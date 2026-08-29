import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/stt_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/stt_providers.dart';
import 'package:native_tavern/presentation/widgets/chat/chat_voice_input_button.dart';

import 'support/fake_stt_backends.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSTTPermissionGateway permission;
  late FakeSystemSTTBackend system;
  late FakeSTTAudioRecorder recorder;
  late FakeRemoteSTTBackend remote;
  late STTService service;
  late TextEditingController controller;

  setUp(() {
    permission = FakeSTTPermissionGateway();
    system = FakeSystemSTTBackend();
    recorder = FakeSTTAudioRecorder();
    remote = FakeRemoteSTTBackend();
    service = STTService(
      permissionGateway: permission,
      systemBackend: system,
      recorder: recorder,
      remoteBackend: remote,
    );
    controller = TextEditingController();
  });

  tearDown(() {
    controller.dispose();
    service.dispose();
  });

  testWidgets(
      'hold updates draft, release stops, and transcript stays editable',
      (tester) async {
    const settings = STTSettings(enabled: true);
    service.updateSettings(settings);
    controller.text = 'Existing draft';
    await _pumpHarness(tester, service, controller, settings: settings);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('chat-voice-hold-button'))),
    );
    await tester.pump();
    await tester.pump();
    system.result('spoken words');
    await tester.pump();
    expect(controller.text, 'Existing draft spoken words');

    await gesture.up();
    await tester.pump();
    expect(system.stopCount, 1);
    expect(controller.text, 'Existing draft spoken words');

    controller.text = '${controller.text} edited';
    expect(controller.text, 'Existing draft spoken words edited');
  });

  testWidgets('explicit cancel restores the draft', (tester) async {
    const settings = STTSettings(enabled: true);
    service.updateSettings(settings);
    controller.text = 'Keep this';
    await _pumpHarness(tester, service, controller, settings: settings);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('chat-voice-hold-button'))),
    );
    await tester.pump();
    await tester.pump();
    system.result('discard this');
    await tester.pump();
    expect(controller.text, 'Keep this discard this');

    await tester.tap(find.byKey(const ValueKey('chat-voice-cancel-button')));
    await tester.pump();
    await gesture.cancel();
    expect(controller.text, 'Keep this');
    expect(system.cancelCount, 1);
  });

  testWidgets('final transcript auto-sends once when enabled', (tester) async {
    const settings = STTSettings(enabled: true, autoSend: true);
    service.updateSettings(settings);
    var sendCount = 0;
    await _pumpHarness(
      tester,
      service,
      controller,
      settings: settings,
      onSend: () => sendCount++,
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('chat-voice-hold-button'))),
    );
    await tester.pump();
    await tester.pump();
    system.result('send me');
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(controller.text, 'send me');
    expect(sendCount, 1);
  });

  testWidgets('permission failure leaves typed text and send control usable',
      (tester) async {
    const settings = STTSettings(enabled: true);
    service.updateSettings(settings);
    permission.current = STTPermissionState.denied;
    var sentText = '';
    await _pumpHarness(
      tester,
      service,
      controller,
      settings: settings,
      onSend: () => sentText = controller.text,
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('chat-voice-hold-button'))),
    );
    await tester.pump();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Microphone permission was denied'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'typed fallback');
    await tester.tap(find.byKey(const ValueKey('send-button')));
    expect(sentText, 'typed fallback');
  });

  testWidgets('permanent denial offers the system settings recovery action',
      (tester) async {
    const settings = STTSettings(enabled: true);
    service.updateSettings(settings);
    permission.current = STTPermissionState.permanentlyDenied;
    await _pumpHarness(tester, service, controller, settings: settings);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('chat-voice-hold-button'))),
    );
    await tester.pump();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Open settings'));
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    expect(permission.openSettingsCount, 1);
  });
}

Future<void> _pumpHarness(
  WidgetTester tester,
  STTService service,
  TextEditingController controller, {
  required STTSettings settings,
  VoidCallback? onSend,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        sttServiceProvider.overrideWithValue(service),
        sttSettingsProvider.overrideWith(
          (ref) => _FixedSTTSettingsNotifier(service, settings),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: TextField(controller: controller)),
              ChatVoiceInputButton(
                controller: controller,
                onAutoSend: onSend ?? () {},
              ),
              IconButton(
                key: const ValueKey('send-button'),
                onPressed: onSend,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _FixedSTTSettingsNotifier extends STTSettingsNotifier {
  _FixedSTTSettingsNotifier(super.service, STTSettings settings) {
    state = settings;
  }
}

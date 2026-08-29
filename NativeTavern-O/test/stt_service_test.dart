import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/stt_service.dart';
import 'package:native_tavern/domain/services/voice_adapter_contract.dart';

import 'support/fake_stt_backends.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSTTPermissionGateway permission;
  late FakeSystemSTTBackend system;
  late FakeSTTAudioRecorder recorder;
  late FakeRemoteSTTBackend remote;
  late STTService service;

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
  });

  tearDown(() {
    service.dispose();
  });

  test('distinguishes denied, permanently denied, and unavailable permission',
      () async {
    service.updateSettings(const STTSettings(enabled: true));

    permission.current = STTPermissionState.denied;
    await service.startListening();
    expect(service.state.phase, STTSessionPhase.permissionDenied);

    permission.current = STTPermissionState.permanentlyDenied;
    await service.startListening();
    expect(
      service.state.phase,
      STTSessionPhase.permissionPermanentlyDenied,
    );
    await service.openPermissionSettings();
    expect(permission.openSettingsCount, 1);

    permission.current = STTPermissionState.unavailable;
    await service.startListening();
    expect(service.state.phase, STTSessionPhase.unavailable);
    expect(system.listenCount, 0);
  });

  test('system recognition publishes partial and editable final transcript',
      () async {
    service.updateSettings(const STTSettings(enabled: true));

    await service.startListening();
    expect(service.state.phase, STTSessionPhase.listening);
    system.result('hello');
    expect(service.state.result?.text, 'hello');
    expect(service.state.result?.isFinal, isFalse);

    await service.stopListening();
    expect(service.state.phase, STTSessionPhase.completed);
    expect(service.state.result?.text, 'hello');
    expect(service.state.result?.isFinal, isTrue);
  });

  test('system cancel cannot be converted to completion by platform status',
      () async {
    service.updateSettings(const STTSettings(enabled: true));
    final phases = <STTSessionPhase>[];
    final subscription =
        service.states.listen((state) => phases.add(state.phase));
    await service.startListening();
    system.result('discard me');

    await service.cancelListening();

    expect(service.state.phase, STTSessionPhase.cancelled);
    expect(service.state.result, isNull);
    expect(phases, isNot(contains(STTSessionPhase.completed)));
    await subscription.cancel();
  });

  test('unavailable system recognizer is observable', () async {
    system.available = false;
    service.updateSettings(const STTSettings(enabled: true));

    await service.startListening();

    expect(service.state.phase, STTSessionPhase.unavailable);
    expect(service.state.errorKind, VoiceAdapterErrorKind.unavailable);
  });

  test('unconfigured remote provider does not record or make a request',
      () async {
    service.updateSettings(
      const STTSettings(
        enabled: true,
        provider: STTProvider.selfHosted,
      ),
    );

    await service.startListening();

    expect(service.state.phase, STTSessionPhase.failed);
    expect(service.state.errorKind, VoiceAdapterErrorKind.configuration);
    expect(permission.requestCount, 0);
    expect(recorder.startCount, 0);
    expect(remote.transcribeCount, 0);
  });

  test('remote recording is stopped and transcribed', () async {
    service.updateSettings(
      const STTSettings(
        enabled: true,
        provider: STTProvider.selfHosted,
        apiEndpoint: 'http://localhost:8080/v1',
      ),
    );

    await service.startListening();
    expect(recorder.startCount, 1);
    await service.stopListening();

    expect(recorder.stopCount, 1);
    expect(remote.transcribeCount, 1);
    expect(remote.lastPath, '/virtual/voice.wav');
    expect(service.state.phase, STTSessionPhase.completed);
    expect(service.state.result?.text, 'remote transcript');
  });

  test('remote timeout uses the shared error contract', () async {
    remote.handler = (_) async => throw DioException(
          requestOptions: RequestOptions(path: '/audio/transcriptions'),
          type: DioExceptionType.receiveTimeout,
        );
    service.updateSettings(
      const STTSettings(
        enabled: true,
        provider: STTProvider.selfHosted,
        apiEndpoint: 'http://localhost:8080/v1',
      ),
    );

    await service.startListening();
    await service.stopListening();

    expect(service.state.phase, STTSessionPhase.failed);
    expect(service.state.errorKind, VoiceAdapterErrorKind.timeout);
  });

  test('remote transcription can be cancelled while processing', () async {
    final transcribing = Completer<STTResult>();
    remote.handler = (token) {
      token.whenCancel.then((error) {
        if (!transcribing.isCompleted) transcribing.completeError(error);
      });
      return transcribing.future;
    };
    service.updateSettings(
      const STTSettings(
        enabled: true,
        provider: STTProvider.selfHosted,
        apiEndpoint: 'http://localhost:8080/v1',
      ),
    );

    await service.startListening();
    final stopping = service.stopListening();
    await _waitFor(() => remote.transcribeCount == 1);
    await service.cancelListening();
    await stopping;

    expect(service.state.phase, STTSessionPhase.cancelled);
  });

  test('background interruption cancels and audio route changes do not',
      () async {
    service.updateSettings(const STTSettings(enabled: true));
    await service.startListening();

    service.handleAudioRouteChanged();
    expect(service.state.phase, STTSessionPhase.listening);
    expect(system.cancelCount, 0);

    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await _waitFor(() => service.state.phase == STTSessionPhase.cancelled);
    expect(system.cancelCount, 1);
  });

  test('late results from a cancelled session do not pollute the next message',
      () async {
    service.updateSettings(const STTSettings(enabled: true));
    await service.startListening();
    system.result('old partial');
    await service.cancelListening();

    await service.startListening();
    system.result('stale final', isFinal: true, sessionIndex: 0);
    expect(service.state.result, isNull);
    expect(service.state.phase, STTSessionPhase.listening);

    system.result('new final', isFinal: true, sessionIndex: 1);
    expect(service.state.result?.text, 'new final');
    expect(service.state.phase, STTSessionPhase.completed);
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 50 && !predicate(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}

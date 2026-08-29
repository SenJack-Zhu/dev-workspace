import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_character_view.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_stage_gestures.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Live2D survives lifecycle changes and 20 character switches',
    (tester) async {
      // Android's integration-test host can request semantics after the test
      // starts, which otherwise looks like an application-owned handle leak.
      tester.platformDispatcher.semanticsEnabledTestValue = false;

      final harnessKey = GlobalKey<_Live2DStabilityHarnessState>();
      await tester.pumpWidget(_Live2DStabilityHarness(key: harnessKey));
      await _waitUntil(
          tester, () => harnessKey.currentState!.controller.isReady);

      expect(find.byType(ClipRect), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Opacity && widget.opacity == 0.72,
        ),
        findsOneWidget,
      );

      final stage = find.byType(Live2DBackgroundTapRegion);
      final center = tester.getCenter(stage);
      await tester.tapAt(center);
      await _waitUntil(
        tester,
        () => harnessKey.currentState!.backgroundTapPlayed,
      );
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(center);
      await tester.pump();
      expect(tester.takeException(), isNull);

      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await _waitUntil(
        tester,
        () => harnessKey.currentState!.controller.isRenderingPaused,
      );
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      await _waitUntil(
        tester,
        () => !harnessKey.currentState!.controller.isRenderingPaused,
      );
      expect(harnessKey.currentState!.controller.isReady, isTrue);

      final navigator = Navigator.of(tester.element(stage));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covered route')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _waitUntil(
        tester,
        () => harnessKey.currentState!.controller.isRenderingPaused,
      );
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _waitUntil(
        tester,
        () => !harnessKey.currentState!.controller.isRenderingPaused,
      );
      expect(harnessKey.currentState!.controller.isReady, isTrue);

      for (var index = 0; index < 20; index++) {
        final modelId = harnessKey.currentState!.switchCharacter();
        await tester.pump();
        await _waitUntil(
          tester,
          () =>
              harnessKey.currentState!.controller.isReady &&
              harnessKey.currentState!.controller.loadedModelId == modelId,
        );
        expect(tester.takeException(), isNull);
      }

      final finalController = harnessKey.currentState!.controller;
      harnessKey.currentState!.showTextOnly();
      await tester.pumpAndSettle();
      expect(find.text('Text-only chat remains available'), findsOneWidget);
      expect(finalController.isAttached, isFalse);
      expect(tester.takeException(), isNull);
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the Live2D native view state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

class _Live2DStabilityHarness extends StatefulWidget {
  const _Live2DStabilityHarness({super.key});

  @override
  State<_Live2DStabilityHarness> createState() =>
      _Live2DStabilityHarnessState();
}

class _Live2DStabilityHarnessState extends State<_Live2DStabilityHarness> {
  final Live2DCharacterController controller = Live2DCharacterController();
  var generation = 0;
  var textOnly = false;
  var backgroundTapPlayed = false;

  String switchCharacter() {
    setState(() {
      generation++;
    });
    return 'hiyori_free_$generation';
  }

  void showTextOnly() {
    setState(() {
      textOnly = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ColoredBox(
          color: const Color(0xfff4f0e8),
          child: textOnly
              ? const Center(child: Text('Text-only chat remains available'))
              : Live2DBackgroundTapRegion(
                  onTap: (position) {
                    unawaited(
                      controller.handleTapAt(position).then((played) {
                        if (mounted && played) {
                          setState(() => backgroundTapPlayed = true);
                        }
                      }),
                    );
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const Center(child: Text('Transparent chat background')),
                      IgnorePointer(
                        child: Live2DCharacterView(
                          config: Live2DConfig(
                            modelId: 'hiyori_free_$generation',
                            displayName: 'Hiyori Momose (Official Sample)',
                            modelDirectory: 'assets/live2d/hiyori_free/',
                            modelFileName: 'hiyori_free_t08.model3.json',
                            opacity: 0.72,
                          ),
                          controller: controller,
                          interactive: false,
                          showStatus: true,
                        ),
                      ),
                      ListView(
                        children: const [
                          SizedBox(height: 80),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Card(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('Foreground chat message'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

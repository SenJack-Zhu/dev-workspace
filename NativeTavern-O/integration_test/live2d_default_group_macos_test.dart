import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_character_view.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_stage_gestures.dart';

const _modelDirectory = String.fromEnvironment('LIVE2D_TEST_MODEL_DIR');
const _modelFileName = String.fromEnvironment('LIVE2D_TEST_MODEL_FILE');
const _idleIndex = int.fromEnvironment('LIVE2D_TEST_IDLE_INDEX');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'default-group idle survives its boundary and accepts repeated taps',
    (tester) async {
      const definition = Live2DModelDefinition(
        id: 'default-group-macos-regression',
        displayName: 'Default group macOS regression model',
        modelDirectory: _modelDirectory,
        modelFileName: _modelFileName,
        source: Live2DModelSource.fileSystem,
      );
      final manifest = await const Live2DService().loadManifest(definition);
      final discoveredIdle = manifest.motions.firstWhere(
        (motion) => motion.group.isEmpty && motion.index == _idleIndex,
      );
      final idleDuration = discoveredIdle.duration;
      expect(idleDuration, isNotNull);

      final controller = Live2DCharacterController();
      final tapResults = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Live2DTwoFingerGestureRegion(
              initialTransform: const Live2DStageTransform(
                scale: 1,
                offsetX: 0,
                offsetY: 0,
              ),
              builder: (context, transform) => Live2DBackgroundTapRegion(
                onTap: (position) {
                  unawaited(
                    controller.handleTapAt(position).then(tapResults.add),
                  );
                },
                child: Stack(
                  key: const ValueKey('default-group-live2d-stage'),
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(
                      child: Live2DCharacterView(
                        config: Live2DConfig(
                          modelId: definition.id,
                          displayName: definition.displayName,
                          modelDirectory: definition.modelDirectory,
                          modelFileName: definition.modelFileName,
                          source: definition.source,
                          idleMotion: Live2DMotionRef(
                            group: discoveredIdle.group,
                            index: discoveredIdle.index,
                            file: discoveredIdle.file,
                            name: discoveredIdle.name,
                          ),
                        ),
                        controller: controller,
                        interactive: false,
                        showStatus: true,
                      ),
                    ),
                    const Align(
                      alignment: Alignment.bottomCenter,
                      child: SizedBox(height: 160, width: double.infinity),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await _waitUntil(tester, () => controller.isReady);

      await Future<void>.delayed(
        idleDuration! + const Duration(milliseconds: 400),
      );
      await tester.pump();

      final stage = find.byKey(const ValueKey('default-group-live2d-stage'));
      final bounds = tester.getRect(stage);
      final tapPosition =
          Offset(bounds.center.dx, bounds.top + bounds.height / 3);
      for (var index = 0; index < 3; index++) {
        await tester.tapAt(tapPosition);
        await _waitUntil(tester, () => tapResults.length > index);
        expect(tapResults[index], isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await tester.pump();
      }

      expect(tester.takeException(), isNull);
    },
    skip:
        !Platform.isMacOS || _modelDirectory.isEmpty || _modelFileName.isEmpty,
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the Live2D regression state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

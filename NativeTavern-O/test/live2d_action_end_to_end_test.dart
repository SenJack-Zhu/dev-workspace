import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_action_orchestrator.dart';
import 'package:native_tavern/domain/services/live2d_hit_test_service.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';

void main() {
  testWidgets('manifest-to-event action flow is deterministic', (tester) async {
    const service = Live2DService();
    final manifest = service.parseManifest(_modelJson);
    const definition = Live2DModelDefinition(
      id: 'semantic-model',
      displayName: 'Semantic Model',
      modelDirectory: 'models/semantic',
      modelFileName: 'semantic.model3.json',
      source: Live2DModelSource.fileSystem,
    );
    final config = Live2DConfig.fromDefinition(definition, manifest);

    expect(config.headTapMotion?.group, 'Tap@Head');
    expect(config.bodyTapMotion?.group, 'Tap@Body');
    expect(config.speakingMotion?.group, 'Talk');
    expect(config.responseMotion?.group, 'Complete');
    expect(config.emotionMotions['happy']?.group, 'Happy');

    const hitTest = Live2DHitTestService();
    final headHit = hitTest.hitTest(
      hitAreas: config.hitAreas,
      normalizedX: 0.5,
      normalizedY: 0.2,
    );
    final bodyHit = hitTest.hitTest(
      hitAreas: config.hitAreas,
      normalizedX: 0.5,
      normalizedY: 0.75,
    );
    expect(headHit, Live2DHitResult.head);
    expect(bodyHit, Live2DHitResult.body);

    final played = <String>[];
    final orchestrator = Live2DActionOrchestrator(
      resolver: Live2DActionResolver(config),
      player: (motion, priority) async {
        played.add('${motion.group}:$priority');
        return true;
      },
      tapDuration: const Duration(milliseconds: 100),
      emotionDuration: const Duration(milliseconds: 80),
      sentenceCooldown: Duration.zero,
    );
    final boundaries = Live2DSentenceBoundaryTracker();

    await orchestrator.onIdleTimeout();
    await orchestrator.onMessageStarted();
    expect(boundaries.takeNewBoundaries('Hello there.'), 1);
    await orchestrator.onSentenceBoundary();
    await orchestrator.onTap(headHit);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await orchestrator.onResponseCompleted(emotion: 'happy');
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();

    expect(played, [
      'Idle:1',
      'Talk:2',
      'Talk:2',
      'Tap@Head:3',
      'Talk:2',
      'Happy:2',
      'Idle:1',
    ]);
    expect(orchestrator.current?.kind, Live2DActionKind.idle);
    orchestrator.dispose();
  });
}

const _modelJson = r'''
{
  "Version": 3,
  "FileReferences": {
    "Moc": "semantic.moc3",
    "Textures": ["texture.png"],
    "Motions": {
      "Idle": [{"File": "motions/idle.motion3.json"}],
      "Tap": [{"File": "motions/tap.motion3.json"}],
      "Tap@Head": [{"File": "motions/head.motion3.json"}],
      "Tap@Body": [{"File": "motions/body.motion3.json"}],
      "Talk": [{"File": "motions/talk.motion3.json"}],
      "Complete": [{"File": "motions/complete.motion3.json"}],
      "Happy": [{"File": "motions/happy.motion3.json"}]
    }
  },
  "Groups": [
    {"Target": "Parameter", "Name": "LipSync", "Ids": ["Mouth"]}
  ],
  "HitAreas": [
    {"Id": "HitAreaHead", "Name": "Head"},
    {"Id": "HitAreaBody", "Name": "Body"}
  ]
}
''';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_action_orchestrator.dart';
import 'package:native_tavern/domain/services/live2d_hit_test_service.dart';

void main() {
  group('Live2D hit semantics', () {
    const service = Live2DHitTestService();
    const hitAreas = [
      Live2DHitArea(id: 'HitAreaHead', name: 'Face'),
      Live2DHitArea(id: 'HitAreaBody', name: 'Torso'),
    ];

    test('distinguishes declared head, body, and misses', () {
      expect(
        service.hitTest(
          hitAreas: hitAreas,
          normalizedX: 0.5,
          normalizedY: 0.2,
        ),
        Live2DHitResult.head,
      );
      expect(
        service.hitTest(
          hitAreas: hitAreas,
          normalizedX: 0.5,
          normalizedY: 0.7,
        ),
        Live2DHitResult.body,
      );
      expect(
        service.hitTest(
          hitAreas: hitAreas,
          normalizedX: 0.01,
          normalizedY: 0.5,
        ),
        Live2DHitResult.miss,
      );
    });

    test('unknown declarations remain non-interactive', () {
      expect(
        service.hitTest(
          hitAreas: const [Live2DHitArea(id: 'Accessory', name: 'Hat')],
          normalizedX: 0.5,
          normalizedY: 0.2,
        ),
        Live2DHitResult.miss,
      );
    });

    test('models without declarations use a generic body target', () {
      expect(
        service.hitTest(
          hitAreas: const [],
          normalizedX: 0.5,
          normalizedY: 0.7,
        ),
        Live2DHitResult.body,
      );
    });
  });

  group('Live2D action orchestration', () {
    test('tap starts from a random non-idle model motion', () async {
      final played = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(
          _config(),
          tapMotions: [
            _motion('Idle'),
            _motion('Wave'),
            _motion('Jump'),
          ],
          randomIndex: (upperBound) => upperBound - 1,
        ),
        player: (motion, priority) async {
          played.add(motion.group);
          return true;
        },
      );

      expect(await orchestrator.onTap(Live2DHitResult.body), isTrue);
      expect(played, ['Jump']);
      orchestrator.dispose();
    });

    test('failed random motion tries the remaining model motions', () async {
      final attempted = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(
          _config(),
          tapMotions: [_motion('Wave'), _motion('Jump')],
          randomIndex: (_) => 0,
        ),
        player: (motion, priority) async {
          attempted.add(motion.group);
          return motion.group == 'Jump';
        },
      );

      expect(await orchestrator.onTap(Live2DHitResult.head), isTrue);
      expect(attempted, ['Wave', 'Jump']);
      orchestrator.dispose();
    });

    testWidgets('default-group idle replays at its motion boundary',
        (tester) async {
      final played = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(
          _config().copyWith(
            idleMotion: _motion(
              '',
              durationSeconds: 0.05,
            ),
          ),
        ),
        player: (motion, priority) async {
          played.add('${motion.group}:${motion.index}');
          return true;
        },
      );

      expect(await orchestrator.onIdleTimeout(), isTrue);
      expect(played, [':0']);
      await tester.pump(const Duration(milliseconds: 51));
      await tester.pump();
      expect(played, [':0', ':0']);
      orchestrator.dispose();
    });

    testWidgets('native-looped idle is not restarted at its boundary',
        (tester) async {
      final played = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(
          _config().copyWith(
            idleMotion: _motion('', durationSeconds: 0.05),
          ),
        ),
        player: (motion, priority) async {
          played.add('${motion.group}:${motion.index}');
          return true;
        },
        replayIdleAtMotionBoundary: false,
      );

      expect(await orchestrator.onIdleTimeout(), isTrue);
      await tester.pump(const Duration(milliseconds: 51));
      await tester.pump();
      expect(played, [':0']);
      orchestrator.dispose();
    });

    testWidgets('tap recovery uses the selected motion duration',
        (tester) async {
      final played = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(
          _config().copyWith(
            headTapMotion: _motion(
              'TapHead',
              durationSeconds: 0.05,
            ),
          ),
        ),
        player: (motion, priority) async {
          played.add(motion.group);
          return true;
        },
        tapDuration: const Duration(seconds: 2),
      );

      expect(await orchestrator.onTap(Live2DHitResult.head), isTrue);
      expect(played, ['TapHead']);
      await tester.pump(const Duration(milliseconds: 51));
      await tester.pump();
      expect(played, ['TapHead', 'Idle']);
      orchestrator.dispose();
    });

    testWidgets('a tap preempts speaking and then restores it', (tester) async {
      final played = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(_config()),
        player: (motion, priority) async {
          played.add('${motion.group}:$priority');
          return true;
        },
        tapDuration: const Duration(milliseconds: 100),
      );

      await orchestrator.onMessageStarted();
      await orchestrator.onTap(Live2DHitResult.head);
      expect(played, ['Talk:2', 'TapHead:3']);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(played, ['Talk:2', 'TapHead:3', 'Talk:2']);
      expect(orchestrator.current?.kind, Live2DActionKind.speaking);

      orchestrator.dispose();
    });

    testWidgets('higher priority tap preserves interrupted completion',
        (tester) async {
      final played = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(_config()),
        player: (motion, priority) async {
          played.add('${motion.group}:$priority');
          return true;
        },
        tapDuration: const Duration(milliseconds: 100),
        completionDuration: const Duration(milliseconds: 80),
      );

      await orchestrator.onMessageStarted();
      await orchestrator.onResponseCompleted();
      await orchestrator.onTap(Live2DHitResult.body);
      expect(played, ['Talk:2', 'Complete:2', 'TapBody:3']);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(played.last, 'Complete:2');
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      expect(played.last, 'Idle:1');

      orchestrator.dispose();
    });

    test('failed or damaged motions fall back without throwing', () async {
      final attempted = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(_config()),
        player: (motion, priority) async {
          attempted.add(motion.group);
          return motion.group != 'TapHead';
        },
      );

      expect(await orchestrator.onTap(Live2DHitResult.head), isTrue);
      expect(attempted, ['TapHead', 'Tap']);
      expect(orchestrator.current?.motion.group, 'Tap');

      orchestrator.dispose();
    });

    test('repeated taps respect cooldown', () async {
      var now = DateTime(2026, 8, 8);
      final played = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(_config()),
        player: (motion, priority) async {
          played.add(motion.group);
          return true;
        },
        now: () => now,
        tapCooldown: const Duration(milliseconds: 600),
      );

      expect(await orchestrator.onTap(Live2DHitResult.head), isTrue);
      expect(await orchestrator.onTap(Live2DHitResult.head), isFalse);
      now = now.add(const Duration(milliseconds: 600));
      expect(await orchestrator.onTap(Live2DHitResult.head), isTrue);
      expect(played, ['TapHead', 'TapHead']);

      orchestrator.dispose();
    });

    testWidgets('reset cancels model-switch recovery', (tester) async {
      final played = <String>[];
      final orchestrator = Live2DActionOrchestrator(
        resolver: Live2DActionResolver(_config()),
        player: (motion, priority) async {
          played.add(motion.group);
          return true;
        },
        tapDuration: const Duration(milliseconds: 100),
      );

      await orchestrator.onMessageStarted();
      await orchestrator.onTap(Live2DHitResult.head);
      orchestrator.reset();
      await tester.pump(const Duration(seconds: 1));
      expect(played, ['Talk', 'TapHead']);
      expect(orchestrator.current, isNull);

      expect(await orchestrator.onIdleTimeout(), isTrue);
      expect(played.last, 'Idle');
      orchestrator.dispose();
      expect(await orchestrator.onIdleTimeout(), isFalse);
    });
  });

  test('sentence tracker emits only newly completed boundaries', () {
    final tracker = Live2DSentenceBoundaryTracker();
    expect(tracker.takeNewBoundaries('Hello'), 0);
    expect(tracker.takeNewBoundaries('Hello.'), 1);
    expect(tracker.takeNewBoundaries('Hello... Still here!'), 1);
    expect(tracker.takeNewBoundaries('replacement?'), 1);
    expect(tracker.takeNewBoundaries('replacement?'), 0);
  });
}

Live2DConfig _config() {
  return Live2DConfig(
    modelId: 'test',
    displayName: 'Test',
    modelDirectory: 'models/test',
    modelFileName: 'test.model3.json',
    idleMotion: _motion('Idle'),
    tapMotion: _motion('Tap'),
    headTapMotion: _motion('TapHead'),
    bodyTapMotion: _motion('TapBody'),
    speakingMotion: _motion('Talk'),
    responseMotion: _motion('Complete'),
    emotionMotions: {'happy': _motion('Happy')},
  );
}

Live2DMotionRef _motion(
  String group, {
  double? durationSeconds,
  bool loop = false,
}) {
  return Live2DMotionRef(
    group: group,
    index: 0,
    file: '$group.motion3.json',
    name: group,
    durationSeconds: durationSeconds,
    loop: loop,
  );
}

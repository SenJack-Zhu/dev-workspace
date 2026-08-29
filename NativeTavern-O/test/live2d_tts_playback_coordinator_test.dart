import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_action_orchestrator.dart';
import 'package:native_tavern/domain/services/live2d_tts_playback_coordinator.dart';
import 'package:native_tavern/domain/services/tts_service.dart';

void main() {
  test('playback boundaries, pause, resume, and stop coordinate Live2D',
      () async {
    final played = <Live2DActionKind>[];
    final mouths = <double>[];
    final orchestrator = Live2DActionOrchestrator(
      resolver: Live2DActionResolver(_config()),
      player: (motion, priority) async => true,
      onPlaybackChanged: (playback) {
        if (playback != null) played.add(playback.kind);
      },
      sentenceCooldown: Duration.zero,
    );
    final coordinator = Live2DTTSPlaybackCoordinator();

    const playing = TTSPlaybackState(
      sessionId: 'speech-1',
      text: 'Hello. Still here.',
      spokenText: 'Hello.',
      phase: TTSPlaybackPhase.playing,
      mouthOpen: 0.82,
    );
    await _apply(
      coordinator.evaluate(null, playing),
      orchestrator,
      mouths,
    );
    expect(played, [Live2DActionKind.speaking, Live2DActionKind.speaking]);
    expect(mouths.last, closeTo(0.82, 0.001));

    final paused = playing.copyWith(
      phase: TTSPlaybackPhase.paused,
      mouthOpen: 0,
    );
    await _apply(
      coordinator.evaluate(playing, paused),
      orchestrator,
      mouths,
    );
    expect(played.last, Live2DActionKind.idle);
    expect(mouths.last, 0);

    final resumed = paused.copyWith(
      phase: TTSPlaybackPhase.playing,
      mouthOpen: 0.45,
    );
    final resumeUpdate = coordinator.evaluate(paused, resumed);
    expect(resumeUpdate.sentenceBoundaries, 0);
    await _apply(resumeUpdate, orchestrator, mouths);
    expect(played.last, Live2DActionKind.speaking);

    final stopped = resumed.copyWith(
      phase: TTSPlaybackPhase.cancelled,
      mouthOpen: 0,
    );
    await _apply(
      coordinator.evaluate(resumed, stopped),
      orchestrator,
      mouths,
    );
    expect(played.last, Live2DActionKind.idle);
    expect(mouths.last, 0);
    orchestrator.dispose();
  });

  test('completion closes the mouth and emits only one completion action',
      () async {
    final coordinator = Live2DTTSPlaybackCoordinator();
    const playing = TTSPlaybackState(
      sessionId: 'speech-1',
      text: 'Finished.',
      spokenText: 'Finished.',
      phase: TTSPlaybackPhase.playing,
      mouthOpen: 0.7,
    );
    final completed = playing.copyWith(
      phase: TTSPlaybackPhase.completed,
      mouthOpen: 0,
    );

    final first = coordinator.evaluate(playing, completed);
    final duplicate = coordinator.evaluate(completed, completed);

    expect(first.mouthOpen, 0);
    expect(first.lifecycle, Live2DTTSLifecycleEvent.completed);
    expect(duplicate.lifecycle, Live2DTTSLifecycleEvent.none);
  });
}

Future<void> _apply(
  Live2DTTSPlaybackUpdate update,
  Live2DActionOrchestrator orchestrator,
  List<double> mouths,
) async {
  mouths.add(update.mouthOpen);
  switch (update.lifecycle) {
    case Live2DTTSLifecycleEvent.none:
      break;
    case Live2DTTSLifecycleEvent.started:
      await orchestrator.onMessageStarted();
    case Live2DTTSLifecycleEvent.paused:
      await orchestrator.onPlaybackPaused();
    case Live2DTTSLifecycleEvent.completed:
      await orchestrator.onResponseCompleted();
    case Live2DTTSLifecycleEvent.stopped:
      await orchestrator.onPlaybackStopped();
  }
  for (var index = 0; index < update.sentenceBoundaries; index++) {
    await orchestrator.onSentenceBoundary();
  }
}

Live2DConfig _config() {
  return Live2DConfig(
    modelId: 'test',
    displayName: 'Test',
    modelDirectory: 'models/test',
    modelFileName: 'test.model3.json',
    idleMotion: _motion('Idle'),
    speakingMotion: _motion('Talk'),
    responseMotion: _motion('Complete'),
  );
}

Live2DMotionRef _motion(String group) {
  return Live2DMotionRef(
    group: group,
    index: 0,
    file: '$group.motion3.json',
    name: group,
  );
}

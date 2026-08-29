import 'package:flutter/foundation.dart';
import 'package:native_tavern/domain/services/live2d_action_orchestrator.dart';
import 'package:native_tavern/domain/services/tts_service.dart';

enum Live2DTTSLifecycleEvent { none, started, paused, completed, stopped }

@immutable
class Live2DTTSPlaybackUpdate {
  const Live2DTTSPlaybackUpdate({
    required this.mouthOpen,
    this.lifecycle = Live2DTTSLifecycleEvent.none,
    this.sentenceBoundaries = 0,
  });

  final double mouthOpen;
  final Live2DTTSLifecycleEvent lifecycle;
  final int sentenceBoundaries;
}

/// Converts TTS state changes into deterministic Live2D mouth and motion work.
class Live2DTTSPlaybackCoordinator {
  final Live2DSentenceBoundaryTracker _sentenceTracker =
      Live2DSentenceBoundaryTracker();

  Live2DTTSPlaybackUpdate evaluate(
    TTSPlaybackState? previous,
    TTSPlaybackState next,
  ) {
    switch (next.phase) {
      case TTSPlaybackPhase.playing:
        final newSession =
            previous == null || previous.sessionId != next.sessionId;
        final started = previous?.sessionId != next.sessionId ||
            previous?.phase != TTSPlaybackPhase.playing;
        if (newSession) _sentenceTracker.reset();
        return Live2DTTSPlaybackUpdate(
          mouthOpen: next.mouthOpen.clamp(0, 1),
          lifecycle: started
              ? Live2DTTSLifecycleEvent.started
              : Live2DTTSLifecycleEvent.none,
          sentenceBoundaries:
              _sentenceTracker.takeNewBoundaries(next.spokenText),
        );
      case TTSPlaybackPhase.paused:
        return Live2DTTSPlaybackUpdate(
          mouthOpen: 0,
          lifecycle: previous?.phase == TTSPlaybackPhase.paused
              ? Live2DTTSLifecycleEvent.none
              : Live2DTTSLifecycleEvent.paused,
        );
      case TTSPlaybackPhase.completed:
        return Live2DTTSPlaybackUpdate(
          mouthOpen: 0,
          lifecycle: previous?.phase != TTSPlaybackPhase.completed ||
                  previous?.sessionId != next.sessionId
              ? Live2DTTSLifecycleEvent.completed
              : Live2DTTSLifecycleEvent.none,
        );
      case TTSPlaybackPhase.cancelled:
      case TTSPlaybackPhase.failed:
      case TTSPlaybackPhase.idle:
        return Live2DTTSPlaybackUpdate(
          mouthOpen: 0,
          lifecycle: previous?.isActive == true ||
                  previous?.sessionId != next.sessionId
              ? Live2DTTSLifecycleEvent.stopped
              : Live2DTTSLifecycleEvent.none,
        );
      case TTSPlaybackPhase.queued:
        return const Live2DTTSPlaybackUpdate(mouthOpen: 0);
    }
  }

  void reset() => _sentenceTracker.reset();
}

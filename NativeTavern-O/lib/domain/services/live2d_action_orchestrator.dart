import 'dart:async';
import 'dart:math';

import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_hit_test_service.dart';

enum Live2DActionKind { idle, speaking, headTap, bodyTap, completion, emotion }

class Live2DActionPlayback {
  final Live2DActionKind kind;
  final Live2DMotionRef motion;
  final int priority;
  final String? emotion;

  const Live2DActionPlayback({
    required this.kind,
    required this.motion,
    required this.priority,
    this.emotion,
  });
}

typedef Live2DMotionPlayer = Future<bool> Function(
    Live2DMotionRef motion, int priority);

typedef Live2DPlaybackListener = void Function(Live2DActionPlayback? playback);
typedef Live2DRandomIndex = int Function(int upperBound);

/// Applies semantic fallback rules without relying on provider-specific names.
class Live2DActionResolver {
  final Live2DConfig config;
  final List<Live2DMotionRef> tapMotions;
  final Live2DRandomIndex _randomIndex;

  Live2DActionResolver(
    this.config, {
    Iterable<Live2DMotionRef> tapMotions = const [],
    Live2DRandomIndex? randomIndex,
  })  : tapMotions = List.unmodifiable(tapMotions),
        _randomIndex = randomIndex ?? Random().nextInt;

  List<Live2DMotionRef> candidatesFor(
    Live2DActionKind kind, {
    String? emotion,
  }) {
    final candidates = switch (kind) {
      Live2DActionKind.idle => [config.idleMotion],
      Live2DActionKind.speaking => [config.speakingMotion, config.idleMotion],
      Live2DActionKind.headTap => [
          ..._randomTapMotions(),
          config.headTapMotion,
          config.tapMotion,
          config.bodyTapMotion,
          config.idleMotion,
        ],
      Live2DActionKind.bodyTap => [
          ..._randomTapMotions(),
          config.bodyTapMotion,
          config.tapMotion,
          config.headTapMotion,
          config.idleMotion,
        ],
      Live2DActionKind.completion => [config.responseMotion, config.idleMotion],
      Live2DActionKind.emotion => [
          if (emotion != null) config.emotionMotions[emotion],
          config.responseMotion,
          config.idleMotion,
        ],
    };

    final seen = <String>{};
    return candidates.whereType<Live2DMotionRef>().where((motion) {
      return seen.add('${motion.group}\u0000${motion.index}');
    }).toList();
  }

  List<Live2DMotionRef> _randomTapMotions() {
    final idle = config.idleMotion;
    final candidates = tapMotions.where((motion) {
      return idle == null ||
          motion.group != idle.group ||
          motion.index != idle.index;
    }).toList();
    if (candidates.isEmpty) return const [];

    final start = _randomIndex(candidates.length);
    return [
      ...candidates.skip(start),
      ...candidates.take(start),
    ];
  }
}

class _ActionRequest {
  final Live2DActionKind kind;
  final int priority;
  final bool transient;
  final Duration duration;
  final String? emotion;

  const _ActionRequest({
    required this.kind,
    required this.priority,
    required this.transient,
    required this.duration,
    this.emotion,
  });
}

/// Deterministically coordinates persistent and one-shot Live2D actions.
class Live2DActionOrchestrator {
  final Live2DActionResolver resolver;
  final Live2DMotionPlayer player;
  final Live2DPlaybackListener? onPlaybackChanged;
  final DateTime Function() _now;
  final Duration tapDuration;
  final Duration completionDuration;
  final Duration emotionDuration;
  final Duration tapCooldown;
  final Duration sentenceCooldown;
  final bool replayIdleAtMotionBoundary;

  Timer? _recoveryTimer;
  Timer? _baseReplayTimer;
  _ActionRequest? _activeTransient;
  _ActionRequest? _pendingTransient;
  Live2DActionPlayback? _current;
  final Map<String, DateTime> _lastEventAt = {};
  int _generation = 0;
  bool _speaking = false;
  bool _disposed = false;

  Live2DActionOrchestrator({
    required this.resolver,
    required this.player,
    this.onPlaybackChanged,
    DateTime Function()? now,
    this.tapDuration = const Duration(milliseconds: 2600),
    this.completionDuration = const Duration(milliseconds: 2200),
    this.emotionDuration = const Duration(milliseconds: 2200),
    this.tapCooldown = const Duration(milliseconds: 600),
    this.sentenceCooldown = const Duration(milliseconds: 450),
    this.replayIdleAtMotionBoundary = true,
  }) : _now = now ?? DateTime.now;

  Live2DActionPlayback? get current => _current;
  bool get isDisposed => _disposed;

  Future<bool> onMessageStarted() {
    if (_disposed) return Future.value(false);
    _speaking = true;
    _pendingTransient = null;
    return _request(
      const _ActionRequest(
        kind: Live2DActionKind.speaking,
        priority: 2,
        transient: false,
        duration: Duration.zero,
      ),
    );
  }

  Future<bool> onSentenceBoundary() {
    if (_disposed || !_speaking) return Future.value(false);
    return _request(
      const _ActionRequest(
        kind: Live2DActionKind.speaking,
        priority: 2,
        transient: false,
        duration: Duration.zero,
      ),
      cooldownKey: 'sentence',
      cooldown: sentenceCooldown,
    );
  }

  Future<bool> onResponseCompleted({String? emotion}) {
    if (_disposed) return Future.value(false);
    _speaking = false;
    final normalizedEmotion = emotion?.trim().toLowerCase();
    final hasEmotion = normalizedEmotion != null &&
        normalizedEmotion.isNotEmpty &&
        normalizedEmotion != 'neutral';
    return _request(
      _ActionRequest(
        kind:
            hasEmotion ? Live2DActionKind.emotion : Live2DActionKind.completion,
        priority: 2,
        transient: true,
        duration: hasEmotion ? emotionDuration : completionDuration,
        emotion: hasEmotion ? normalizedEmotion : null,
      ),
    );
  }

  Future<bool> onPlaybackPaused() => _stopSpeakingWithoutCompletion();

  Future<bool> onPlaybackStopped() => _stopSpeakingWithoutCompletion();

  Future<bool> _stopSpeakingWithoutCompletion() {
    if (_disposed) return Future.value(false);
    _speaking = false;
    _pendingTransient = null;
    _activeTransient = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    return _request(
      const _ActionRequest(
        kind: Live2DActionKind.idle,
        priority: 1,
        transient: false,
        duration: Duration.zero,
      ),
    );
  }

  Future<bool> onTap(Live2DHitResult hit) {
    if (_disposed || hit == Live2DHitResult.miss) {
      return Future.value(false);
    }
    final kind = hit == Live2DHitResult.head
        ? Live2DActionKind.headTap
        : Live2DActionKind.bodyTap;
    return _request(
      _ActionRequest(
        kind: kind,
        priority: 3,
        transient: true,
        duration: tapDuration,
      ),
      cooldownKey: kind.name,
      cooldown: tapCooldown,
    );
  }

  Future<bool> onIdleTimeout() {
    if (_disposed || _speaking || _activeTransient != null) {
      return Future.value(false);
    }
    return _request(
      const _ActionRequest(
        kind: Live2DActionKind.idle,
        priority: 1,
        transient: false,
        duration: Duration.zero,
      ),
    );
  }

  Future<bool> _request(
    _ActionRequest request, {
    String? cooldownKey,
    Duration cooldown = Duration.zero,
  }) async {
    if (_disposed) return false;
    _baseReplayTimer?.cancel();
    _baseReplayTimer = null;
    if (cooldownKey != null && !_consumeCooldown(cooldownKey, cooldown)) {
      return false;
    }

    final active = _activeTransient;
    if (active != null && active.priority > request.priority) {
      if (request.transient) _queueTransient(request);
      return false;
    }
    if (active != null && request.priority > active.priority) {
      _queueTransient(active);
    }

    _recoveryTimer?.cancel();
    _activeTransient = request.transient ? request : null;
    return _play(request);
  }

  bool _consumeCooldown(String key, Duration cooldown) {
    final now = _now();
    final last = _lastEventAt[key];
    if (last != null && now.difference(last) < cooldown) return false;
    _lastEventAt[key] = now;
    return true;
  }

  void _queueTransient(_ActionRequest request) {
    final pending = _pendingTransient;
    if (pending == null || request.priority >= pending.priority) {
      _pendingTransient = request;
    }
  }

  Future<bool> _play(_ActionRequest request) async {
    final generation = ++_generation;
    final candidates = resolver.candidatesFor(
      request.kind,
      emotion: request.emotion,
    );

    for (final motion in candidates) {
      final played = await player(motion, request.priority);
      if (_disposed || generation != _generation) return false;
      if (!played) continue;
      _setCurrent(
        Live2DActionPlayback(
          kind: request.kind,
          motion: motion,
          priority: request.priority,
          emotion: request.emotion,
        ),
      );
      if (request.transient) {
        _scheduleRecovery(
          _motionDuration(motion, request.duration),
          generation,
        );
      } else if (replayIdleAtMotionBoundary &&
          request.kind == Live2DActionKind.idle &&
          motion.group != 'Idle') {
        _scheduleBaseReplay(_motionDuration(motion, request.duration));
      }
      return true;
    }

    if (request.transient && generation == _generation) {
      scheduleMicrotask(() => _finishTransient(generation));
    }
    return false;
  }

  void _scheduleRecovery(Duration duration, int generation) {
    _recoveryTimer = Timer(duration, () => _finishTransient(generation));
  }

  void _scheduleBaseReplay(Duration duration) {
    if (duration <= Duration.zero) return;
    _baseReplayTimer = Timer(duration, () {
      _baseReplayTimer = null;
      if (!_disposed && !_speaking && _activeTransient == null) {
        unawaited(_restoreBaseAction());
      }
    });
  }

  Duration _motionDuration(
    Live2DMotionRef motion,
    Duration fallback,
  ) {
    final duration = motion.duration;
    if (duration == null) return fallback;
    final speed = resolver.config.motionSpeed;
    if (!speed.isFinite || speed <= 0) return duration;
    return Duration(
      microseconds: (duration.inMicroseconds / speed).round(),
    );
  }

  void _finishTransient(int generation) {
    if (_disposed || generation != _generation) return;
    _recoveryTimer = null;
    _activeTransient = null;
    final pending = _pendingTransient;
    _pendingTransient = null;
    if (pending != null) {
      unawaited(_request(pending));
      return;
    }
    unawaited(_restoreBaseAction());
  }

  Future<bool> _restoreBaseAction() {
    return _request(
      _ActionRequest(
        kind: _speaking ? Live2DActionKind.speaking : Live2DActionKind.idle,
        priority: _speaking ? 2 : 1,
        transient: false,
        duration: Duration.zero,
      ),
    );
  }

  void _setCurrent(Live2DActionPlayback? playback) {
    _current = playback;
    onPlaybackChanged?.call(playback);
  }

  void reset() {
    if (_disposed) return;
    _generation++;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _baseReplayTimer?.cancel();
    _baseReplayTimer = null;
    _activeTransient = null;
    _pendingTransient = null;
    _lastEventAt.clear();
    _speaking = false;
    _setCurrent(null);
  }

  void dispose() {
    if (_disposed) return;
    reset();
    _disposed = true;
  }
}

/// Counts only newly completed sentence boundaries in a streaming response.
class Live2DSentenceBoundaryTracker {
  static final RegExp _boundary = RegExp(r'(?:[.!?。！？]+|\n+)');

  String _previousText = '';
  int _boundaryCount = 0;

  int takeNewBoundaries(String text) {
    if (!text.startsWith(_previousText)) {
      _boundaryCount = 0;
    }
    final count = _boundary.allMatches(text).length;
    final added = count > _boundaryCount ? count - _boundaryCount : 0;
    _previousText = text;
    _boundaryCount = count;
    return added;
  }

  void reset({String text = ''}) {
    _previousText = text;
    _boundaryCount = _boundary.allMatches(text).length;
  }
}

import 'dart:async';

typedef Live2DRenderingPauseApplier = Future<void> Function(bool paused);

/// Serializes app lifecycle changes before they reach a native render loop.
///
/// A platform view can attach after the app has already entered the
/// background, and pause/resume platform calls can complete out of order.
/// This coordinator preserves the latest requested state across both cases.
class Live2DRenderingLifecycle {
  final Live2DRenderingPauseApplier _applyPaused;

  Future<void> _tail = Future<void>.value();
  bool _attached = false;
  bool _disposed = false;
  bool _appActive;
  bool _viewVisible;
  bool _desiredPaused;
  bool? _appliedPaused;
  int _attachmentGeneration = 0;
  Object? _lastError;

  Live2DRenderingLifecycle({
    required Live2DRenderingPauseApplier applyPaused,
    bool initialPaused = false,
  })  : _applyPaused = applyPaused,
        _appActive = !initialPaused,
        _viewVisible = true,
        _desiredPaused = initialPaused;

  bool get isAttached => _attached;
  bool get desiredPaused => _desiredPaused;
  bool? get appliedPaused => _appliedPaused;
  Object? get lastError => _lastError;

  Future<void> setAttached(bool attached) {
    if (_disposed || _attached == attached) return _tail;
    if (!attached) {
      return _detachAndPause();
    }
    _attached = true;
    _appliedPaused = null;
    _attachmentGeneration++;
    return _scheduleSynchronization();
  }

  Future<void> setAppActive(bool active) {
    if (_disposed) return Future<void>.value();
    _appActive = active;
    return _updateDesiredState();
  }

  Future<void> setViewVisible(bool visible) {
    if (_disposed) return Future<void>.value();
    _viewVisible = visible;
    return _updateDesiredState();
  }

  Future<void> _updateDesiredState() {
    final desiredPaused = !_appActive || !_viewVisible;
    if (_desiredPaused == desiredPaused) return _tail;
    _desiredPaused = desiredPaused;
    return _scheduleSynchronization();
  }

  Future<void> _scheduleSynchronization() {
    final operation = _tail.then<void>(
      (_) => _synchronize(),
      onError: (_, __) => _synchronize(),
    );
    _tail = operation;
    return operation;
  }

  Future<void> _synchronize() async {
    if (_disposed || !_attached || _appliedPaused == _desiredPaused) return;

    final target = _desiredPaused;
    final attachmentGeneration = _attachmentGeneration;
    try {
      await _applyPaused(target);
    } catch (error, stackTrace) {
      _lastError = error;
      Error.throwWithStackTrace(error, stackTrace);
    }

    if (_disposed ||
        !_attached ||
        attachmentGeneration != _attachmentGeneration) {
      return;
    }
    _appliedPaused = target;
    _lastError = null;
  }

  /// Stops the native display-link / ticker before Flutter unmounts the view.
  ///
  /// Leaving the pump running races Impeller text teardown and crashes iOS.
  Future<void> pauseForTeardown() {
    if (_disposed) return Future<void>.value();
    _desiredPaused = true;
    return _applyPauseNow();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _attached = false;
    _desiredPaused = true;
    _appliedPaused = null;
    _attachmentGeneration++;
    unawaited(_applyPaused(true).catchError((_) {}));
  }

  Future<void> _detachAndPause() {
    _attached = false;
    _desiredPaused = true;
    _appliedPaused = null;
    _attachmentGeneration++;
    return _applyPauseNow();
  }

  Future<void> _applyPauseNow() {
    final generation = _attachmentGeneration;
    final operation = _tail.catchError((_) {}).then((_) async {
      try {
        await _applyPaused(true);
        if (!_disposed && generation == _attachmentGeneration) {
          _appliedPaused = true;
          _lastError = null;
        }
      } catch (error) {
        _lastError = error;
      }
    });
    _tail = operation;
    return operation;
  }
}

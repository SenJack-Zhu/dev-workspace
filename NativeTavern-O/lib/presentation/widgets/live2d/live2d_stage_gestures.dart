import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

@immutable
class Live2DStageTransform {
  static const double minScale = 0.1;
  static const double maxScale = 10;
  static const double maxOffset = 10;

  final double scale;
  final double offsetX;
  final double offsetY;

  const Live2DStageTransform({
    required this.scale,
    required this.offsetX,
    required this.offsetY,
  });

  factory Live2DStageTransform.constrained({
    required double scale,
    required double offsetX,
    required double offsetY,
  }) {
    return Live2DStageTransform(
      scale: scale.clamp(minScale, maxScale),
      offsetX: offsetX.clamp(-maxOffset, maxOffset),
      offsetY: offsetY.clamp(-maxOffset, maxOffset),
    );
  }

  /// Applies a gesture relative to its initial focal point and transform.
  /// Offsets are stored as fractions of the stage size.
  static Live2DStageTransform applyGesture({
    required Live2DStageTransform start,
    required Offset startFocalPoint,
    required Offset currentFocalPoint,
    required double scaleDelta,
    required Size size,
  }) {
    if (size.isEmpty) return start;
    final startScale = start.scale.clamp(minScale, maxScale);
    final nextScale = (startScale * scaleDelta).clamp(minScale, maxScale);
    final scaleRatio = nextScale / startScale;
    final center = size.center(Offset.zero);
    final startTranslation = Offset(
      start.offsetX * size.width,
      start.offsetY * size.height,
    );
    final nextTranslation = currentFocalPoint -
        center -
        (startFocalPoint - center - startTranslation) * scaleRatio;
    return Live2DStageTransform.constrained(
      scale: nextScale,
      offsetX: nextTranslation.dx / size.width,
      offsetY: nextTranslation.dy / size.height,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is Live2DStageTransform &&
        other.scale == scale &&
        other.offsetX == offsetX &&
        other.offsetY == offsetY;
  }

  @override
  int get hashCode => Object.hash(scale, offsetX, offsetY);
}

typedef Live2DTransformBuilder = Widget Function(
    BuildContext context, Live2DStageTransform transform);

/// Observes taps that were not claimed by foreground controls or scrolling.
class Live2DBackgroundTapRegion extends StatelessWidget {
  final Widget child;
  final ValueChanged<Offset> onTap;

  const Live2DBackgroundTapRegion({
    super.key,
    required this.child,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) => onTap(details.localPosition),
      child: child,
    );
  }
}

/// Waits for a second touch before accepting the gesture. A one-finger drag can
/// therefore be won by the message list, while a two-finger gesture transforms
/// the Live2D stage without scrolling messages at the same time.
class Live2DTwoFingerGestureRegion extends StatefulWidget {
  final Live2DStageTransform initialTransform;
  final Live2DTransformBuilder builder;
  final ValueChanged<Live2DStageTransform>? onTransformEnd;
  final bool resetOnDoubleTap;

  const Live2DTwoFingerGestureRegion({
    super.key,
    required this.initialTransform,
    required this.builder,
    this.onTransformEnd,
    this.resetOnDoubleTap = false,
  });

  @override
  State<Live2DTwoFingerGestureRegion> createState() =>
      _Live2DTwoFingerGestureRegionState();
}

class _Live2DTwoFingerGestureRegionState
    extends State<Live2DTwoFingerGestureRegion> {
  final Map<int, Offset> _touches = {};
  late Live2DStageTransform _transform;
  Live2DStageTransform? _gestureStartTransform;
  Offset? _gestureStartFocalPoint;
  double? _gestureStartDistance;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _transform = widget.initialTransform;
  }

  @override
  void didUpdateWidget(Live2DTwoFingerGestureRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_gestureStartTransform == null &&
        oldWidget.initialTransform != widget.initialTransform) {
      _transform = widget.initialTransform;
    }
  }

  bool _isTouch(PointerEvent event) => event.kind == PointerDeviceKind.touch;

  List<Offset> get _primaryTouches {
    final pointers = _touches.keys.toList()..sort();
    return pointers.take(2).map((pointer) => _touches[pointer]!).toList();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_isTouch(event)) return;
    _touches[event.pointer] = event.localPosition;
    if (_touches.length == 2) {
      final touches = _primaryTouches;
      _gestureStartTransform = _transform;
      _gestureStartFocalPoint = _centroid(touches);
      _gestureStartDistance = (touches[0] - touches[1]).distance;
      _changed = false;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.localPosition;
    final startTransform = _gestureStartTransform;
    final startFocalPoint = _gestureStartFocalPoint;
    final startDistance = _gestureStartDistance;
    final size = context.size;
    if (_touches.length < 2 ||
        startTransform == null ||
        startFocalPoint == null ||
        startDistance == null ||
        size == null ||
        size.isEmpty) {
      return;
    }

    final touches = _primaryTouches;
    final currentDistance = (touches[0] - touches[1]).distance;
    final scaleDelta =
        startDistance <= 0.000001 ? 1.0 : currentDistance / startDistance;
    final next = Live2DStageTransform.applyGesture(
      start: startTransform,
      startFocalPoint: startFocalPoint,
      currentFocalPoint: _centroid(touches),
      scaleDelta: scaleDelta,
      size: size,
    );
    if (next == _transform) return;
    setState(() => _transform = next);
    _changed = true;
  }

  void _handlePointerEnd(int pointer) {
    if (!_touches.containsKey(pointer)) return;
    _touches.remove(pointer);
    if (_gestureStartTransform != null && _touches.length < 2) {
      _gestureStartTransform = null;
      _gestureStartFocalPoint = null;
      _gestureStartDistance = null;
      if (_changed) widget.onTransformEnd?.call(_transform);
      _changed = false;
    }
  }

  void _handleDoubleTap() {
    const reset = Live2DStageTransform(
      scale: 1,
      offsetX: 0,
      offsetY: 0,
    );
    if (_transform == reset) return;
    setState(() => _transform = reset);
    widget.onTransformEnd?.call(reset);
  }

  Offset _centroid(List<Offset> touches) {
    return Offset(
      touches.map((point) => point.dx).reduce((a, b) => a + b) / touches.length,
      touches.map((point) => point.dy).reduce((a, b) => a + b) / touches.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        _TwoFingerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<_TwoFingerGestureRecognizer>(
          _TwoFingerGestureRecognizer.new,
          (recognizer) {
            recognizer
              ..onPointerDown = _handlePointerDown
              ..onPointerMove = _handlePointerMove
              ..onPointerEnd = _handlePointerEnd;
          },
        ),
        if (widget.resetOnDoubleTap)
          DoubleTapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
            DoubleTapGestureRecognizer.new,
            (recognizer) => recognizer.onDoubleTap = _handleDoubleTap,
          ),
      },
      child: widget.builder(context, _transform),
    );
  }
}

class _TwoFingerGestureRecognizer extends OneSequenceGestureRecognizer {
  final Set<int> _trackedPointers = {};
  ValueChanged<PointerDownEvent>? onPointerDown;
  ValueChanged<PointerMoveEvent>? onPointerMove;
  ValueChanged<int>? onPointerEnd;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch || _trackedPointers.length >= 2) {
      return;
    }
    startTrackingPointer(event.pointer, event.transform);
    _trackedPointers.add(event.pointer);
    onPointerDown?.call(event);
    if (_trackedPointers.length == 2) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_trackedPointers.contains(event.pointer)) return;
    if (event is PointerMoveEvent) {
      onPointerMove?.call(event);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _finishPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    _finishPointer(pointer);
  }

  void _finishPointer(int pointer) {
    if (!_trackedPointers.remove(pointer)) return;
    onPointerEnd?.call(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    resolve(GestureDisposition.rejected);
  }

  @override
  String get debugDescription => 'two finger Live2D transform';
}

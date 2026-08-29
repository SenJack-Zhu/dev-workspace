import 'package:native_tavern/data/models/live2d.dart';

enum Live2DHitResult { head, body, miss }

/// Resolves app-level touch semantics from declared Cubism hit areas.
///
/// Cubism's model JSON identifies hit drawables but does not expose their
/// geometry to Flutter. This resolver provides deterministic normalized zones
/// and treats models without declarations as a generic body target.
class Live2DHitTestService {
  static const double _modelLeft = 0.08;
  static const double _modelRight = 0.92;
  static const double _modelTop = 0.04;
  static const double _modelBottom = 0.98;
  static const double _headBottom = 0.4;

  const Live2DHitTestService();

  Live2DHitResult hitTest({
    required List<Live2DHitArea> hitAreas,
    required double normalizedX,
    required double normalizedY,
  }) {
    if (!normalizedX.isFinite ||
        !normalizedY.isFinite ||
        normalizedX < _modelLeft ||
        normalizedX > _modelRight ||
        normalizedY < _modelTop ||
        normalizedY > _modelBottom) {
      return Live2DHitResult.miss;
    }

    final kinds = hitAreas.map((area) => area.kind).toSet();
    final hasHead = kinds.contains(Live2DHitAreaKind.head);
    final hasBody = kinds.contains(Live2DHitAreaKind.body);
    if (hitAreas.isEmpty) return Live2DHitResult.body;
    if (hasHead && (!hasBody || normalizedY <= _headBottom)) {
      return Live2DHitResult.head;
    }
    if (hasBody) return Live2DHitResult.body;
    return Live2DHitResult.miss;
  }
}

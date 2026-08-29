import 'package:flutter/material.dart';

/// Returns a valid popover anchor for iPad share sheets.
Rect sharePositionOrigin(BuildContext context) {
  Rect? rectFor(RenderObject? object) {
    if (object is! RenderBox || !object.hasSize || object.size.isEmpty) {
      return null;
    }
    final origin = object.localToGlobal(Offset.zero);
    final rect = origin & object.size;
    return rect.isEmpty ? null : rect;
  }

  final localRect = rectFor(context.findRenderObject());
  if (localRect != null) return localRect;

  final overlayRect = rectFor(
    Overlay.maybeOf(context)?.context.findRenderObject(),
  );
  if (overlayRect != null) return overlayRect;

  final size = MediaQuery.sizeOf(context);
  return Rect.fromLTWH(size.width / 2, size.height / 2, 1, 1);
}

import 'package:spine_flutter/spine_flutter.dart' as spine;

class SpineModelMetadata {
  final String version;
  final List<String> animations;

  const SpineModelMetadata({
    required this.version,
    required this.animations,
  });
}

/// Lazily initializes the official Spine runtime and inspects binary data.
class SpineRuntimeService {
  static Future<void>? _initialization;

  static Future<void> ensureInitialized() {
    return _initialization ??= spine.initSpineFlutter();
  }

  static Future<SpineModelMetadata> inspectModel({
    required String atlasPath,
    required String skeletonPath,
  }) async {
    await ensureInitialized();
    final atlas = await spine.Atlas.fromFile(atlasPath);
    spine.SkeletonData? skeletonData;
    try {
      skeletonData = await spine.SkeletonData.fromFile(atlas, skeletonPath);
      return SpineModelMetadata(
        version: skeletonData.getVersion() ?? '',
        animations: skeletonData
            .getAnimations()
            .map((animation) => animation.getName())
            .toList(growable: false),
      );
    } finally {
      skeletonData?.dispose();
      atlas.dispose();
    }
  }
}

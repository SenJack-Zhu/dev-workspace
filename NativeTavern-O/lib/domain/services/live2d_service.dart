import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/spine_runtime_service.dart';
import 'package:path/path.dart' as p;

/// Discovers and validates Cubism model metadata without loading native code.
class Live2DService {
  final String? dataPath;

  const Live2DService({this.dataPath});

  static const bundledModels = <Live2DModelDefinition>[
    Live2DModelDefinition(
      id: 'hiyori_free',
      displayName: 'Hiyori Momose (Official Sample)',
      modelDirectory: 'assets/live2d/hiyori_free/',
      modelFileName: 'hiyori_free_t08.model3.json',
    ),
  ];

  /// Resolves persisted assignments against the current model catalog.
  ///
  /// Imported model IDs change when the same ZIP is imported again, so a
  /// unique model-file match provides a recovery path for legacy assignments.
  /// Unknown asset assignments are not returned because Flutter cannot load
  /// assets that are no longer declared by the application bundle.
  static Live2DModelDefinition? resolveDefinitionForConfig(
    Live2DConfig config,
    Iterable<Live2DModelDefinition> availableModels,
  ) {
    final models = availableModels.toList();
    for (final model in models) {
      if (model.id == config.modelId) return model;
    }

    for (final model in models) {
      if (p.equals(
            p.normalize(model.modelDirectory),
            p.normalize(config.modelDirectory),
          ) &&
          model.modelFileName == config.modelFileName &&
          model.format == config.format) {
        return model;
      }
    }

    final fileMatches = models
        .where(
          (model) =>
              model.format == config.format &&
              model.modelFileName.toLowerCase() ==
                  config.modelFileName.toLowerCase(),
        )
        .toList();
    if (fileMatches.length == 1 &&
        (config.displayName.trim().isEmpty ||
            _identityKey(fileMatches.single.displayName) ==
                _identityKey(config.displayName))) {
      return fileMatches.single;
    }

    if (config.source == Live2DModelSource.asset ||
        config.modelDirectory.isEmpty ||
        config.modelFileName.isEmpty) {
      return null;
    }
    return Live2DModelDefinition(
      id: config.modelId,
      displayName: config.displayName,
      modelDirectory: config.modelDirectory,
      modelFileName: config.modelFileName,
      source: config.source,
      format: config.format,
      atlasFileName: config.atlasFileName,
    );
  }

  static String _identityKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Updates storage identity while retaining character-specific staging and
  /// motion choices from an existing assignment.
  static Live2DConfig rebindConfigToDefinition(
    Live2DConfig config,
    Live2DModelDefinition definition,
    Live2DModelManifest manifest,
  ) {
    final discovered = Live2DConfig.fromDefinition(definition, manifest);
    return config
        .withActionDefaults(
          discovered,
          discoveredMotions: manifest.motions,
        )
        .copyWith(
          modelId: definition.id,
          displayName: definition.displayName,
          modelDirectory: definition.modelDirectory,
          modelFileName: definition.modelFileName,
          source: definition.source,
          format: definition.format,
          atlasFileName: definition.atlasFileName,
        );
  }

  Future<Live2DModelManifest> loadManifest(
    Live2DModelDefinition definition,
  ) async {
    if (definition.format == Live2DModelFormat.spine) {
      return _loadSpineManifest(definition);
    }
    final modelDirectory = _resolveModelDirectory(definition);
    final jsonText = switch (definition.source) {
      Live2DModelSource.asset => await rootBundle.loadString(
          '${definition.modelDirectory}${definition.modelFileName}',
        ),
      Live2DModelSource.appData || Live2DModelSource.fileSystem => await File(
          p.join(modelDirectory, definition.modelFileName),
        ).readAsString(),
    };
    final manifest = parseManifest(jsonText);
    return _loadMotionMetadata(definition, manifest);
  }

  Future<Live2DModelManifest> _loadMotionMetadata(
    Live2DModelDefinition definition,
    Live2DModelManifest manifest,
  ) async {
    final modelDirectory = _resolveModelDirectory(definition);
    final motions = <Live2DMotionRef>[];
    for (final motion in manifest.motions) {
      if (motion.file.isEmpty) {
        motions.add(motion);
        continue;
      }
      try {
        final jsonText = switch (definition.source) {
          Live2DModelSource.asset => await rootBundle.loadString(
              '${definition.modelDirectory}${motion.file}',
            ),
          Live2DModelSource.appData ||
          Live2DModelSource.fileSystem =>
            await File(p.join(modelDirectory, motion.file)).readAsString(),
        };
        final root = jsonDecode(jsonText) as Map<String, dynamic>;
        final meta = root['Meta'] as Map<String, dynamic>? ?? const {};
        motions.add(
          motion.copyWith(
            durationSeconds: (meta['Duration'] as num?)?.toDouble(),
            loop: meta['Loop'] as bool? ?? false,
          ),
        );
      } catch (_) {
        motions.add(motion);
      }
    }
    return manifest.copyWith(motions: motions);
  }

  Future<Live2DModelManifest> _loadSpineManifest(
    Live2DModelDefinition definition,
  ) async {
    if (definition.source == Live2DModelSource.asset) {
      throw UnsupportedError('Bundled Spine assets are not configured.');
    }
    final modelDirectory = _resolveModelDirectory(definition);
    final atlasFileName = definition.atlasFileName;
    if (atlasFileName == null || atlasFileName.isEmpty) {
      throw const FormatException('The Spine model is missing its atlas file.');
    }
    final atlasPath = p.join(modelDirectory, atlasFileName);
    final skeletonPath = p.join(modelDirectory, definition.modelFileName);
    final textures = parseSpineAtlasTexturePaths(
      await File(atlasPath).readAsString(),
    );
    if (textures.isEmpty) {
      throw const FormatException(
          'The Spine atlas does not reference a texture.');
    }
    try {
      final metadata = await SpineRuntimeService.inspectModel(
        atlasPath: atlasPath,
        skeletonPath: skeletonPath,
      );
      final version = int.tryParse(metadata.version.split('.').first) ?? 0;
      return Live2DModelManifest(
        format: Live2DModelFormat.spine,
        version: version,
        mocFile: '',
        textures: textures,
        atlasFileName: atlasFileName,
        motions: [
          for (var index = 0; index < metadata.animations.length; index++)
            Live2DMotionRef(
              group: metadata.animations[index],
              index: index,
              file: '',
              name: metadata.animations[index],
            ),
        ],
      );
    } catch (error) {
      final headerVersion = parseSpineBinaryVersion(
        await File(skeletonPath).readAsBytes(),
      );
      if (!isSupportedSpineRuntimeVersion(headerVersion)) {
        throw FormatException(
          'The Spine model could not be read by runtime 4.1: $error',
        );
      }
      return Live2DModelManifest(
        format: Live2DModelFormat.spine,
        version: spineMajorVersion(headerVersion) ?? 4,
        mocFile: '',
        textures: textures,
        atlasFileName: atlasFileName,
      );
    }
  }

  /// Reads the editor version string from a Spine 4.x `.skel` header.
  static String? parseSpineBinaryVersion(List<int> bytes) {
    if (bytes.length < 10) return null;
    var offset = 8;
    final length = _readSpineVarint(bytes, offset);
    if (length == null) return null;
    offset = length.offset;
    if (length.value <= 1 || offset + length.value - 1 > bytes.length) {
      return null;
    }
    try {
      return utf8.decode(bytes.sublist(offset, offset + length.value - 1));
    } catch (_) {
      return null;
    }
  }

  static bool isSupportedSpineRuntimeVersion(String? version) {
    return version != null && version.startsWith('4.1');
  }

  static int? spineMajorVersion(String? version) {
    if (version == null || version.isEmpty) return null;
    return int.tryParse(version.split('.').first);
  }

  static ({int value, int offset})? _readSpineVarint(
    List<int> bytes,
    int offset,
  ) {
    var result = 0;
    var shift = 0;
    var cursor = offset;
    while (cursor < bytes.length && shift <= 28) {
      final byte = bytes[cursor++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        return (value: result, offset: cursor);
      }
      shift += 7;
    }
    return null;
  }

  /// Extracts page image paths from the standard Spine atlas text format.
  static List<String> parseSpineAtlasTexturePaths(String atlasText) {
    final lines = const LineSplitter().convert(atlasText);
    final textures = <String>[];
    var startsSection = true;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty) {
        startsSection = true;
        continue;
      }
      if (!startsSection || line.contains(':')) continue;
      final nextProperty = lines
          .skip(index + 1)
          .map((candidate) => candidate.trim())
          .firstWhere((candidate) => candidate.isNotEmpty, orElse: () => '');
      if (nextProperty.startsWith('size:') ||
          nextProperty.startsWith('format:') ||
          nextProperty.startsWith('filter:') ||
          nextProperty.startsWith('repeat:') ||
          nextProperty.startsWith('pma:')) {
        textures.add(line.replaceAll('\\', '/'));
      }
      startsSection = false;
    }
    return textures;
  }

  Live2DModelManifest parseManifest(String jsonText) {
    final root = jsonDecode(jsonText) as Map<String, dynamic>;
    final references =
        root['FileReferences'] as Map<String, dynamic>? ?? const {};
    final motions = <Live2DMotionRef>[];
    final motionGroups =
        references['Motions'] as Map<String, dynamic>? ?? const {};

    for (final entry in motionGroups.entries) {
      final items = entry.value as List<dynamic>? ?? const [];
      for (var index = 0; index < items.length; index++) {
        final item = items[index] as Map<String, dynamic>? ?? const {};
        final file = item['File'] as String? ?? '';
        motions.add(
          Live2DMotionRef(
            group: entry.key,
            index: index,
            file: file,
            name: _motionName(file, entry.key, index),
          ),
        );
      }
    }

    final expressions = <String>[];
    for (final raw in references['Expressions'] as List<dynamic>? ?? const []) {
      if (raw is Map<String, dynamic> && raw['File'] is String) {
        expressions.add(raw['File'] as String);
      }
    }

    final lipSyncParameters = <String>[];
    for (final raw in root['Groups'] as List<dynamic>? ?? const []) {
      if (raw is! Map<String, dynamic> || raw['Name'] != 'LipSync') continue;
      for (final id in raw['Ids'] as List<dynamic>? ?? const []) {
        if (id is String) lipSyncParameters.add(id);
      }
    }

    final hitAreas = <Live2DHitArea>[];
    for (final raw in root['HitAreas'] as List<dynamic>? ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      final id = raw['Id'] as String? ?? '';
      final name = raw['Name'] as String? ?? '';
      if (id.isEmpty && name.isEmpty) continue;
      hitAreas.add(Live2DHitArea(id: id, name: name));
    }

    return Live2DModelManifest(
      version: (root['Version'] as num?)?.toInt() ?? 0,
      mocFile: references['Moc'] as String? ?? '',
      textures: (references['Textures'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      physicsFile: references['Physics'] as String?,
      poseFile: references['Pose'] as String?,
      expressions: expressions,
      motions: motions,
      hitAreas: hitAreas,
      lipSyncParameters: lipSyncParameters,
    );
  }

  /// Returns referenced files that cannot be found beside the model JSON.
  Future<List<String>> findMissingFiles(
    Live2DModelDefinition definition,
    Live2DModelManifest manifest,
  ) async {
    final missing = <String>[];
    final modelDirectory = _resolveModelDirectory(definition);
    for (final file in manifest.referencedFiles) {
      try {
        switch (definition.source) {
          case Live2DModelSource.asset:
            await rootBundle.load('${definition.modelDirectory}$file');
          case Live2DModelSource.appData:
          case Live2DModelSource.fileSystem:
            if (!File(p.join(modelDirectory, file)).existsSync()) {
              missing.add(file);
            }
        }
      } catch (_) {
        missing.add(file);
      }
    }
    return missing;
  }

  String _resolveModelDirectory(Live2DModelDefinition definition) {
    if (definition.source != Live2DModelSource.appData) {
      return definition.modelDirectory;
    }
    final root = dataPath;
    if (root == null || root.isEmpty) {
      throw StateError('A data path is required for imported Live2D models.');
    }
    return p.join(root, definition.modelDirectory);
  }

  String _motionName(String file, String group, int index) {
    if (file.isEmpty) return group.isEmpty ? 'Motion ${index + 1}' : group;
    final baseName = p.basename(file).replaceFirst('.motion3.json', '');
    return baseName.replaceAll('_', ' ');
  }
}

final live2DServiceProvider = Provider<Live2DService>((ref) {
  return Live2DService(dataPath: ref.watch(dataPathProvider));
});

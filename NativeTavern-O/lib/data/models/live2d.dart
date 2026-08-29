/// Where a Live2D model is loaded from.
enum Live2DModelSource {
  asset,
  appData,
  fileSystem;

  static Live2DModelSource fromJson(String? value) {
    return Live2DModelSource.values.firstWhere(
      (source) => source.name == value,
      orElse: () => asset,
    );
  }
}

/// The animation runtime required by an imported character model.
enum Live2DModelFormat {
  cubism,
  spine;

  static Live2DModelFormat fromJson(String? value) {
    return Live2DModelFormat.values.firstWhere(
      (format) => format.name == value,
      orElse: () => cubism,
    );
  }
}

/// App-level semantics for a Cubism hit area.
enum Live2DHitAreaKind {
  head,
  body,
  other,
}

/// A named drawable region declared by a Cubism `*.model3.json` file.
class Live2DHitArea {
  final String id;
  final String name;

  const Live2DHitArea({
    required this.id,
    required this.name,
  });

  Live2DHitAreaKind get kind {
    final value = _normalize('$id $name');
    if (value.contains('head') || value.contains('face')) {
      return Live2DHitAreaKind.head;
    }
    if (value.contains('body') ||
        value.contains('torso') ||
        value.contains('bust')) {
      return Live2DHitAreaKind.body;
    }
    return Live2DHitAreaKind.other;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
      };

  factory Live2DHitArea.fromJson(Map<String, dynamic> json) {
    return Live2DHitArea(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
    );
  }
}

/// A motion's stable address inside a Cubism model definition.
class Live2DMotionRef {
  final String group;
  final int index;
  final String file;
  final String name;
  final double? durationSeconds;
  final bool loop;

  const Live2DMotionRef({
    required this.group,
    required this.index,
    required this.file,
    required this.name,
    this.durationSeconds,
    this.loop = false,
  });

  Duration? get duration {
    final seconds = durationSeconds;
    if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
    return Duration(
        microseconds: (seconds * Duration.microsecondsPerSecond).round());
  }

  Live2DMotionRef copyWith({
    double? durationSeconds,
    bool? loop,
  }) {
    return Live2DMotionRef(
      group: group,
      index: index,
      file: file,
      name: name,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      loop: loop ?? this.loop,
    );
  }

  Map<String, dynamic> toJson() => {
        'group': group,
        'index': index,
        'file': file,
        'name': name,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
        'loop': loop,
      };

  factory Live2DMotionRef.fromJson(Map<String, dynamic> json) {
    return Live2DMotionRef(
      group: json['group'] as String? ?? '',
      index: (json['index'] as num?)?.toInt() ?? 0,
      file: json['file'] as String? ?? '',
      name: json['name'] as String? ?? '',
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble(),
      loop: json['loop'] as bool? ?? false,
    );
  }
}

/// A model available to NativeTavern before it is assigned to a character.
class Live2DModelDefinition {
  final String id;
  final String displayName;
  final String modelDirectory;
  final String modelFileName;
  final Live2DModelSource source;
  final Live2DModelFormat format;
  final String? atlasFileName;

  const Live2DModelDefinition({
    required this.id,
    required this.displayName,
    required this.modelDirectory,
    required this.modelFileName,
    this.source = Live2DModelSource.asset,
    this.format = Live2DModelFormat.cubism,
    this.atlasFileName,
  });
}

/// Parsed data from a Cubism `*.model3.json` file.
class Live2DModelManifest {
  final Live2DModelFormat format;
  final int version;
  final String mocFile;
  final List<String> textures;
  final String? atlasFileName;
  final String? physicsFile;
  final String? poseFile;
  final List<String> expressions;
  final List<Live2DMotionRef> motions;
  final List<Live2DHitArea> hitAreas;
  final List<String> lipSyncParameters;

  const Live2DModelManifest({
    this.format = Live2DModelFormat.cubism,
    required this.version,
    required this.mocFile,
    required this.textures,
    this.atlasFileName,
    this.physicsFile,
    this.poseFile,
    this.expressions = const [],
    this.motions = const [],
    this.hitAreas = const [],
    this.lipSyncParameters = const [],
  });

  Live2DModelManifest copyWith({List<Live2DMotionRef>? motions}) {
    return Live2DModelManifest(
      format: format,
      version: version,
      mocFile: mocFile,
      textures: textures,
      atlasFileName: atlasFileName,
      physicsFile: physicsFile,
      poseFile: poseFile,
      expressions: expressions,
      motions: motions ?? this.motions,
      hitAreas: hitAreas,
      lipSyncParameters: lipSyncParameters,
    );
  }

  Iterable<String> get referencedFiles sync* {
    if (format == Live2DModelFormat.spine) {
      if (atlasFileName case final value?) yield value;
      yield* textures;
      return;
    }
    if (mocFile.isNotEmpty) yield mocFile;
    yield* textures;
    if (physicsFile case final value?) yield value;
    if (poseFile case final value?) yield value;
    yield* expressions;
    for (final motion in motions) {
      if (motion.file.isNotEmpty) yield motion.file;
    }
  }

  Live2DMotionRef? findMotion(Iterable<String> preferredNames) {
    final normalized = preferredNames
        .map((name) => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''))
        .toList();
    for (final preferred in normalized) {
      for (final motion in motions) {
        final nameCandidate =
            motion.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        final groupCandidate =
            motion.group.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (nameCandidate == preferred || groupCandidate == preferred) {
          return motion;
        }
      }
    }
    return null;
  }
}

/// Per-character Live2D assignment and stage presentation.
class Live2DConfig {
  final bool enabled;
  final String modelId;
  final String displayName;
  final String modelDirectory;
  final String modelFileName;
  final Live2DModelSource source;
  final Live2DModelFormat format;
  final String? atlasFileName;
  final double scale;
  final double offsetX;
  final double offsetY;
  final double opacity;
  final double motionSpeed;
  final Live2DMotionRef? idleMotion;
  final Live2DMotionRef? tapMotion;
  final Live2DMotionRef? headTapMotion;
  final Live2DMotionRef? bodyTapMotion;
  final Live2DMotionRef? speakingMotion;
  final Live2DMotionRef? responseMotion;
  final Map<String, Live2DMotionRef> emotionMotions;
  final List<Live2DHitArea> hitAreas;
  final String lipSyncParameter;

  const Live2DConfig({
    this.enabled = true,
    required this.modelId,
    required this.displayName,
    required this.modelDirectory,
    required this.modelFileName,
    this.source = Live2DModelSource.asset,
    this.format = Live2DModelFormat.cubism,
    this.atlasFileName,
    this.scale = 1,
    this.offsetX = 0,
    this.offsetY = 0,
    this.opacity = 1,
    this.motionSpeed = 1,
    this.idleMotion,
    this.tapMotion,
    this.headTapMotion,
    this.bodyTapMotion,
    this.speakingMotion,
    this.responseMotion,
    this.emotionMotions = const {},
    this.hitAreas = const [],
    this.lipSyncParameter = 'ParamMouthOpenY',
  });

  factory Live2DConfig.fromDefinition(
    Live2DModelDefinition definition,
    Live2DModelManifest manifest,
  ) {
    return Live2DConfig(
      modelId: definition.id,
      displayName: definition.displayName,
      modelDirectory: definition.modelDirectory,
      modelFileName: definition.modelFileName,
      source: definition.source,
      format: definition.format,
      atlasFileName: definition.atlasFileName ?? manifest.atlasFileName,
      idleMotion: manifest.findMotion(const ['idle']),
      tapMotion: manifest.findMotion(
        const ['tap', 'touch', 'flick'],
      ),
      headTapMotion: manifest.findMotion(
        const [
          'touch_head',
          'tap_head',
          'flick_head',
          'head',
        ],
      ),
      bodyTapMotion: manifest.findMotion(
        const [
          'touch_body',
          'tap_body',
          'flick_body',
          'body',
        ],
      ),
      speakingMotion: manifest.findMotion(
        const [
          'speaking',
          'speak',
          'talking',
          'talk',
          'voice',
          'main_1',
          'main_2',
          'main_3',
          'effect',
        ],
      ),
      responseMotion: manifest.findMotion(
        const [
          'complete',
          'completed',
          'finish',
          'finished',
          'response',
          'mission_complete',
        ],
      ),
      emotionMotions: _discoverEmotionMotions(manifest),
      hitAreas: manifest.hitAreas,
      lipSyncParameter:
          manifest.lipSyncParameters.firstOrNull ?? 'ParamMouthOpenY',
    );
  }

  Live2DConfig copyWith({
    bool? enabled,
    String? modelId,
    String? displayName,
    String? modelDirectory,
    String? modelFileName,
    Live2DModelSource? source,
    Live2DModelFormat? format,
    String? atlasFileName,
    double? scale,
    double? offsetX,
    double? offsetY,
    double? opacity,
    double? motionSpeed,
    Live2DMotionRef? idleMotion,
    Live2DMotionRef? tapMotion,
    Live2DMotionRef? headTapMotion,
    Live2DMotionRef? bodyTapMotion,
    Live2DMotionRef? speakingMotion,
    Live2DMotionRef? responseMotion,
    Map<String, Live2DMotionRef>? emotionMotions,
    List<Live2DHitArea>? hitAreas,
    String? lipSyncParameter,
  }) {
    return Live2DConfig(
      enabled: enabled ?? this.enabled,
      modelId: modelId ?? this.modelId,
      displayName: displayName ?? this.displayName,
      modelDirectory: modelDirectory ?? this.modelDirectory,
      modelFileName: modelFileName ?? this.modelFileName,
      source: source ?? this.source,
      format: format ?? this.format,
      atlasFileName: atlasFileName ?? this.atlasFileName,
      scale: scale ?? this.scale,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
      opacity: opacity ?? this.opacity,
      motionSpeed: motionSpeed ?? this.motionSpeed,
      idleMotion: idleMotion ?? this.idleMotion,
      tapMotion: tapMotion ?? this.tapMotion,
      headTapMotion: headTapMotion ?? this.headTapMotion,
      bodyTapMotion: bodyTapMotion ?? this.bodyTapMotion,
      speakingMotion: speakingMotion ?? this.speakingMotion,
      responseMotion: responseMotion ?? this.responseMotion,
      emotionMotions: emotionMotions ?? this.emotionMotions,
      hitAreas: hitAreas ?? this.hitAreas,
      lipSyncParameter: lipSyncParameter ?? this.lipSyncParameter,
    );
  }

  /// Keeps explicit character choices and fills newly discovered semantics.
  Live2DConfig withActionDefaults(
    Live2DConfig defaults, {
    Iterable<Live2DMotionRef> discoveredMotions = const [],
  }) {
    final metadataByAddress = {
      for (final motion in discoveredMotions) _motionAddress(motion): motion,
    };

    Live2DMotionRef? merge(
      Live2DMotionRef? selected,
      Live2DMotionRef? fallback,
    ) {
      final motion = selected ?? fallback;
      if (motion == null) return null;
      return _withDiscoveredMetadata(
        motion,
        metadataByAddress[_motionAddress(motion)] ?? fallback,
      );
    }

    return copyWith(
      idleMotion: merge(idleMotion, defaults.idleMotion),
      tapMotion: merge(tapMotion, defaults.tapMotion),
      headTapMotion: merge(headTapMotion, defaults.headTapMotion),
      bodyTapMotion: merge(bodyTapMotion, defaults.bodyTapMotion),
      speakingMotion: merge(speakingMotion, defaults.speakingMotion),
      responseMotion: merge(responseMotion, defaults.responseMotion),
      emotionMotions: {
        ...defaults.emotionMotions,
        for (final entry in emotionMotions.entries)
          entry.key: merge(
            entry.value,
            defaults.emotionMotions[entry.key],
          )!,
      },
      hitAreas: hitAreas.isEmpty ? defaults.hitAreas : hitAreas,
    );
  }

  static Live2DMotionRef? _withDiscoveredMetadata(
    Live2DMotionRef? selected,
    Live2DMotionRef? discovered,
  ) {
    if (selected == null) return discovered;
    if (discovered == null ||
        selected.group != discovered.group ||
        selected.index != discovered.index) {
      return selected;
    }
    if (discovered.durationSeconds == null) return selected;
    return selected.copyWith(
      durationSeconds: discovered.durationSeconds,
      loop: discovered.loop,
    );
  }

  static String _motionAddress(Live2DMotionRef motion) =>
      '${motion.group}\u0000${motion.index}';

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'modelId': modelId,
        'displayName': displayName,
        'modelDirectory': modelDirectory,
        'modelFileName': modelFileName,
        'source': source.name,
        'format': format.name,
        'atlasFileName': atlasFileName,
        'scale': scale,
        'offsetX': offsetX,
        'offsetY': offsetY,
        'opacity': opacity,
        'motionSpeed': motionSpeed,
        'idleMotion': idleMotion?.toJson(),
        'tapMotion': tapMotion?.toJson(),
        'headTapMotion': headTapMotion?.toJson(),
        'bodyTapMotion': bodyTapMotion?.toJson(),
        'speakingMotion': speakingMotion?.toJson(),
        'responseMotion': responseMotion?.toJson(),
        'emotionMotions': emotionMotions.map(
          (emotion, motion) => MapEntry(emotion, motion.toJson()),
        ),
        'hitAreas': hitAreas.map((area) => area.toJson()).toList(),
        'lipSyncParameter': lipSyncParameter,
      };

  factory Live2DConfig.fromJson(Map<String, dynamic> json) {
    Live2DMotionRef? parseMotion(String key) {
      final value = json[key];
      return value is Map<String, dynamic>
          ? Live2DMotionRef.fromJson(value)
          : null;
    }

    return Live2DConfig(
      enabled: json['enabled'] as bool? ?? true,
      modelId: json['modelId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      modelDirectory: json['modelDirectory'] as String? ?? '',
      modelFileName: json['modelFileName'] as String? ?? '',
      source: Live2DModelSource.fromJson(json['source'] as String?),
      format: Live2DModelFormat.fromJson(json['format'] as String?),
      atlasFileName: json['atlasFileName'] as String?,
      scale: (json['scale'] as num?)?.toDouble() ?? 1,
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1,
      motionSpeed: (json['motionSpeed'] as num?)?.toDouble() ?? 1,
      idleMotion: parseMotion('idleMotion'),
      tapMotion: parseMotion('tapMotion'),
      headTapMotion: parseMotion('headTapMotion'),
      bodyTapMotion: parseMotion('bodyTapMotion'),
      speakingMotion: parseMotion('speakingMotion'),
      responseMotion: parseMotion('responseMotion'),
      emotionMotions: _parseEmotionMotions(json['emotionMotions']),
      hitAreas: (json['hitAreas'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Live2DHitArea.fromJson)
          .toList(),
      lipSyncParameter:
          json['lipSyncParameter'] as String? ?? 'ParamMouthOpenY',
    );
  }
}

const _emotionMotionAliases = <String, List<String>>{
  'neutral': ['neutral', 'normal', 'calm'],
  'happy': ['happy', 'smile', 'joy', 'laugh', 'grin'],
  'sad': ['sad', 'cry', 'sorrow'],
  'angry': ['angry', 'mad', 'rage'],
  'surprised': ['surprised', 'surprise', 'shock'],
  'scared': ['scared', 'fear', 'afraid'],
  'disgusted': ['disgusted', 'disgust'],
  'confused': ['confused', 'puzzled'],
  'embarrassed': ['embarrassed', 'blush', 'shy'],
  'excited': ['excited', 'thrilled'],
  'loving': ['loving', 'love', 'adore'],
  'thinking': ['thinking', 'think', 'ponder'],
  'smug': ['smug', 'proud'],
  'tired': ['tired', 'sleepy', 'yawn'],
  'bored': ['bored', 'uninterested'],
};

Map<String, Live2DMotionRef> _discoverEmotionMotions(
  Live2DModelManifest manifest,
) {
  final motions = <String, Live2DMotionRef>{};
  for (final entry in _emotionMotionAliases.entries) {
    final motion = manifest.findMotion(entry.value);
    if (motion != null) motions[entry.key] = motion;
  }
  return motions;
}

Map<String, Live2DMotionRef> _parseEmotionMotions(Object? value) {
  if (value is! Map) return const {};
  final motions = <String, Live2DMotionRef>{};
  for (final entry in value.entries) {
    if (entry.key is String && entry.value is Map) {
      motions[entry.key as String] = Live2DMotionRef.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
  }
  return motions;
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

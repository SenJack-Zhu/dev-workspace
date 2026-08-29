import 'rpg_rules.dart';
import 'rpg_state.dart';

class RpgScenarioMetadata {
  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final List<String> tags;

  const RpgScenarioMetadata({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.author = '',
    this.tags = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        if (description.isNotEmpty) 'description': description,
        if (author.isNotEmpty) 'author': author,
        if (tags.isNotEmpty) 'tags': tags,
      };

  factory RpgScenarioMetadata.fromJson(Map<String, dynamic> json) =>
      RpgScenarioMetadata(
        id: json['id'] as String,
        name: json['name'] as String,
        version: json['version'] as String,
        description: json['description'] as String? ?? '',
        author: json['author'] as String? ?? '',
        tags: _scenarioStringList(json['tags']),
      );
}

class RpgCompatibility {
  static const defaultEngineVersion = '1.0.0';

  final String minimumEngineVersion;
  final String? maximumEngineVersion;
  final List<String> requiredCapabilities;

  const RpgCompatibility({
    this.minimumEngineVersion = defaultEngineVersion,
    this.maximumEngineVersion,
    this.requiredCapabilities = const [],
  });

  Map<String, dynamic> toJson() => {
        'minimumEngineVersion': minimumEngineVersion,
        if (maximumEngineVersion != null)
          'maximumEngineVersion': maximumEngineVersion,
        'requiredCapabilities': requiredCapabilities,
      };

  factory RpgCompatibility.fromJson(Map<String, dynamic> json) =>
      RpgCompatibility(
        minimumEngineVersion:
            json['minimumEngineVersion'] as String? ?? defaultEngineVersion,
        maximumEngineVersion: json['maximumEngineVersion'] as String?,
        requiredCapabilities: _scenarioStringList(json['requiredCapabilities']),
      );
}

class RpgAttributeDefinition {
  final String id;
  final String label;
  final num initialValue;
  final num? minimum;
  final num? maximum;

  const RpgAttributeDefinition({
    required this.id,
    required this.label,
    this.initialValue = 0,
    this.minimum,
    this.maximum,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'initialValue': initialValue,
        if (minimum != null) 'minimum': minimum,
        if (maximum != null) 'maximum': maximum,
      };

  factory RpgAttributeDefinition.fromJson(Map<String, dynamic> json) =>
      RpgAttributeDefinition(
        id: json['id'] as String,
        label: json['label'] as String,
        initialValue: json['initialValue'] as num? ?? 0,
        minimum: json['minimum'] as num?,
        maximum: json['maximum'] as num?,
      );
}

class RpgItemDefinition {
  final String id;
  final String label;
  final String description;
  final bool stackable;

  const RpgItemDefinition({
    required this.id,
    required this.label,
    this.description = '',
    this.stackable = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (description.isNotEmpty) 'description': description,
        'stackable': stackable,
      };

  factory RpgItemDefinition.fromJson(Map<String, dynamic> json) =>
      RpgItemDefinition(
        id: json['id'] as String,
        label: json['label'] as String,
        description: json['description'] as String? ?? '',
        stackable: json['stackable'] as bool? ?? true,
      );
}

class RpgActorDefinition {
  final String id;
  final String label;

  const RpgActorDefinition({required this.id, required this.label});

  Map<String, dynamic> toJson() => {'id': id, 'label': label};

  factory RpgActorDefinition.fromJson(Map<String, dynamic> json) =>
      RpgActorDefinition(
        id: json['id'] as String,
        label: json['label'] as String,
      );
}

class RpgLocationDefinition {
  final String id;
  final String label;
  final String description;

  const RpgLocationDefinition({
    required this.id,
    required this.label,
    this.description = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (description.isNotEmpty) 'description': description,
      };

  factory RpgLocationDefinition.fromJson(Map<String, dynamic> json) =>
      RpgLocationDefinition(
        id: json['id'] as String,
        label: json['label'] as String,
        description: json['description'] as String? ?? '',
      );
}

class RpgQuestStageDefinition {
  final String id;
  final String label;
  final List<String> objectiveIds;

  const RpgQuestStageDefinition({
    required this.id,
    required this.label,
    this.objectiveIds = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (objectiveIds.isNotEmpty) 'objectiveIds': objectiveIds,
      };

  factory RpgQuestStageDefinition.fromJson(Map<String, dynamic> json) =>
      RpgQuestStageDefinition(
        id: json['id'] as String,
        label: json['label'] as String,
        objectiveIds: _scenarioStringList(json['objectiveIds']),
      );
}

class RpgQuestDefinition {
  final String id;
  final String label;
  final List<RpgQuestStageDefinition> stages;

  const RpgQuestDefinition({
    required this.id,
    required this.label,
    this.stages = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'stages': stages.map((stage) => stage.toJson()).toList(),
      };

  factory RpgQuestDefinition.fromJson(Map<String, dynamic> json) =>
      RpgQuestDefinition(
        id: json['id'] as String,
        label: json['label'] as String,
        stages: _scenarioMapList(
          json['stages'],
        ).map(RpgQuestStageDefinition.fromJson).toList(),
      );
}

/// Version 1 contract for a script-free, deterministic scenario package.
class RpgScenario {
  static const currentSchemaVersion = 1;

  static const defaultProtectedFields = <String>[
    'random.initialSeed',
    'random.state',
    'random.rollsConsumed',
    'turn',
    'inventory',
    'quests',
    'cooldowns',
    'eventHistory',
  ];

  final int schemaVersion;
  final RpgScenarioMetadata metadata;
  final int initialSeed;
  final RpgCompatibility compatibility;
  final List<String> protectedFields;
  final List<RpgAttributeDefinition> attributes;
  final List<RpgItemDefinition> items;
  final List<RpgActorDefinition> actors;
  final List<RpgLocationDefinition> locations;
  final List<RpgQuestDefinition> quests;
  final List<RpgActionDefinition> actions;
  final RpgRuntimeState initialState;

  const RpgScenario({
    this.schemaVersion = currentSchemaVersion,
    required this.metadata,
    required this.initialSeed,
    this.compatibility = const RpgCompatibility(),
    this.protectedFields = defaultProtectedFields,
    this.attributes = const [],
    this.items = const [],
    this.actors = const [],
    this.locations = const [],
    this.quests = const [],
    this.actions = const [],
    required this.initialState,
  });

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'metadata': metadata.toJson(),
        'initialSeed': initialSeed,
        'compatibility': compatibility.toJson(),
        'protectedFields': protectedFields,
        'attributes':
            attributes.map((attribute) => attribute.toJson()).toList(),
        'items': items.map((item) => item.toJson()).toList(),
        'actors': actors.map((actor) => actor.toJson()).toList(),
        'locations': locations.map((location) => location.toJson()).toList(),
        'quests': quests.map((quest) => quest.toJson()).toList(),
        'actions': actions.map((action) => action.toJson()).toList(),
        'initialState': initialState.toJson(),
      };

  factory RpgScenario.fromJson(Map<String, dynamic> json) => RpgScenario(
        schemaVersion: (json['schemaVersion'] as num).toInt(),
        metadata: RpgScenarioMetadata.fromJson(
          json['metadata'] as Map<String, dynamic>,
        ),
        initialSeed: (json['initialSeed'] as num).toInt(),
        compatibility: json['compatibility'] == null
            ? const RpgCompatibility()
            : RpgCompatibility.fromJson(
                json['compatibility'] as Map<String, dynamic>,
              ),
        protectedFields: json['protectedFields'] == null
            ? defaultProtectedFields
            : _scenarioStringList(json['protectedFields']),
        attributes: _scenarioMapList(
          json['attributes'],
        ).map(RpgAttributeDefinition.fromJson).toList(),
        items: _scenarioMapList(
          json['items'],
        ).map(RpgItemDefinition.fromJson).toList(),
        actors: _scenarioMapList(
          json['actors'],
        ).map(RpgActorDefinition.fromJson).toList(),
        locations: _scenarioMapList(
          json['locations'],
        ).map(RpgLocationDefinition.fromJson).toList(),
        quests: _scenarioMapList(
          json['quests'],
        ).map(RpgQuestDefinition.fromJson).toList(),
        actions: _scenarioMapList(
          json['actions'],
        ).map(RpgActionDefinition.fromJson).toList(),
        initialState: RpgRuntimeState.fromJson(
          json['initialState'] as Map<String, dynamic>,
        ),
      );
}

List<Map<String, dynamic>> _scenarioMapList(Object? value) =>
    (value as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item as Map<String, dynamic>)
        .toList();

List<String> _scenarioStringList(Object? value) =>
    (value as List<dynamic>? ?? const <dynamic>[]).cast<String>();

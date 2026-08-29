/// Deterministic random-generator inputs persisted with every runtime state.
class RpgRandomState {
  final int initialSeed;
  final int state;
  final int rollsConsumed;

  const RpgRandomState({
    required this.initialSeed,
    required this.state,
    this.rollsConsumed = 0,
  });

  Map<String, dynamic> toJson() => {
        'initialSeed': initialSeed,
        'state': state,
        'rollsConsumed': rollsConsumed,
      };

  factory RpgRandomState.fromJson(Map<String, dynamic> json) => RpgRandomState(
        initialSeed: (json['initialSeed'] as num).toInt(),
        state: (json['state'] as num).toInt(),
        rollsConsumed: (json['rollsConsumed'] as num?)?.toInt() ?? 0,
      );
}

class RpgInventoryEntry {
  final String itemId;
  final int quantity;
  final Map<String, Object?> metadata;

  const RpgInventoryEntry({
    required this.itemId,
    required this.quantity,
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'quantity': quantity,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  factory RpgInventoryEntry.fromJson(Map<String, dynamic> json) =>
      RpgInventoryEntry(
        itemId: json['itemId'] as String,
        quantity: (json['quantity'] as num).toInt(),
        metadata: _objectMap(json['metadata']),
      );
}

class RpgRelationshipState {
  final String actorId;
  final num score;
  final List<String> tags;

  const RpgRelationshipState({
    required this.actorId,
    this.score = 0,
    this.tags = const [],
  });

  Map<String, dynamic> toJson() => {
        'actorId': actorId,
        'score': score,
        if (tags.isNotEmpty) 'tags': tags,
      };

  factory RpgRelationshipState.fromJson(Map<String, dynamic> json) =>
      RpgRelationshipState(
        actorId: json['actorId'] as String,
        score: json['score'] as num? ?? 0,
        tags: _stringList(json['tags']),
      );
}

/// Scenario time represented without wall-clock or locale dependencies.
class RpgClockState {
  final int elapsedMinutes;
  final int day;
  final int minuteOfDay;

  const RpgClockState({
    this.elapsedMinutes = 0,
    this.day = 1,
    this.minuteOfDay = 0,
  });

  Map<String, dynamic> toJson() => {
        'elapsedMinutes': elapsedMinutes,
        'day': day,
        'minuteOfDay': minuteOfDay,
      };

  factory RpgClockState.fromJson(Map<String, dynamic> json) => RpgClockState(
        elapsedMinutes: (json['elapsedMinutes'] as num?)?.toInt() ?? 0,
        day: (json['day'] as num?)?.toInt() ?? 1,
        minuteOfDay: (json['minuteOfDay'] as num?)?.toInt() ?? 0,
      );
}

enum RpgQuestStatus {
  inactive,
  active,
  completed,
  failed;

  static RpgQuestStatus fromJson(String value) =>
      RpgQuestStatus.values.firstWhere((status) => status.name == value);
}

class RpgQuestState {
  final String questId;
  final RpgQuestStatus status;
  final String? stageId;
  final Map<String, int> objectiveProgress;

  const RpgQuestState({
    required this.questId,
    this.status = RpgQuestStatus.inactive,
    this.stageId,
    this.objectiveProgress = const {},
  });

  Map<String, dynamic> toJson() => {
        'questId': questId,
        'status': status.name,
        if (stageId != null) 'stageId': stageId,
        if (objectiveProgress.isNotEmpty)
          'objectiveProgress': objectiveProgress,
      };

  factory RpgQuestState.fromJson(Map<String, dynamic> json) => RpgQuestState(
        questId: json['questId'] as String,
        status: RpgQuestStatus.fromJson(
          json['status'] as String? ?? RpgQuestStatus.inactive.name,
        ),
        stageId: json['stageId'] as String?,
        objectiveProgress: _intMap(json['objectiveProgress']),
      );
}

class RpgEventRecord {
  final String id;
  final int turn;
  final String type;
  final String? actionId;
  final String summary;
  final Map<String, Object?> data;

  const RpgEventRecord({
    required this.id,
    required this.turn,
    required this.type,
    this.actionId,
    this.summary = '',
    this.data = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'turn': turn,
        'type': type,
        if (actionId != null) 'actionId': actionId,
        if (summary.isNotEmpty) 'summary': summary,
        if (data.isNotEmpty) 'data': data,
      };

  factory RpgEventRecord.fromJson(Map<String, dynamic> json) => RpgEventRecord(
        id: json['id'] as String,
        turn: (json['turn'] as num).toInt(),
        type: json['type'] as String,
        actionId: json['actionId'] as String?,
        summary: json['summary'] as String? ?? '',
        data: _objectMap(json['data']),
      );
}

/// All inputs needed to resume deterministic rule execution.
class RpgRuntimeState {
  final String scenarioId;
  final String scenarioVersion;
  final int turn;
  final RpgRandomState random;
  final Map<String, num> attributes;
  final Map<String, Object?> variables;
  final List<RpgInventoryEntry> inventory;
  final List<RpgRelationshipState> relationships;
  final RpgClockState clock;
  final String locationId;
  final List<RpgQuestState> quests;
  final Map<String, int> cooldowns;
  final List<RpgEventRecord> eventHistory;

  const RpgRuntimeState({
    required this.scenarioId,
    required this.scenarioVersion,
    this.turn = 0,
    required this.random,
    this.attributes = const {},
    this.variables = const {},
    this.inventory = const [],
    this.relationships = const [],
    this.clock = const RpgClockState(),
    this.locationId = '',
    this.quests = const [],
    this.cooldowns = const {},
    this.eventHistory = const [],
  });

  Map<String, dynamic> toJson() => {
        'scenarioId': scenarioId,
        'scenarioVersion': scenarioVersion,
        'turn': turn,
        'random': random.toJson(),
        'attributes': attributes,
        'variables': variables,
        'inventory': inventory.map((entry) => entry.toJson()).toList(),
        'relationships':
            relationships.map((relationship) => relationship.toJson()).toList(),
        'clock': clock.toJson(),
        'locationId': locationId,
        'quests': quests.map((quest) => quest.toJson()).toList(),
        'cooldowns': cooldowns,
        'eventHistory': eventHistory.map((event) => event.toJson()).toList(),
      };

  factory RpgRuntimeState.fromJson(Map<String, dynamic> json) =>
      RpgRuntimeState(
        scenarioId: json['scenarioId'] as String,
        scenarioVersion: json['scenarioVersion'] as String,
        turn: (json['turn'] as num?)?.toInt() ?? 0,
        random: RpgRandomState.fromJson(json['random'] as Map<String, dynamic>),
        attributes: _numMap(json['attributes']),
        variables: _objectMap(json['variables']),
        inventory: _mapList(
          json['inventory'],
        ).map(RpgInventoryEntry.fromJson).toList(),
        relationships: _mapList(
          json['relationships'],
        ).map(RpgRelationshipState.fromJson).toList(),
        clock: json['clock'] == null
            ? const RpgClockState()
            : RpgClockState.fromJson(json['clock'] as Map<String, dynamic>),
        locationId: json['locationId'] as String? ?? '',
        quests: _mapList(json['quests']).map(RpgQuestState.fromJson).toList(),
        cooldowns: _intMap(json['cooldowns']),
        eventHistory: _mapList(
          json['eventHistory'],
        ).map(RpgEventRecord.fromJson).toList(),
      );
}

/// Metadata needed to attach a snapshot to a rollback/branch graph.
class RpgSnapshotMetadata {
  final String id;
  final String scenarioId;
  final String scenarioVersion;
  final String branchId;
  final String? parentSnapshotId;
  final int turn;
  final int randomState;
  final int rollsConsumed;
  final DateTime createdAt;
  final String? stateHash;

  const RpgSnapshotMetadata({
    required this.id,
    required this.scenarioId,
    required this.scenarioVersion,
    required this.branchId,
    this.parentSnapshotId,
    required this.turn,
    required this.randomState,
    required this.rollsConsumed,
    required this.createdAt,
    this.stateHash,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'scenarioId': scenarioId,
        'scenarioVersion': scenarioVersion,
        'branchId': branchId,
        if (parentSnapshotId != null) 'parentSnapshotId': parentSnapshotId,
        'turn': turn,
        'randomState': randomState,
        'rollsConsumed': rollsConsumed,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (stateHash != null) 'stateHash': stateHash,
      };

  factory RpgSnapshotMetadata.fromJson(Map<String, dynamic> json) =>
      RpgSnapshotMetadata(
        id: json['id'] as String,
        scenarioId: json['scenarioId'] as String,
        scenarioVersion: json['scenarioVersion'] as String,
        branchId: json['branchId'] as String,
        parentSnapshotId: json['parentSnapshotId'] as String?,
        turn: (json['turn'] as num).toInt(),
        randomState: (json['randomState'] as num).toInt(),
        rollsConsumed: (json['rollsConsumed'] as num).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        stateHash: json['stateHash'] as String?,
      );
}

class RpgStateSnapshot {
  final RpgSnapshotMetadata metadata;
  final RpgRuntimeState state;

  const RpgStateSnapshot({required this.metadata, required this.state});

  Map<String, dynamic> toJson() => {
        'metadata': metadata.toJson(),
        'state': state.toJson(),
      };

  factory RpgStateSnapshot.fromJson(Map<String, dynamic> json) =>
      RpgStateSnapshot(
        metadata: RpgSnapshotMetadata.fromJson(
          json['metadata'] as Map<String, dynamic>,
        ),
        state: RpgRuntimeState.fromJson(json['state'] as Map<String, dynamic>),
      );
}

List<Map<String, dynamic>> _mapList(Object? value) =>
    (value as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item as Map<String, dynamic>)
        .toList();

List<String> _stringList(Object? value) =>
    (value as List<dynamic>? ?? const <dynamic>[]).cast<String>();

Map<String, Object?> _objectMap(Object? value) => Map<String, Object?>.from(
      value as Map<String, dynamic>? ?? const <String, dynamic>{},
    );

Map<String, int> _intMap(Object? value) =>
    (value as Map<String, dynamic>? ?? const <String, dynamic>{}).map(
      (key, item) => MapEntry(key, (item as num).toInt()),
    );

Map<String, num> _numMap(Object? value) =>
    (value as Map<String, dynamic>? ?? const <String, dynamic>{}).map(
      (key, item) => MapEntry(key, item as num),
    );

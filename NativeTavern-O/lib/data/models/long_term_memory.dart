import 'package:equatable/equatable.dart';

/// The semantic category of a long-term memory.
enum MemoryKind {
  personFact,
  relationship,
  event,
  commitment,
  preference,
  location,
  other,
}

/// The owner boundary used when querying a memory.
enum MemoryScopeKind { character, characterPersona, chat, group }

/// The review and lifecycle state of a memory.
enum MemoryState { candidate, active, superseded, forgotten }

/// Whether a memory was entered by a person or extracted by a model.
enum MemoryOrigin { manual, generated }

/// Identifies exactly one supported memory scope.
class MemoryScope extends Equatable {
  final MemoryScopeKind kind;
  final String? characterId;
  final String? personaId;
  final String? chatId;
  final String? groupId;

  const MemoryScope._({
    required this.kind,
    this.characterId,
    this.personaId,
    this.chatId,
    this.groupId,
  });

  factory MemoryScope({
    required MemoryScopeKind kind,
    String? characterId,
    String? personaId,
    String? chatId,
    String? groupId,
  }) {
    _validateOptionalId(characterId, 'characterId');
    _validateOptionalId(personaId, 'personaId');
    _validateOptionalId(chatId, 'chatId');
    _validateOptionalId(groupId, 'groupId');

    final valid = switch (kind) {
      MemoryScopeKind.character => characterId != null &&
          personaId == null &&
          chatId == null &&
          groupId == null,
      MemoryScopeKind.characterPersona => characterId != null &&
          personaId != null &&
          chatId == null &&
          groupId == null,
      MemoryScopeKind.chat => characterId == null &&
          personaId == null &&
          chatId != null &&
          groupId == null,
      MemoryScopeKind.group => characterId == null &&
          personaId == null &&
          chatId == null &&
          groupId != null,
    };
    if (!valid) {
      throw ArgumentError(
        'Scope ${kind.name} contains missing or incompatible IDs.',
      );
    }

    return MemoryScope._(
      kind: kind,
      characterId: characterId,
      personaId: personaId,
      chatId: chatId,
      groupId: groupId,
    );
  }

  factory MemoryScope.character(String characterId) {
    return MemoryScope(
      kind: MemoryScopeKind.character,
      characterId: characterId,
    );
  }

  factory MemoryScope.characterPersona({
    required String characterId,
    required String personaId,
  }) {
    return MemoryScope(
      kind: MemoryScopeKind.characterPersona,
      characterId: characterId,
      personaId: personaId,
    );
  }

  factory MemoryScope.chat(String chatId) {
    return MemoryScope(kind: MemoryScopeKind.chat, chatId: chatId);
  }

  factory MemoryScope.group(String groupId) {
    return MemoryScope(kind: MemoryScopeKind.group, groupId: groupId);
  }

  factory MemoryScope.fromJson(Map<String, dynamic> json) {
    return MemoryScope(
      kind: _enumFromJson(MemoryScopeKind.values, json['kind'], 'kind'),
      characterId: _optionalString(json, 'characterId'),
      personaId: _optionalString(json, 'personaId'),
      chatId: _optionalString(json, 'chatId'),
      groupId: _optionalString(json, 'groupId'),
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (characterId != null) 'characterId': characterId,
        if (personaId != null) 'personaId': personaId,
        if (chatId != null) 'chatId': chatId,
        if (groupId != null) 'groupId': groupId,
      };

  @override
  List<Object?> get props => [kind, characterId, personaId, chatId, groupId];
}

/// Source provenance retained for audit and candidate review.
class MemorySource extends Equatable {
  final MemoryOrigin origin;
  final String? sourceChatId;
  final List<String> sourceMessageIds;
  final DateTime? extractedAt;
  final String? providerId;
  final String? modelId;

  MemorySource._({
    required this.origin,
    required this.sourceChatId,
    required List<String> sourceMessageIds,
    required this.extractedAt,
    required this.providerId,
    required this.modelId,
  }) : sourceMessageIds = List.unmodifiable(sourceMessageIds);

  factory MemorySource({
    MemoryOrigin origin = MemoryOrigin.manual,
    String? sourceChatId,
    List<String> sourceMessageIds = const [],
    DateTime? extractedAt,
    String? providerId,
    String? modelId,
  }) {
    _validateOptionalId(sourceChatId, 'sourceChatId');
    _validateOptionalId(providerId, 'providerId');
    _validateOptionalId(modelId, 'modelId');
    _validateIdList(sourceMessageIds, 'sourceMessageIds');

    if (sourceMessageIds.isNotEmpty && sourceChatId == null) {
      throw ArgumentError(
        'sourceChatId is required when sourceMessageIds are provided.',
      );
    }
    if (sourceChatId != null && sourceMessageIds.isEmpty) {
      throw ArgumentError(
        'At least one sourceMessageId is required for a source chat.',
      );
    }
    if (extractedAt != null && sourceChatId == null) {
      throw ArgumentError(
        'extractedAt requires source chat and message provenance.',
      );
    }

    switch (origin) {
      case MemoryOrigin.manual:
        if (providerId != null || modelId != null) {
          throw ArgumentError(
            'Manual memories cannot declare a model provider or model.',
          );
        }
        break;
      case MemoryOrigin.generated:
        if (sourceChatId == null ||
            sourceMessageIds.isEmpty ||
            extractedAt == null ||
            providerId == null ||
            modelId == null) {
          throw ArgumentError(
            'Generated memories require source chat, source messages, '
            'extraction time, provider, and model.',
          );
        }
        break;
    }

    return MemorySource._(
      origin: origin,
      sourceChatId: sourceChatId,
      sourceMessageIds: sourceMessageIds,
      extractedAt: extractedAt,
      providerId: providerId,
      modelId: modelId,
    );
  }

  factory MemorySource.manual({
    String? sourceChatId,
    List<String> sourceMessageIds = const [],
    DateTime? extractedAt,
  }) {
    return MemorySource(
      sourceChatId: sourceChatId,
      sourceMessageIds: sourceMessageIds,
      extractedAt: extractedAt,
    );
  }

  factory MemorySource.generated({
    required String sourceChatId,
    required List<String> sourceMessageIds,
    required DateTime extractedAt,
    required String providerId,
    required String modelId,
  }) {
    return MemorySource(
      origin: MemoryOrigin.generated,
      sourceChatId: sourceChatId,
      sourceMessageIds: sourceMessageIds,
      extractedAt: extractedAt,
      providerId: providerId,
      modelId: modelId,
    );
  }

  factory MemorySource.fromJson(Map<String, dynamic> json) {
    return MemorySource(
      origin: _enumFromJson(
        MemoryOrigin.values,
        json['origin'],
        'origin',
        defaultValue: MemoryOrigin.manual,
      ),
      sourceChatId: _optionalString(json, 'sourceChatId'),
      sourceMessageIds: _stringList(json, 'sourceMessageIds'),
      extractedAt: _optionalDateTime(json, 'extractedAt'),
      providerId: _optionalString(json, 'providerId'),
      modelId: _optionalString(json, 'modelId'),
    );
  }

  Map<String, dynamic> toJson() => {
        'origin': origin.name,
        if (sourceChatId != null) 'sourceChatId': sourceChatId,
        'sourceMessageIds': sourceMessageIds,
        if (extractedAt != null) 'extractedAt': extractedAt!.toIso8601String(),
        if (providerId != null) 'providerId': providerId,
        if (modelId != null) 'modelId': modelId,
      };

  @override
  List<Object?> get props => [
        origin,
        sourceChatId,
        sourceMessageIds,
        extractedAt,
        providerId,
        modelId,
      ];
}

/// An inspectable, storage-independent long-term memory record.
class LongTermMemory extends Equatable {
  static const defaultImportance = 0.5;
  static const defaultConfidence = 0.5;

  final String id;
  final MemoryKind kind;
  final MemoryScope scope;
  final MemoryState state;
  final String content;
  final MemorySource source;
  final double importance;
  final double confidence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? expiresAt;
  final bool locked;
  final String normalizedIdentityKey;

  /// The replacement record when this memory is [MemoryState.superseded].
  final String? supersededByMemoryId;

  const LongTermMemory._({
    required this.id,
    required this.kind,
    required this.scope,
    required this.state,
    required this.content,
    required this.source,
    required this.importance,
    required this.confidence,
    required this.createdAt,
    required this.updatedAt,
    required this.expiresAt,
    required this.locked,
    required this.normalizedIdentityKey,
    required this.supersededByMemoryId,
  });

  factory LongTermMemory({
    required String id,
    required MemoryKind kind,
    required MemoryScope scope,
    MemoryState state = MemoryState.candidate,
    required String content,
    MemorySource? source,
    double importance = defaultImportance,
    double confidence = defaultConfidence,
    required DateTime createdAt,
    DateTime? updatedAt,
    DateTime? expiresAt,
    bool locked = false,
    String? normalizedIdentityKey,
    String? supersededByMemoryId,
  }) {
    _validateRequiredString(id, 'id');
    _validateRequiredString(content, 'content');
    _validateOptionalId(supersededByMemoryId, 'supersededByMemoryId');
    _validateUnitInterval(importance, 'importance');
    _validateUnitInterval(confidence, 'confidence');

    final effectiveUpdatedAt = updatedAt ?? createdAt;
    final effectiveIdentityKey = normalizedIdentityKey ?? id;
    final effectiveSource = source ?? MemorySource.manual();
    _validateRequiredString(effectiveIdentityKey, 'normalizedIdentityKey');

    if (effectiveUpdatedAt.isBefore(createdAt)) {
      throw ArgumentError('updatedAt cannot be before createdAt.');
    }
    if (expiresAt != null && !expiresAt.isAfter(createdAt)) {
      throw ArgumentError('expiresAt must be after createdAt.');
    }
    if (effectiveSource.extractedAt?.isAfter(createdAt) ?? false) {
      throw ArgumentError('Source extraction time cannot be after createdAt.');
    }
    if (supersededByMemoryId == id) {
      throw ArgumentError('A memory cannot supersede itself.');
    }
    if (state == MemoryState.superseded && supersededByMemoryId == null) {
      throw ArgumentError(
        'A superseded memory must reference its replacement.',
      );
    }
    if (state != MemoryState.superseded && supersededByMemoryId != null) {
      throw ArgumentError(
        'Only superseded memories can reference a replacement.',
      );
    }

    return LongTermMemory._(
      id: id,
      kind: kind,
      scope: scope,
      state: state,
      content: content,
      source: effectiveSource,
      importance: importance,
      confidence: confidence,
      createdAt: createdAt,
      updatedAt: effectiveUpdatedAt,
      expiresAt: expiresAt,
      locked: locked,
      normalizedIdentityKey: effectiveIdentityKey,
      supersededByMemoryId: supersededByMemoryId,
    );
  }

  factory LongTermMemory.fromJson(Map<String, dynamic> json) {
    final createdAt = _requiredDateTime(json, 'createdAt');
    final id = _requiredString(json, 'id');
    final sourceJson = json['source'];
    final scopeJson = json['scope'];
    if (scopeJson is! Map<String, dynamic>) {
      throw const FormatException('scope must be a JSON object.');
    }
    late final MemorySource source;
    if (sourceJson == null) {
      source = MemorySource.manual();
    } else if (sourceJson is Map<String, dynamic>) {
      source = MemorySource.fromJson(sourceJson);
    } else {
      throw const FormatException('source must be a JSON object.');
    }

    return LongTermMemory(
      id: id,
      kind: _enumFromJson(MemoryKind.values, json['kind'], 'kind'),
      scope: MemoryScope.fromJson(scopeJson),
      state: _enumFromJson(
        MemoryState.values,
        json['state'],
        'state',
        defaultValue: MemoryState.candidate,
      ),
      content: _requiredString(json, 'content'),
      source: source,
      importance: _doubleValue(
        json,
        'importance',
        defaultValue: defaultImportance,
      ),
      confidence: _doubleValue(
        json,
        'confidence',
        defaultValue: defaultConfidence,
      ),
      createdAt: createdAt,
      updatedAt: _optionalDateTime(json, 'updatedAt') ?? createdAt,
      expiresAt: _optionalDateTime(json, 'expiresAt'),
      locked: _boolValue(json, 'locked', defaultValue: false),
      normalizedIdentityKey:
          _optionalString(json, 'normalizedIdentityKey') ?? id,
      supersededByMemoryId: _optionalString(json, 'supersededByMemoryId'),
    );
  }

  bool isExpiredAt(DateTime instant) {
    final expiry = expiresAt;
    return expiry != null && !instant.isBefore(expiry);
  }

  LongTermMemory copyWith({
    String? id,
    MemoryKind? kind,
    MemoryScope? scope,
    MemoryState? state,
    String? content,
    MemorySource? source,
    double? importance,
    double? confidence,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? expiresAt,
    bool clearExpiresAt = false,
    bool? locked,
    String? normalizedIdentityKey,
    String? supersededByMemoryId,
    bool clearSupersededByMemoryId = false,
  }) {
    return LongTermMemory(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      scope: scope ?? this.scope,
      state: state ?? this.state,
      content: content ?? this.content,
      source: source ?? this.source,
      importance: importance ?? this.importance,
      confidence: confidence ?? this.confidence,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
      locked: locked ?? this.locked,
      normalizedIdentityKey:
          normalizedIdentityKey ?? this.normalizedIdentityKey,
      supersededByMemoryId: clearSupersededByMemoryId
          ? null
          : (supersededByMemoryId ?? this.supersededByMemoryId),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'scope': scope.toJson(),
        'state': state.name,
        'content': content,
        'source': source.toJson(),
        'importance': importance,
        'confidence': confidence,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
        'locked': locked,
        'normalizedIdentityKey': normalizedIdentityKey,
        if (supersededByMemoryId != null)
          'supersededByMemoryId': supersededByMemoryId,
      };

  @override
  List<Object?> get props => [
        id,
        kind,
        scope,
        state,
        content,
        source,
        importance,
        confidence,
        createdAt,
        updatedAt,
        expiresAt,
        locked,
        normalizedIdentityKey,
        supersededByMemoryId,
      ];
}

T _enumFromJson<T extends Enum>(
  List<T> values,
  Object? value,
  String fieldName, {
  T? defaultValue,
}) {
  if (value == null && defaultValue != null) return defaultValue;
  if (value is String) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
  }
  throw FormatException('$fieldName has an unsupported value: $value');
}

String _requiredString(Map<String, dynamic> json, String fieldName) {
  final value = json[fieldName];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$fieldName must be a non-empty string.');
  }
  return value;
}

String? _optionalString(Map<String, dynamic> json, String fieldName) {
  final value = json[fieldName];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$fieldName must be a non-empty string when set.');
  }
  return value;
}

List<String> _stringList(Map<String, dynamic> json, String fieldName) {
  final value = json[fieldName];
  if (value == null) return const [];
  if (value is! List<dynamic> || value.any((item) => item is! String)) {
    throw FormatException('$fieldName must be a list of strings.');
  }
  return value.cast<String>();
}

DateTime _requiredDateTime(Map<String, dynamic> json, String fieldName) {
  final parsed = _optionalDateTime(json, fieldName);
  if (parsed == null) {
    throw FormatException('$fieldName must be an ISO-8601 date-time.');
  }
  return parsed;
}

DateTime? _optionalDateTime(Map<String, dynamic> json, String fieldName) {
  final value = json[fieldName];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$fieldName must be an ISO-8601 date-time.');
  }
  try {
    return DateTime.parse(value);
  } on FormatException {
    throw FormatException('$fieldName must be an ISO-8601 date-time.');
  }
}

double _doubleValue(
  Map<String, dynamic> json,
  String fieldName, {
  required double defaultValue,
}) {
  final value = json[fieldName];
  if (value == null) return defaultValue;
  if (value is! num) {
    throw FormatException('$fieldName must be numeric.');
  }
  return value.toDouble();
}

bool _boolValue(
  Map<String, dynamic> json,
  String fieldName, {
  required bool defaultValue,
}) {
  final value = json[fieldName];
  if (value == null) return defaultValue;
  if (value is! bool) {
    throw FormatException('$fieldName must be a boolean.');
  }
  return value;
}

void _validateRequiredString(String value, String fieldName) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, fieldName, 'must not be empty');
  }
}

void _validateOptionalId(String? value, String fieldName) {
  if (value != null) _validateRequiredString(value, fieldName);
}

void _validateIdList(List<String> values, String fieldName) {
  for (final value in values) {
    _validateRequiredString(value, fieldName);
  }
  if (values.toSet().length != values.length) {
    throw ArgumentError.value(values, fieldName, 'must not contain duplicates');
  }
}

void _validateUnitInterval(double value, String fieldName) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw ArgumentError.value(value, fieldName, 'must be between 0 and 1');
  }
}

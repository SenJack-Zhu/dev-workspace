import 'package:drift/drift.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/domain/repositories/long_term_memory_repository.dart';

class DriftLongTermMemoryRepository implements LongTermMemoryRepository {
  DriftLongTermMemoryRepository(
    this._database, {
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final AppDatabase _database;
  final DateTime Function() _now;

  @override
  Future<LongTermMemory?> getById(String id) async {
    final row = await (_database.select(_database.longTermMemories)
          ..where((table) => table.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<LongTermMemory> create(LongTermMemory memory) async {
    return (await createAll([memory])).single;
  }

  @override
  Future<List<LongTermMemory>> createAll(
    List<LongTermMemory> memories,
  ) async {
    if (memories.isEmpty) return const [];
    await _database.transaction(() async {
      for (final memory in memories) {
        await _database.into(_database.longTermMemories).insert(
              _toCompanion(memory),
            );
        await _insertSourceMessages(memory);
      }
    });
    return Future.wait(
      memories.map((memory) async => (await getById(memory.id))!),
    );
  }

  @override
  Future<LongTermMemory> update(LongTermMemory memory) async {
    await _require(memory.id);
    await _database.transaction(() async {
      await (_database.delete(_database.longTermMemorySourceMessages)
            ..where((table) => table.memoryId.equals(memory.id)))
          .go();
      await (_database.update(_database.longTermMemories)
            ..where((table) => table.id.equals(memory.id)))
          .write(_toCompanion(memory));
      await _insertSourceMessages(memory);
    });
    return (await getById(memory.id))!;
  }

  @override
  Future<void> delete(String id) async {
    await (_database.delete(_database.longTermMemories)
          ..where((table) => table.id.equals(id)))
        .go();
  }

  @override
  Future<List<LongTermMemory>> findByScope(
    MemoryScope scope, {
    Set<MemoryState> states = const <MemoryState>{},
    bool includeExpired = false,
    DateTime? at,
  }) async {
    final query = _database.select(_database.longTermMemories)
      ..where((table) => _scopeExpression(table, scope));
    if (states.isNotEmpty) {
      query.where((table) => table.state.isIn(states.map((e) => e.name)));
    }
    if (!includeExpired) {
      final instant = at ?? _now();
      query.where(
        (table) =>
            table.expiresAt.isNull() |
            table.expiresAt.isBiggerThanValue(instant),
      );
    }
    query.orderBy([(table) => OrderingTerm.asc(table.id)]);
    final rows = await query.get();
    return Future.wait(rows.map(_toModel));
  }

  @override
  Future<List<LongTermMemory>> findBySource({
    required String chatId,
    String? messageId,
  }) async {
    Iterable<String>? memoryIds;
    if (messageId != null) {
      final sources = await (_database.select(
        _database.longTermMemorySourceMessages,
      )..where((table) => table.messageId.equals(messageId)))
          .get();
      memoryIds = sources.map((row) => row.memoryId);
      if (memoryIds.isEmpty) return const [];
    }

    final query = _database.select(_database.longTermMemories)
      ..where((table) => table.sourceChatId.equals(chatId));
    if (memoryIds != null) {
      query.where((table) => table.id.isIn(memoryIds!));
    }
    query.orderBy([(table) => OrderingTerm.asc(table.id)]);
    final rows = await query.get();
    return Future.wait(rows.map(_toModel));
  }

  @override
  Future<List<LongTermMemory>> findByStates(
    Set<MemoryState> states, {
    bool includeExpired = true,
    DateTime? at,
  }) async {
    final query = _database.select(_database.longTermMemories);
    if (states.isNotEmpty) {
      query.where(
          (table) => table.state.isIn(states.map((state) => state.name)));
    }
    if (!includeExpired) {
      final instant = at ?? _now();
      query.where(
        (table) =>
            table.expiresAt.isNull() |
            table.expiresAt.isBiggerThanValue(instant),
      );
    }
    query.orderBy([
      (table) => OrderingTerm.desc(table.updatedAt),
      (table) => OrderingTerm.asc(table.id),
    ]);
    final rows = await query.get();
    return Future.wait(rows.map(_toModel));
  }

  @override
  Future<List<LongTermMemorySearchResult>> search(
    String query, {
    required MemoryScope scope,
    int topK = 20,
    Set<MemoryState> states = const <MemoryState>{MemoryState.active},
    bool includeExpired = false,
    DateTime? at,
  }) async {
    if (topK <= 0) {
      throw RangeError.range(topK, 1, null, 'topK');
    }
    final matchQuery = _plainTextFtsQuery(query);
    if (matchQuery == null) return const [];

    final conditions = <String>[
      'long_term_memories_fts MATCH ?',
      'm.scope_kind = ?',
    ];
    final variables = <Variable<Object>>[
      Variable<String>(matchQuery),
      Variable<String>(scope.kind.name),
    ];
    switch (scope.kind) {
      case MemoryScopeKind.character:
        conditions.add('m.character_id = ?');
        variables.add(Variable<String>(scope.characterId!));
      case MemoryScopeKind.characterPersona:
        conditions.add('m.character_id = ?');
        conditions.add('m.persona_id = ?');
        variables.add(Variable<String>(scope.characterId!));
        variables.add(Variable<String>(scope.personaId!));
      case MemoryScopeKind.chat:
        conditions.add('m.chat_id = ?');
        variables.add(Variable<String>(scope.chatId!));
      case MemoryScopeKind.group:
        conditions.add('m.group_id = ?');
        variables.add(Variable<String>(scope.groupId!));
    }

    if (states.isNotEmpty) {
      final orderedStates = states.toList()
        ..sort((left, right) => left.index.compareTo(right.index));
      conditions.add(
        'm.state IN (${List.filled(orderedStates.length, '?').join(', ')})',
      );
      variables.addAll(
        orderedStates.map((state) => Variable<String>(state.name)),
      );
    }
    if (!includeExpired) {
      conditions.add('(m.expires_at IS NULL OR m.expires_at > ?)');
      variables.add(Variable<DateTime>((at ?? _now()).toUtc()));
    }
    variables.add(Variable<int>(topK));

    final rows = await _database
        .customSelect(
          '''
        SELECT m.id AS memory_id, bm25(long_term_memories_fts) AS rank
        FROM long_term_memories_fts
        JOIN long_term_memories AS m
          ON m.rowid = long_term_memories_fts.rowid
        WHERE ${conditions.join(' AND ')}
        ORDER BY bm25(long_term_memories_fts) ASC,
                 m.importance DESC,
                 m.updated_at DESC,
                 m.id ASC
        LIMIT ?
      ''',
          variables: variables,
          readsFrom: {_database.longTermMemories},
        )
        .get();

    final results = <LongTermMemorySearchResult>[];
    for (final row in rows) {
      final memoryId = row.read<String>('memory_id');
      final memory = await getById(memoryId);
      if (memory == null) {
        throw StateError('FTS index references missing memory $memoryId.');
      }
      results.add(
        LongTermMemorySearchResult(
          memory: memory,
          rank: row.read<double>('rank'),
        ),
      );
    }
    return results;
  }

  @override
  Future<void> rebuildSearchIndex() {
    return _database.rebuildLongTermMemorySearchIndex();
  }

  @override
  Future<LongTermMemory> resolve(
    LongTermMemory resolved, {
    Set<String> supersededMemoryIds = const <String>{},
  }) async {
    if (resolved.state != MemoryState.active) {
      throw ArgumentError('A resolved memory must be active.');
    }
    if (supersededMemoryIds.contains(resolved.id)) {
      throw ArgumentError('A memory cannot supersede itself.');
    }

    await _database.transaction(() async {
      final priorRows = supersededMemoryIds.isEmpty
          ? <LongTermMemoryRow>[]
          : await (_database.select(_database.longTermMemories)
                ..where((table) => table.id.isIn(supersededMemoryIds)))
              .get();
      final found = priorRows.map((row) => row.id).toSet();
      final missing = supersededMemoryIds.difference(found);
      if (missing.isNotEmpty) {
        throw StateError('Memory ${missing.first} does not exist.');
      }
      for (final row in priorRows) {
        if (row.locked) {
          throw StateError('Locked memory ${row.id} cannot be replaced.');
        }
        if (!_rowHasScope(row, resolved.scope)) {
          throw StateError('Memory ${row.id} has a different scope.');
        }
      }

      final existing = await (_database.select(_database.longTermMemories)
            ..where((table) => table.id.equals(resolved.id)))
          .getSingleOrNull();
      if (existing == null) {
        await _database.into(_database.longTermMemories).insert(
              _toCompanion(resolved),
            );
      } else {
        await (_database.delete(_database.longTermMemorySourceMessages)
              ..where((table) => table.memoryId.equals(resolved.id)))
            .go();
        await (_database.update(_database.longTermMemories)
              ..where((table) => table.id.equals(resolved.id)))
            .write(_toCompanion(resolved));
      }
      await _insertSourceMessages(resolved);

      if (supersededMemoryIds.isNotEmpty) {
        await (_database.update(_database.longTermMemories)
              ..where((table) => table.id.isIn(supersededMemoryIds)))
            .write(
          LongTermMemoriesCompanion(
            state: const Value('superseded'),
            supersededByMemoryId: Value(resolved.id),
            updatedAt: Value(_now()),
          ),
        );
      }
    });
    return (await getById(resolved.id))!;
  }

  @override
  Future<void> updateStates({
    required Set<String> memoryIds,
    required MemoryState state,
    String? supersededByMemoryId,
  }) async {
    if (memoryIds.isEmpty) return;
    if ((state == MemoryState.superseded) != (supersededByMemoryId != null)) {
      throw ArgumentError(
        'Only superseded memories require a replacement memory ID.',
      );
    }
    if (supersededByMemoryId != null) {
      await _require(supersededByMemoryId);
      if (memoryIds.contains(supersededByMemoryId)) {
        throw ArgumentError('A memory cannot supersede itself.');
      }
    }

    await _database.transaction(() async {
      final rows = await (_database.select(_database.longTermMemories)
            ..where((table) => table.id.isIn(memoryIds)))
          .get();
      final found = rows.map((row) => row.id).toSet();
      final missing = memoryIds.difference(found);
      if (missing.isNotEmpty) {
        throw StateError('Memory ${missing.first} does not exist.');
      }
      await (_database.update(_database.longTermMemories)
            ..where((table) => table.id.isIn(memoryIds)))
          .write(
        LongTermMemoriesCompanion(
          state: Value(state.name),
          supersededByMemoryId: Value(supersededByMemoryId),
          updatedAt: Value(_now()),
        ),
      );
    });
  }

  Expression<bool> _scopeExpression(
    LongTermMemories table,
    MemoryScope scope,
  ) {
    final kind = table.scopeKind.equals(scope.kind.name);
    return switch (scope.kind) {
      MemoryScopeKind.character =>
        kind & table.characterId.equals(scope.characterId!),
      MemoryScopeKind.characterPersona => kind &
          table.characterId.equals(scope.characterId!) &
          table.personaId.equals(scope.personaId!),
      MemoryScopeKind.chat => kind & table.chatId.equals(scope.chatId!),
      MemoryScopeKind.group => kind & table.groupId.equals(scope.groupId!),
    };
  }

  bool _rowHasScope(LongTermMemoryRow row, MemoryScope scope) {
    return row.scopeKind == scope.kind.name &&
        row.characterId == scope.characterId &&
        row.personaId == scope.personaId &&
        row.chatId == scope.chatId &&
        row.groupId == scope.groupId;
  }

  Future<void> _insertSourceMessages(LongTermMemory memory) async {
    for (final entry in memory.source.sourceMessageIds.indexed) {
      await _database.into(_database.longTermMemorySourceMessages).insert(
            LongTermMemorySourceMessagesCompanion.insert(
              memoryId: memory.id,
              messageId: entry.$2,
              ordinal: entry.$1,
            ),
          );
    }
  }

  Future<LongTermMemory> _toModel(LongTermMemoryRow row) async {
    final sourceRows = await (_database.select(
      _database.longTermMemorySourceMessages,
    )
          ..where((table) => table.memoryId.equals(row.id))
          ..orderBy([(table) => OrderingTerm.asc(table.ordinal)]))
        .get();
    final source = MemorySource(
      origin: _enumByName(MemoryOrigin.values, row.sourceOrigin),
      sourceChatId: row.sourceChatId,
      sourceMessageIds: sourceRows.map((entry) => entry.messageId).toList(),
      extractedAt: row.extractedAt?.toUtc(),
      providerId: row.providerId,
      modelId: row.modelId,
    );
    return LongTermMemory(
      id: row.id,
      kind: _enumByName(MemoryKind.values, row.kind),
      scope: MemoryScope(
        kind: _enumByName(MemoryScopeKind.values, row.scopeKind),
        characterId: row.characterId,
        personaId: row.personaId,
        chatId: row.chatId,
        groupId: row.groupId,
      ),
      state: _enumByName(MemoryState.values, row.state),
      content: row.content,
      source: source,
      importance: row.importance,
      confidence: row.confidence,
      createdAt: row.createdAt.toUtc(),
      updatedAt: row.updatedAt.toUtc(),
      expiresAt: row.expiresAt?.toUtc(),
      locked: row.locked,
      normalizedIdentityKey: row.normalizedIdentityKey,
      supersededByMemoryId: row.supersededByMemoryId,
    );
  }

  LongTermMemoriesCompanion _toCompanion(LongTermMemory memory) {
    return LongTermMemoriesCompanion(
      id: Value(memory.id),
      kind: Value(memory.kind.name),
      scopeKind: Value(memory.scope.kind.name),
      characterId: Value(memory.scope.characterId),
      personaId: Value(memory.scope.personaId),
      chatId: Value(memory.scope.chatId),
      groupId: Value(memory.scope.groupId),
      state: Value(memory.state.name),
      content: Value(memory.content),
      sourceOrigin: Value(memory.source.origin.name),
      sourceChatId: Value(memory.source.sourceChatId),
      extractedAt: Value(memory.source.extractedAt),
      providerId: Value(memory.source.providerId),
      modelId: Value(memory.source.modelId),
      importance: Value(memory.importance),
      confidence: Value(memory.confidence),
      createdAt: Value(memory.createdAt),
      updatedAt: Value(memory.updatedAt),
      expiresAt: Value(memory.expiresAt),
      locked: Value(memory.locked),
      normalizedIdentityKey: Value(memory.normalizedIdentityKey),
      supersededByMemoryId: Value(memory.supersededByMemoryId),
    );
  }

  Future<void> _require(String id) async {
    if (await getById(id) == null) {
      throw StateError('Memory $id does not exist.');
    }
  }
}

String? _plainTextFtsQuery(String input) {
  final tokens = RegExp(
    r'[\p{L}\p{N}]+',
    unicode: true,
  ).allMatches(input).map((match) => match.group(0)!).toList();
  if (tokens.isEmpty) return null;
  return tokens.map((token) => '"$token"*').join(' AND ');
}

T _enumByName<T extends Enum>(Iterable<T> values, String name) {
  return values.firstWhere(
    (value) => value.name == name,
    orElse: () => throw StateError('Unsupported persisted enum value: $name'),
  );
}

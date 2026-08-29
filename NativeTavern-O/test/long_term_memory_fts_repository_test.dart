import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/repositories/drift_long_term_memory_repository.dart';

void main() {
  final now = DateTime.utc(2026, 8, 8, 12);
  late AppDatabase database;
  late DriftLongTermMemoryRepository repository;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    await _seedOwners(database);
    repository = DriftLongTermMemoryRepository(database, now: () => now);
  });

  tearDown(() => database.close());

  test('CRUD keeps FTS synchronized and returns complete provenance', () async {
    final original = _memory(
      id: 'memory-crud',
      scope: MemoryScope.characterPersona(
        characterId: 'character-1',
        personaId: 'persona-1',
      ),
      content: 'Meet at the station.',
      normalizedIdentityKey: 'commitment:railway',
      source: MemorySource.generated(
        sourceChatId: 'chat-1',
        sourceMessageIds: const ['message-1', 'message-2'],
        extractedAt: now.subtract(const Duration(minutes: 1)),
        providerId: 'provider-1',
        modelId: 'model-1',
      ),
    );

    await repository.create(original);
    var matches = await repository.search('station', scope: original.scope);
    expect(matches.map((result) => result.memory), [original]);
    expect(
      matches.single.memory.source.sourceMessageIds,
      ['message-1', 'message-2'],
    );
    expect(
      (await repository.search('rail', scope: original.scope)).single.memory.id,
      original.id,
    );

    final updated = original.copyWith(
      content: 'Meet at the library.',
      updatedAt: now.add(const Duration(minutes: 1)),
      locked: true,
    );
    await repository.update(updated);
    expect(await repository.search('station', scope: original.scope), isEmpty);
    matches = await repository.search('library', scope: original.scope);
    expect(matches.single.memory, updated);
    expect(matches.single.memory.locked, isTrue);

    await repository.updateStates(
      memoryIds: {original.id},
      state: MemoryState.forgotten,
    );
    expect(await repository.search('library', scope: original.scope), isEmpty);
    await repository.updateStates(
      memoryIds: {original.id},
      state: MemoryState.active,
    );
    expect(
      (await repository.search('library', scope: original.scope))
          .single
          .memory
          .state,
      MemoryState.active,
    );

    await repository.delete(original.id);
    expect(await repository.search('library', scope: original.scope), isEmpty);
  });

  test('plain-text normalization contains FTS operators and invalid limits',
      () async {
    final scope = MemoryScope.character('character-1');
    await repository.create(
      _memory(
        id: 'memory-normalized-query',
        scope: scope,
        content: 'station secret',
      ),
    );

    expect(
      await repository.search('station OR absent', scope: scope),
      isEmpty,
    );
    expect(await repository.search('" ) ( *', scope: scope), isEmpty);
    await expectLater(
      repository.search('station', scope: scope, topK: 0),
      throwsRangeError,
    );
  });

  test('scope, lifecycle, and expiry filters prevent incorrect recall',
      () async {
    final scopes = <MemoryScope>[
      MemoryScope.character('character-1'),
      MemoryScope.characterPersona(
        characterId: 'character-1',
        personaId: 'persona-1',
      ),
      MemoryScope.chat('chat-1'),
      MemoryScope.group('group-1'),
    ];
    for (final (index, scope) in scopes.indexed) {
      await repository.create(
        _memory(
          id: 'scope-$index',
          scope: scope,
          content: 'scope sentinel',
        ),
      );
    }

    for (final (index, scope) in scopes.indexed) {
      final matches = await repository.search('sentinel', scope: scope);
      expect(matches.map((result) => result.memory.id), ['scope-$index']);
    }

    final characterScope = scopes.first;
    await repository.create(
      _memory(
        id: 'candidate',
        scope: characterScope,
        content: 'lifecycle sentinel',
        state: MemoryState.candidate,
      ),
    );
    await repository.create(
      _memory(
        id: 'forgotten',
        scope: characterScope,
        content: 'lifecycle sentinel',
        state: MemoryState.forgotten,
      ),
    );
    await repository.create(
      _memory(
        id: 'replacement',
        scope: characterScope,
        content: 'replacement without the query term',
      ),
    );
    await repository.create(
      _memory(
        id: 'superseded',
        scope: characterScope,
        content: 'lifecycle sentinel',
        state: MemoryState.superseded,
        supersededByMemoryId: 'replacement',
      ),
    );
    await repository.create(
      _memory(
        id: 'expired',
        scope: characterScope,
        content: 'lifecycle sentinel',
        createdAt: now.subtract(const Duration(days: 2)),
        expiresAt: now.subtract(const Duration(hours: 1)),
      ),
    );

    expect(
      await repository.search('lifecycle', scope: characterScope),
      isEmpty,
    );
    expect(
      (await repository.search(
        'lifecycle',
        scope: characterScope,
        states: const {MemoryState.candidate},
      ))
          .single
          .memory
          .id,
      'candidate',
    );
    expect(
      (await repository.search(
        'lifecycle',
        scope: characterScope,
        includeExpired: true,
      ))
          .single
          .memory
          .id,
      'expired',
    );
  });

  test('BM25 ties use importance, update time, and id deterministically',
      () async {
    final scope = MemoryScope.character('character-1');
    final createdAt = now.subtract(const Duration(days: 2));
    final fixtures = [
      _memory(
        id: 'rank-important',
        scope: scope,
        content: 'shared ranking token',
        normalizedIdentityKey: 'same-key',
        importance: 0.9,
        createdAt: createdAt,
      ),
      _memory(
        id: 'rank-newer',
        scope: scope,
        content: 'shared ranking token',
        normalizedIdentityKey: 'same-key',
        updatedAt: now,
        createdAt: createdAt,
      ),
      _memory(
        id: 'rank-b',
        scope: scope,
        content: 'shared ranking token',
        normalizedIdentityKey: 'same-key',
        createdAt: createdAt,
      ),
      _memory(
        id: 'rank-a',
        scope: scope,
        content: 'shared ranking token',
        normalizedIdentityKey: 'same-key',
        createdAt: createdAt,
      ),
    ];
    for (final fixture in fixtures) {
      await repository.create(fixture);
    }

    final ids = (await repository.search('shared', scope: scope))
        .map((result) => result.memory.id)
        .toList();
    expect(
      ids,
      ['rank-important', 'rank-newer', 'rank-a', 'rank-b'],
    );
  });

  test('BM25 relevance is applied before memory importance', () async {
    final scope = MemoryScope.character('character-1');
    await repository.create(
      _memory(
        id: 'bm25-concise',
        scope: scope,
        content: 'orchid',
        normalizedIdentityKey: 'same-key',
        importance: 0,
      ),
    );
    await repository.create(
      _memory(
        id: 'bm25-verbose',
        scope: scope,
        content:
            'orchid with many unrelated filler words that dilute relevance',
        normalizedIdentityKey: 'same-key',
        importance: 1,
      ),
    );

    final matches = await repository.search('orchid', scope: scope);

    expect(
      matches.map((result) => result.memory.id),
      ['bm25-concise', 'bm25-verbose'],
    );
    expect(matches.first.rank, lessThan(matches.last.rank));
  });

  test('rebuild recovers a missing derived index', () async {
    final scope = MemoryScope.character('character-1');
    await repository.create(
      _memory(
        id: 'memory-rebuild',
        scope: scope,
        content: 'recoverable archive',
      ),
    );
    await database.customStatement('DROP TABLE long_term_memories_fts');

    await repository.rebuildSearchIndex();

    expect(
      (await repository.search('recoverable', scope: scope)).single.memory.id,
      'memory-rebuild',
    );
  });

  test('failed repository transaction rolls back the FTS write', () async {
    final scope = MemoryScope.character('character-1');
    final memory = _memory(
      id: 'memory-rollback',
      scope: scope,
      content: 'transaction sentinel',
      source: MemorySource.generated(
        sourceChatId: 'chat-1',
        sourceMessageIds: const ['missing-message'],
        extractedAt: now.subtract(const Duration(minutes: 1)),
        providerId: 'provider-1',
        modelId: 'model-1',
      ),
    );

    await expectLater(repository.create(memory), throwsA(anything));

    expect(await repository.getById(memory.id), isNull);
    expect(await repository.search('transaction', scope: scope), isEmpty);
  });

  test('1001-memory fixture has repeatable Top-K performance', () async {
    final createdAt = now.subtract(const Duration(days: 1));
    final fixtures = List.generate(
      1001,
      (index) => LongTermMemoriesCompanion.insert(
        id: 'bulk-${index.toString().padLeft(4, '0')}',
        kind: MemoryKind.other.name,
        scopeKind: MemoryScopeKind.character.name,
        characterId: const Value('character-1'),
        state: MemoryState.active.name,
        content: index == 777
            ? 'performance needle target'
            : 'repeatable ordinary fixture $index',
        sourceOrigin: MemoryOrigin.manual.name,
        importance: 0.5,
        confidence: 0.5,
        createdAt: createdAt,
        updatedAt: createdAt,
        normalizedIdentityKey: 'bulk-key-$index',
      ),
    );
    await database.batch(
      (batch) => batch.insertAll(database.longTermMemories, fixtures),
    );

    final stopwatch = Stopwatch()..start();
    final first = await repository.search(
      'needle',
      scope: MemoryScope.character('character-1'),
      topK: 5,
    );
    final second = await repository.search(
      'needle',
      scope: MemoryScope.character('character-1'),
      topK: 5,
    );
    stopwatch.stop();

    expect(first.map((result) => result.memory.id), ['bulk-0777']);
    expect(
      second.map((result) => result.memory.id),
      first.map((result) => result.memory.id),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}

LongTermMemory _memory({
  required String id,
  required MemoryScope scope,
  required String content,
  MemoryState state = MemoryState.active,
  MemorySource? source,
  double importance = 0.5,
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? expiresAt,
  String? normalizedIdentityKey,
  String? supersededByMemoryId,
}) {
  final effectiveCreatedAt = createdAt ?? DateTime.utc(2026, 8, 8, 12);
  return LongTermMemory(
    id: id,
    kind: MemoryKind.other,
    scope: scope,
    state: state,
    content: content,
    source: source,
    importance: importance,
    confidence: 0.9,
    createdAt: effectiveCreatedAt,
    updatedAt: updatedAt ?? effectiveCreatedAt,
    expiresAt: expiresAt,
    normalizedIdentityKey: normalizedIdentityKey ?? id,
    supersededByMemoryId: supersededByMemoryId,
  );
}

Future<void> _seedOwners(AppDatabase database) async {
  const statements = [
    'INSERT INTO characters (id, name, created_at, modified_at) '
        "VALUES ('character-1', 'Character', 1, 1)",
    'INSERT INTO personas (id, name, created_at, updated_at) '
        "VALUES ('persona-1', 'Persona', 1, 1)",
    'INSERT INTO groups (id, name, created_at, modified_at) '
        "VALUES ('group-1', 'Group', 1, 1)",
    'INSERT INTO chats (id, character_id, created_at, updated_at) '
        "VALUES ('chat-1', 'character-1', 1, 1)",
    'INSERT INTO messages (id, chat_id, role, content, timestamp) '
        "VALUES ('message-1', 'chat-1', 'user', 'First', 1)",
    'INSERT INTO messages (id, chat_id, role, content, timestamp) '
        "VALUES ('message-2', 'chat-1', 'assistant', 'Second', 2)",
  ];
  for (final statement in statements) {
    await database.customStatement(statement);
  }
}

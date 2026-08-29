import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/domain/repositories/long_term_memory_repository.dart';

void main() {
  test('memory lifecycle works through a JSON-backed repository boundary',
      () async {
    final createdAt = DateTime.utc(2026, 8, 7, 8);
    final repository = _JsonMemoryRepository(
      now: createdAt.add(const Duration(hours: 2)),
    );

    final manualMemory = LongTermMemory(
      id: 'manual-memory',
      kind: MemoryKind.preference,
      scope: MemoryScope.character('character-1'),
      state: MemoryState.active,
      content: 'Prefers tea without sugar.',
      importance: 0.7,
      confidence: 1,
      createdAt: createdAt,
      normalizedIdentityKey: 'preference:tea:sugar:none',
      locked: true,
    );
    await repository.create(manualMemory);

    final candidate = LongTermMemory(
      id: 'generated-candidate',
      kind: MemoryKind.commitment,
      scope: MemoryScope.characterPersona(
        characterId: 'character-1',
        personaId: 'persona-1',
      ),
      content: 'Promised to meet at the station.',
      source: MemorySource.generated(
        sourceChatId: 'chat-1',
        sourceMessageIds: const ['message-10', 'message-11'],
        extractedAt: createdAt.add(const Duration(minutes: 20)),
        providerId: 'openai-compatible',
        modelId: 'memory-model',
      ),
      importance: 0.9,
      confidence: 0.85,
      createdAt: createdAt.add(const Duration(minutes: 21)),
      normalizedIdentityKey: 'commitment:station-meeting',
    );
    await repository.create(candidate);

    expect(await repository.getById(manualMemory.id), manualMemory);
    expect(
      await repository.findBySource(
        chatId: 'chat-1',
        messageId: 'message-11',
      ),
      [candidate],
    );

    final approved = candidate.copyWith(
      state: MemoryState.active,
      updatedAt: createdAt.add(const Duration(minutes: 30)),
    );
    await repository.update(approved);

    final replacement = LongTermMemory(
      id: 'replacement-memory',
      kind: MemoryKind.commitment,
      scope: approved.scope,
      state: MemoryState.active,
      content: 'Changed the meeting place to the library.',
      source: MemorySource.manual(
        sourceChatId: 'chat-1',
        sourceMessageIds: const ['message-12'],
        extractedAt: createdAt.add(const Duration(minutes: 40)),
      ),
      importance: 0.9,
      confidence: 1,
      createdAt: createdAt.add(const Duration(minutes: 41)),
      normalizedIdentityKey: approved.normalizedIdentityKey,
    );
    await repository.create(replacement);
    await repository.updateStates(
      memoryIds: {approved.id},
      state: MemoryState.superseded,
      supersededByMemoryId: replacement.id,
    );

    final superseded = await repository.getById(approved.id);
    expect(superseded?.state, MemoryState.superseded);
    expect(superseded?.supersededByMemoryId, replacement.id);
    expect(
      await repository.findByScope(
        approved.scope,
        states: {MemoryState.active},
      ),
      [replacement],
    );

    final expired = LongTermMemory(
      id: 'expired-memory',
      kind: MemoryKind.event,
      scope: MemoryScope.group('group-1'),
      state: MemoryState.active,
      content: 'The temporary event has ended.',
      createdAt: createdAt,
      expiresAt: createdAt.add(const Duration(hours: 1)),
    );
    await repository.create(expired);

    expect(await repository.findByScope(expired.scope), isEmpty);
    expect(
      await repository.findByScope(expired.scope, includeExpired: true),
      [expired],
    );

    await repository.updateStates(
      memoryIds: {replacement.id},
      state: MemoryState.forgotten,
    );
    expect(
      await repository.findByScope(
        approved.scope,
        states: {MemoryState.active},
      ),
      isEmpty,
    );

    await repository.delete(manualMemory.id);
    expect(await repository.getById(manualMemory.id), isNull);
  });
}

/// Exercises the public contract through the same JSON boundary a future
/// persistence adapter will use, without choosing a production backend.
class _JsonMemoryRepository implements LongTermMemoryRepository {
  final DateTime now;
  final Map<String, String> _records = {};

  _JsonMemoryRepository({required this.now});

  @override
  Future<LongTermMemory> create(LongTermMemory memory) async {
    if (_records.containsKey(memory.id)) {
      throw StateError('Memory ${memory.id} already exists.');
    }
    _write(memory);
    return _read(memory.id)!;
  }

  @override
  Future<List<LongTermMemory>> createAll(List<LongTermMemory> memories) async {
    final created = <LongTermMemory>[];
    for (final memory in memories) {
      created.add(await create(memory));
    }
    return created;
  }

  @override
  Future<void> delete(String id) async {
    _records.remove(id);
  }

  @override
  Future<List<LongTermMemory>> findByScope(
    MemoryScope scope, {
    Set<MemoryState> states = const <MemoryState>{},
    bool includeExpired = false,
    DateTime? at,
  }) async {
    final instant = at ?? now;
    final matches = _all().where((memory) {
      if (memory.scope != scope) return false;
      if (states.isNotEmpty && !states.contains(memory.state)) return false;
      return includeExpired || !memory.isExpiredAt(instant);
    }).toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    return matches;
  }

  @override
  Future<List<LongTermMemory>> findBySource({
    required String chatId,
    String? messageId,
  }) async {
    final matches = _all().where((memory) {
      if (memory.source.sourceChatId != chatId) return false;
      return messageId == null ||
          memory.source.sourceMessageIds.contains(messageId);
    }).toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    return matches;
  }

  @override
  Future<List<LongTermMemory>> findByStates(
    Set<MemoryState> states, {
    bool includeExpired = true,
    DateTime? at,
  }) async {
    return _all().where((memory) {
      if (states.isNotEmpty && !states.contains(memory.state)) return false;
      return includeExpired || !memory.isExpiredAt(at ?? now);
    }).toList();
  }

  @override
  Future<void> rebuildSearchIndex() async {}

  @override
  Future<LongTermMemory> resolve(
    LongTermMemory resolved, {
    Set<String> supersededMemoryIds = const <String>{},
  }) async {
    _write(resolved);
    for (final id in supersededMemoryIds) {
      final prior = _read(id)!;
      _write(
        prior.copyWith(
          state: MemoryState.superseded,
          supersededByMemoryId: resolved.id,
          updatedAt: now,
        ),
      );
    }
    return resolved;
  }

  @override
  Future<List<LongTermMemorySearchResult>> search(
    String query, {
    required MemoryScope scope,
    int topK = 20,
    Set<MemoryState> states = const <MemoryState>{MemoryState.active},
    bool includeExpired = false,
    DateTime? at,
  }) async =>
      const [];

  @override
  Future<LongTermMemory?> getById(String id) async => _read(id);

  @override
  Future<LongTermMemory> update(LongTermMemory memory) async {
    if (!_records.containsKey(memory.id)) {
      throw StateError('Memory ${memory.id} does not exist.');
    }
    _write(memory);
    return _read(memory.id)!;
  }

  @override
  Future<void> updateStates({
    required Set<String> memoryIds,
    required MemoryState state,
    String? supersededByMemoryId,
  }) async {
    if (state == MemoryState.superseded && supersededByMemoryId == null) {
      throw ArgumentError('Superseded memories require a replacement ID.');
    }
    if (state != MemoryState.superseded && supersededByMemoryId != null) {
      throw ArgumentError('Only superseded memories accept a replacement ID.');
    }

    final memories = memoryIds.map((id) {
      final memory = _read(id);
      if (memory == null) throw StateError('Memory $id does not exist.');
      return memory;
    }).toList();
    for (final memory in memories) {
      _write(
        memory.copyWith(
          state: state,
          updatedAt: now,
          supersededByMemoryId: supersededByMemoryId,
          clearSupersededByMemoryId: state != MemoryState.superseded,
        ),
      );
    }
  }

  Iterable<LongTermMemory> _all() sync* {
    for (final id in _records.keys) {
      yield _read(id)!;
    }
  }

  LongTermMemory? _read(String id) {
    final encoded = _records[id];
    if (encoded == null) return null;
    return LongTermMemory.fromJson(
      jsonDecode(encoded) as Map<String, dynamic>,
    );
  }

  void _write(LongTermMemory memory) {
    _records[memory.id] = jsonEncode(memory.toJson());
  }
}

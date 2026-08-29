import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/domain/repositories/long_term_memory_repository.dart';

void main() {
  final createdAt = DateTime.utc(2026, 8, 7, 8);
  final extractedAt = DateTime.utc(2026, 8, 7, 7, 30);

  MemorySource generatedSource() => MemorySource.generated(
        sourceChatId: 'chat-1',
        sourceMessageIds: const ['message-1', 'message-2'],
        extractedAt: extractedAt,
        providerId: 'openai-compatible',
        modelId: 'memory-model',
      );

  LongTermMemory buildMemory({
    String id = 'memory-1',
    MemoryKind kind = MemoryKind.personFact,
    MemoryScope? scope,
    MemoryState state = MemoryState.candidate,
    MemorySource? source,
    double importance = 0.8,
    double confidence = 0.9,
    DateTime? updatedAt,
    DateTime? expiresAt,
    bool locked = true,
    String? supersededByMemoryId,
  }) {
    return LongTermMemory(
      id: id,
      kind: kind,
      scope: scope ?? MemoryScope.character('character-1'),
      state: state,
      content: 'Prefers tea without sugar.',
      source: source ?? generatedSource(),
      importance: importance,
      confidence: confidence,
      createdAt: createdAt,
      updatedAt: updatedAt ?? createdAt.add(const Duration(minutes: 5)),
      expiresAt: expiresAt,
      locked: locked,
      normalizedIdentityKey: 'preference:tea:sugar:none',
      supersededByMemoryId: supersededByMemoryId,
    );
  }

  LongTermMemory jsonRoundTrip(LongTermMemory memory) {
    final encoded = jsonEncode(memory.toJson());
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    return LongTermMemory.fromJson(decoded);
  }

  group('LongTermMemory JSON contract', () {
    test('round-trips every kind, state, and scope without loss', () {
      final scopes = <MemoryScope>[
        MemoryScope.character('character-1'),
        MemoryScope.characterPersona(
          characterId: 'character-1',
          personaId: 'persona-1',
        ),
        MemoryScope.chat('chat-1'),
        MemoryScope.group('group-1'),
      ];

      var sequence = 0;
      for (final kind in MemoryKind.values) {
        for (final state in MemoryState.values) {
          for (final scope in scopes) {
            sequence += 1;
            final memory = buildMemory(
              id: 'memory-$sequence',
              kind: kind,
              scope: scope,
              state: state,
              expiresAt: createdAt.add(const Duration(days: 30)),
              supersededByMemoryId: state == MemoryState.superseded
                  ? 'replacement-$sequence'
                  : null,
            );

            expect(jsonRoundTrip(memory), memory);
          }
        }
      }
    });

    test('uses backward-compatible defaults for optional fields', () {
      final memory = LongTermMemory.fromJson({
        'id': 'legacy-memory',
        'kind': 'other',
        'scope': const <String, dynamic>{
          'kind': 'character',
          'characterId': 'character-1',
        },
        'content': 'A manually entered note.',
        'createdAt': createdAt.toIso8601String(),
      });

      expect(memory.state, MemoryState.candidate);
      expect(memory.source.origin, MemoryOrigin.manual);
      expect(memory.source.sourceMessageIds, isEmpty);
      expect(memory.importance, LongTermMemory.defaultImportance);
      expect(memory.confidence, LongTermMemory.defaultConfidence);
      expect(memory.updatedAt, createdAt);
      expect(memory.expiresAt, isNull);
      expect(memory.locked, isFalse);
      expect(memory.normalizedIdentityKey, 'legacy-memory');
      expect(memory.supersededByMemoryId, isNull);
    });

    test('represents manual memory without an LLM configuration', () {
      final memory = buildMemory(
        source: MemorySource.manual(),
        state: MemoryState.active,
      );

      expect(jsonRoundTrip(memory).source, MemorySource.manual());
    });

    test('retains exact generated source provenance', () {
      final source = generatedSource();
      final restored = jsonRoundTrip(buildMemory(source: source));

      expect(restored.source.sourceChatId, 'chat-1');
      expect(restored.source.sourceMessageIds, ['message-1', 'message-2']);
      expect(restored.source.extractedAt, extractedAt);
      expect(restored.source.providerId, 'openai-compatible');
      expect(restored.source.modelId, 'memory-model');
    });

    test('copies source message IDs into an immutable collection', () {
      final messageIds = ['message-1'];
      final source = MemorySource.generated(
        sourceChatId: 'chat-1',
        sourceMessageIds: messageIds,
        extractedAt: extractedAt,
        providerId: 'provider',
        modelId: 'model',
      );
      messageIds.add('message-2');

      expect(source.sourceMessageIds, ['message-1']);
      expect(
        () => source.sourceMessageIds.add('message-3'),
        throwsUnsupportedError,
      );
    });

    test('copyWith preserves invariants for lifecycle updates', () {
      final active = buildMemory(
        state: MemoryState.active,
        expiresAt: createdAt.add(const Duration(days: 1)),
      );
      final superseded = active.copyWith(
        state: MemoryState.superseded,
        supersededByMemoryId: 'memory-2',
        clearExpiresAt: true,
      );

      expect(superseded.state, MemoryState.superseded);
      expect(superseded.supersededByMemoryId, 'memory-2');
      expect(superseded.expiresAt, isNull);
      expect(superseded.content, active.content);
    });
  });

  group('validation', () {
    test('rejects invalid scope ID combinations', () {
      expect(
        () => MemoryScope(kind: MemoryScopeKind.character),
        throwsArgumentError,
      );
      expect(
        () => MemoryScope(
          kind: MemoryScopeKind.character,
          characterId: 'character-1',
          personaId: 'persona-1',
        ),
        throwsArgumentError,
      );
      expect(
        () => MemoryScope(
          kind: MemoryScopeKind.characterPersona,
          characterId: 'character-1',
        ),
        throwsArgumentError,
      );
      expect(
        () => MemoryScope(
          kind: MemoryScopeKind.chat,
          chatId: 'chat-1',
          groupId: 'group-1',
        ),
        throwsArgumentError,
      );
      expect(() => MemoryScope.group('  '), throwsArgumentError);
    });

    test('rejects confidence and importance outside the unit interval', () {
      for (final invalid in [-0.01, 1.01, double.nan, double.infinity]) {
        expect(() => buildMemory(importance: invalid), throwsArgumentError);
        expect(() => buildMemory(confidence: invalid), throwsArgumentError);
      }
    });

    test('requires complete generated provenance', () {
      expect(
        () => MemorySource(origin: MemoryOrigin.generated),
        throwsArgumentError,
      );
      expect(
        () => MemorySource(
          origin: MemoryOrigin.generated,
          sourceChatId: 'chat-1',
          sourceMessageIds: const ['message-1'],
          extractedAt: extractedAt,
          providerId: 'provider',
        ),
        throwsArgumentError,
      );
      expect(
        () => MemorySource(sourceMessageIds: const ['message-1']),
        throwsArgumentError,
      );
      expect(() => MemorySource(sourceChatId: 'chat-1'), throwsArgumentError);
      expect(
        () => MemorySource(
          sourceChatId: 'chat-1',
          sourceMessageIds: const ['message-1', 'message-1'],
        ),
        throwsArgumentError,
      );
      expect(
        () => MemorySource(
          origin: MemoryOrigin.manual,
          providerId: 'provider',
          modelId: 'model',
        ),
        throwsArgumentError,
      );
    });

    test('rejects contradictory lifecycle metadata', () {
      expect(
        () => buildMemory(state: MemoryState.superseded),
        throwsArgumentError,
      );
      expect(
        () => buildMemory(
          state: MemoryState.active,
          supersededByMemoryId: 'memory-2',
        ),
        throwsArgumentError,
      );
      expect(
        () => buildMemory(
          state: MemoryState.superseded,
          supersededByMemoryId: 'memory-1',
        ),
        throwsArgumentError,
      );
      expect(
        () => buildMemory(
          updatedAt: createdAt.subtract(const Duration(seconds: 1)),
        ),
        throwsArgumentError,
      );
      expect(() => buildMemory(expiresAt: createdAt), throwsArgumentError);
      expect(
        () => buildMemory(
          source: MemorySource.generated(
            sourceChatId: 'chat-1',
            sourceMessageIds: const ['message-1'],
            extractedAt: createdAt.add(const Duration(seconds: 1)),
            providerId: 'provider',
            modelId: 'model',
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects malformed serialized enum and source data', () {
      expect(
        () => LongTermMemory.fromJson({
          'id': 'memory-1',
          'kind': 'unsupported',
          'scope': const <String, dynamic>{
            'kind': 'chat',
            'chatId': 'chat-1',
          },
          'content': 'Memory',
          'createdAt': createdAt.toIso8601String(),
        }),
        throwsFormatException,
      );
      expect(
        () => MemorySource.fromJson({
          'origin': 'generated',
          'sourceChatId': 'chat-1',
          'sourceMessageIds': 'message-1',
          'extractedAt': extractedAt.toIso8601String(),
          'providerId': 'provider',
          'modelId': 'model',
        }),
        throwsFormatException,
      );
    });

    test('reports expiry at and after the expiry instant', () {
      final expiry = createdAt.add(const Duration(hours: 1));
      final memory = buildMemory(expiresAt: expiry);

      expect(
        memory.isExpiredAt(expiry.subtract(const Duration(microseconds: 1))),
        isFalse,
      );
      expect(memory.isExpiredAt(expiry), isTrue);
      expect(
        memory.isExpiredAt(expiry.add(const Duration(seconds: 1))),
        isTrue,
      );
    });
  });

  test('repository contract is implementable without persistence packages', () {
    final repository = _MemoryRepositoryStub();

    expect(repository, isA<LongTermMemoryRepository>());
  });
}

class _MemoryRepositoryStub implements LongTermMemoryRepository {
  @override
  Future<LongTermMemory> create(LongTermMemory memory) async => memory;

  @override
  Future<List<LongTermMemory>> createAll(List<LongTermMemory> memories) async =>
      memories;

  @override
  Future<void> delete(String id) async {}

  @override
  Future<List<LongTermMemory>> findByScope(
    MemoryScope scope, {
    Set<MemoryState> states = const <MemoryState>{},
    bool includeExpired = false,
    DateTime? at,
  }) async =>
      const [];

  @override
  Future<List<LongTermMemory>> findBySource({
    required String chatId,
    String? messageId,
  }) async =>
      const [];

  @override
  Future<List<LongTermMemory>> findByStates(
    Set<MemoryState> states, {
    bool includeExpired = true,
    DateTime? at,
  }) async =>
      const [];

  @override
  Future<void> rebuildSearchIndex() async {}

  @override
  Future<LongTermMemory> resolve(
    LongTermMemory resolved, {
    Set<String> supersededMemoryIds = const <String>{},
  }) async =>
      resolved;

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
  Future<LongTermMemory?> getById(String id) async => null;

  @override
  Future<LongTermMemory> update(LongTermMemory memory) async => memory;

  @override
  Future<void> updateStates({
    required Set<String> memoryIds,
    required MemoryState state,
    String? supersededByMemoryId,
  }) async {}
}

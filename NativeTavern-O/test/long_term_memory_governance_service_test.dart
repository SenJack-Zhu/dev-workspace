import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/repositories/drift_long_term_memory_repository.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/long_term_memory_governance_service.dart';

void main() {
  final now = DateTime.utc(2026, 8, 8, 12);
  const config = LLMConfig(
    provider: LLMProvider.openai,
    model: 'memory-model',
    apiKey: 'secret',
    apiUrl: 'https://example.com/v1',
    maxTokens: 4096,
  );
  late AppDatabase database;
  late DriftLongTermMemoryRepository repository;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    await _seedOwners(database);
    repository = DriftLongTermMemoryRepository(database, now: () => now);
  });

  tearDown(() => database.close());

  group('extraction', () {
    test('stages every supported kind with model and message provenance',
        () async {
      final response = jsonEncode({
        'memories': [
          for (final kind in MemoryKind.values)
            {
              'kind': kind.name,
              'content': 'Durable ${kind.name} fact',
              'identityKey': 'Subject ${kind.name}',
              'importance': 0.8,
              'confidence': 0.9,
              'sourceMessageIds': ['message-1', 'message-2'],
              'expiresAt': null,
            },
        ],
      });
      late List<Map<String, dynamic>> sentPrompt;
      late LLMConfig sentConfig;
      var nextId = 0;
      final service = LongTermMemoryExtractionService(
        repository: repository,
        transport: (messages, requestConfig) async {
          sentPrompt = messages;
          sentConfig = requestConfig;
          return '```json\n$response\n```';
        },
        now: () => now,
        createId: () => 'candidate-${nextId++}',
      );

      final result = await service.extractAndStage(
        scope: MemoryScope.characterPersona(
          characterId: 'character-1',
          personaId: 'persona-1',
        ),
        chatId: 'chat-1',
        messages: const [
          MemoryExtractionMessage(
            id: 'message-1',
            role: 'user',
            content: 'I always order tea.',
          ),
          MemoryExtractionMessage(
            id: 'message-2',
            role: 'assistant',
            content: 'I will remember that.',
          ),
        ],
        config: config,
      );

      expect(result.succeeded, isTrue);
      expect(result.candidates.map((memory) => memory.kind), MemoryKind.values);
      expect(result.candidates.every((m) => m.state == MemoryState.candidate),
          isTrue);
      expect(
          result.candidates
              .every((m) => m.source.origin == MemoryOrigin.generated),
          isTrue);
      expect(result.candidates.every((m) => m.source.providerId == 'openai'),
          isTrue);
      expect(result.candidates.every((m) => m.source.modelId == 'memory-model'),
          isTrue);
      expect(result.candidates.first.source.sourceMessageIds,
          ['message-1', 'message-2']);
      expect(sentPrompt.first['role'], 'system');
      expect(sentConfig.streamEnabled, isFalse);
      expect(sentConfig.temperature, 0);
      expect(sentConfig.maxTokens, 2048);
    });

    test(
        'rejects malformed items and source-id injection without losing valid items',
        () async {
      final service = LongTermMemoryExtractionService(
        repository: repository,
        transport: (_, __) async => jsonEncode({
          'memories': [
            {
              'kind': 'preference',
              'content': 'Prefers jasmine tea.',
              'identityKey': 'person:drink',
              'sourceMessageIds': ['message-1'],
            },
            {
              'kind': 'event',
              'content': 'Injected source.',
              'identityKey': 'event:injected',
              'sourceMessageIds': ['not-supplied'],
            },
            {'kind': 'unsupported'},
          ],
        }),
        now: () => now,
        createId: () => 'valid-candidate',
      );

      final result = await _extract(service, config);

      expect(result.succeeded, isTrue);
      expect(result.rejectedItems, 2);
      expect(result.candidates.single.content, 'Prefers jasmine tea.');
      expect(
        await repository.findByStates({MemoryState.candidate}),
        hasLength(1),
      );
    });

    test('deduplicates existing and within-batch normalized facts', () async {
      await repository.create(
        _memory(
          id: 'existing',
          content: 'Prefers jasmine tea!',
          identityKey: 'person:drink',
        ),
      );
      var nextId = 0;
      final service = LongTermMemoryExtractionService(
        repository: repository,
        transport: (_, __) async => jsonEncode({
          'memories': [
            {
              'kind': 'preference',
              'content': 'Prefers jasmine tea.',
              'identityKey': 'Person Drink',
              'sourceMessageIds': ['message-1'],
            },
            {
              'kind': 'location',
              'content': 'Lives in Singapore.',
              'identityKey': 'Person Home',
              'sourceMessageIds': ['message-1'],
            },
            {
              'kind': 'location',
              'content': 'LIVES IN SINGAPORE!',
              'identityKey': 'person:home',
              'sourceMessageIds': ['message-2'],
            },
          ],
        }),
        now: () => now,
        createId: () => 'new-${nextId++}',
      );

      final result = await _extract(service, config);

      expect(result.candidates.map((memory) => memory.id), ['new-1']);
      expect(result.duplicateMemoryIds, ['existing', 'new-1']);
    });

    test('reports unavailable, invalid, cancelled, and transport failures',
        () async {
      var called = false;
      final unavailable = LongTermMemoryExtractionService(
        repository: repository,
        transport: (_, __) async {
          called = true;
          return '{}';
        },
      );
      final unavailableResult = await _extract(
        unavailable,
        config.copyWith(apiKey: ''),
      );
      expect(unavailableResult.failure?.kind,
          MemoryExtractionFailureKind.unavailable);
      expect(called, isFalse);

      final invalid = LongTermMemoryExtractionService(
        repository: repository,
        transport: (_, __) async => 'not json',
      );
      expect((await _extract(invalid, config)).failure?.kind,
          MemoryExtractionFailureKind.invalidResponse);

      final cancelled = LongTermMemoryExtractionService(
        repository: repository,
        transport: (_, __) => throw DioException(
          requestOptions: RequestOptions(path: '/memory'),
          type: DioExceptionType.cancel,
        ),
      );
      expect((await _extract(cancelled, config)).failure?.kind,
          MemoryExtractionFailureKind.cancelled);

      final transport = LongTermMemoryExtractionService(
        repository: repository,
        transport: (_, __) => throw StateError('offline'),
      );
      expect((await _extract(transport, config)).failure?.kind,
          MemoryExtractionFailureKind.transport);
      expect(await repository.findByStates({MemoryState.candidate}), isEmpty);
    });

    test('batch persistence failure rolls back every candidate', () async {
      final service = LongTermMemoryExtractionService(
        repository: repository,
        transport: (_, __) async => jsonEncode({
          'memories': [
            {
              'kind': 'preference',
              'content': 'First candidate.',
              'identityKey': 'first',
              'sourceMessageIds': ['message-1'],
            },
            {
              'kind': 'event',
              'content': 'Second candidate.',
              'identityKey': 'second',
              'sourceMessageIds': ['message-2'],
            },
          ],
        }),
        now: () => now,
        createId: () => 'same-id',
      );

      final result = await _extract(service, config);

      expect(result.failure?.kind, MemoryExtractionFailureKind.persistence);
      expect(await repository.findByStates({MemoryState.candidate}), isEmpty);
    });
  });

  group('governance', () {
    test(
        'approves plain candidate and atomically supersedes conflicting source',
        () async {
      final scope = MemoryScope.character('character-1');
      await repository.create(
        _memory(
          id: 'prior',
          scope: scope,
          content: 'Lives in Paris.',
          identityKey: 'person:home',
        ),
      );
      await repository.create(
        _memory(
          id: 'candidate',
          scope: scope,
          state: MemoryState.candidate,
          content: 'Lives in Singapore.',
          identityKey: 'person:home',
          source: _generatedSource('message-2'),
        ),
      );
      final service = LongTermMemoryGovernanceService(
        repository: repository,
        now: () => now.add(const Duration(minutes: 1)),
      );

      final assessment = await service.inspect('candidate');
      expect(assessment.kind, MemoryConflictKind.conflicting);
      expect(assessment.existingMemories.single.id, 'prior');

      final result = await service.approve('candidate');
      expect(result.kind, MemoryResolutionKind.activated);
      expect(result.memory.state, MemoryState.active);
      expect(
          (await repository.getById('prior'))?.state, MemoryState.superseded);
      expect((await repository.getById('prior'))?.supersededByMemoryId,
          'candidate');
      expect((await repository.getById('prior'))?.source.origin,
          MemoryOrigin.manual);
      expect((await repository.getById('candidate'))?.source.sourceMessageIds,
          ['message-2']);
    });

    test('links duplicates and blocks replacement of a locked active fact',
        () async {
      final scope = MemoryScope.character('character-1');
      await repository.create(
        _memory(
          id: 'locked',
          scope: scope,
          content: 'Prefers tea.',
          identityKey: 'person:drink',
          locked: true,
        ),
      );
      await repository.create(
        _memory(
          id: 'duplicate',
          scope: scope,
          state: MemoryState.candidate,
          content: 'PREFERS TEA!',
          identityKey: 'person drink',
        ),
      );
      await repository.create(
        _memory(
          id: 'conflict',
          scope: scope,
          state: MemoryState.candidate,
          content: 'Prefers coffee.',
          identityKey: 'person drink',
        ),
      );
      final service = LongTermMemoryGovernanceService(repository: repository);

      final duplicate = await service.approve('duplicate');
      expect(duplicate.kind, MemoryResolutionKind.duplicateLinked);
      expect(duplicate.memory.state, MemoryState.superseded);
      expect(duplicate.memory.supersededByMemoryId, 'locked');

      final conflict = await service.approve('conflict');
      expect(conflict.kind, MemoryResolutionKind.blockedByLock);
      expect(
          (await repository.getById('conflict'))?.state, MemoryState.candidate);
      expect((await repository.getById('locked'))?.state, MemoryState.active);
    });

    test('merges candidates while retaining each original source record',
        () async {
      final scope = MemoryScope.character('character-1');
      await repository.createAll([
        _memory(
          id: 'candidate-a',
          scope: scope,
          state: MemoryState.candidate,
          content: 'Likes tea.',
          identityKey: 'drink:a',
          source: _generatedSource('message-1'),
        ),
        _memory(
          id: 'candidate-b',
          scope: scope,
          state: MemoryState.candidate,
          content: 'Avoids sugar.',
          identityKey: 'drink:b',
          source: _generatedSource('message-2'),
        ),
      ]);
      final service = LongTermMemoryGovernanceService(
        repository: repository,
        now: () => now.add(const Duration(minutes: 1)),
        createId: () => 'merged',
      );

      final merged = await service.mergeCandidates(
        candidateIds: {'candidate-a', 'candidate-b'},
        kind: MemoryKind.preference,
        content: 'Likes unsweetened tea.',
        identityKey: 'person:drink',
        locked: true,
      );

      expect(merged.id, 'merged');
      expect(merged.state, MemoryState.active);
      expect(merged.locked, isTrue);
      expect(merged.source.origin, MemoryOrigin.manual);
      final originalA = await repository.getById('candidate-a');
      final originalB = await repository.getById('candidate-b');
      expect(originalA?.supersededByMemoryId, 'merged');
      expect(originalA?.source.sourceMessageIds, ['message-1']);
      expect(originalB?.supersededByMemoryId, 'merged');
      expect(originalB?.source.sourceMessageIds, ['message-2']);
    });

    test('manual memories work offline and expiry never forgets locked facts',
        () async {
      final createdAt = now.subtract(const Duration(days: 2));
      await repository.createAll([
        _memory(
          id: 'due',
          createdAt: createdAt,
          expiresAt: now.subtract(const Duration(hours: 1)),
        ),
        _memory(
          id: 'locked-due',
          createdAt: createdAt,
          expiresAt: now.subtract(const Duration(hours: 1)),
          locked: true,
        ),
      ]);
      final service = LongTermMemoryGovernanceService(
        repository: repository,
        now: () => now,
        createId: () => 'manual',
      );

      final manual = await service.createManual(
        scope: MemoryScope.chat('chat-1'),
        kind: MemoryKind.other,
        content: '  Written without an LLM.  ',
        locked: true,
      );
      expect(manual.content, 'Written without an LLM.');
      expect(manual.state, MemoryState.active);
      expect(manual.source.origin, MemoryOrigin.manual);

      expect(await service.expireDueMemories(), 1);
      expect((await repository.getById('due'))?.state, MemoryState.forgotten);
      expect(
          (await repository.getById('locked-due'))?.state, MemoryState.active);
    });
  });
}

Future<MemoryExtractionResult> _extract(
  LongTermMemoryExtractionService service,
  LLMConfig config,
) {
  return service.extractAndStage(
    scope: MemoryScope.character('character-1'),
    chatId: 'chat-1',
    messages: const [
      MemoryExtractionMessage(
        id: 'message-1',
        role: 'user',
        content: 'First',
      ),
      MemoryExtractionMessage(
        id: 'message-2',
        role: 'assistant',
        content: 'Second',
      ),
    ],
    config: config,
  );
}

LongTermMemory _memory({
  required String id,
  MemoryScope? scope,
  MemoryState state = MemoryState.active,
  String content = 'Memory content.',
  String? identityKey,
  MemorySource? source,
  bool locked = false,
  DateTime? createdAt,
  DateTime? expiresAt,
}) {
  final effectiveCreatedAt = createdAt ?? DateTime.utc(2026, 8, 8, 12);
  return LongTermMemory(
    id: id,
    kind: MemoryKind.other,
    scope: scope ?? MemoryScope.character('character-1'),
    state: state,
    content: content,
    source: source,
    importance: 0.7,
    confidence: 0.9,
    createdAt: effectiveCreatedAt,
    expiresAt: expiresAt,
    locked: locked,
    normalizedIdentityKey: normalizeMemoryIdentity(identityKey ?? id),
  );
}

MemorySource _generatedSource(String messageId) {
  return MemorySource.generated(
    sourceChatId: 'chat-1',
    sourceMessageIds: [messageId],
    extractedAt: DateTime.utc(2026, 8, 8, 11, 59),
    providerId: 'openai',
    modelId: 'memory-model',
  );
}

Future<void> _seedOwners(AppDatabase database) async {
  const statements = [
    'INSERT INTO characters (id, name, created_at, modified_at) '
        "VALUES ('character-1', 'Character', 1, 1)",
    'INSERT INTO personas (id, name, created_at, updated_at) '
        "VALUES ('persona-1', 'Persona', 1, 1)",
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

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/repositories/drift_long_term_memory_repository.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/long_term_memory_context_service.dart';

void main() {
  final now = DateTime.utc(2026, 8, 8, 12);
  late AppDatabase database;
  late DriftLongTermMemoryRepository repository;
  late LongTermMemoryContextService service;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    await _seedOwners(database);
    repository = DriftLongTermMemoryRepository(database, now: () => now);
    service = LongTermMemoryContextService(repository: repository);
  });

  tearDown(() => database.close());

  test('aggregates allowed scopes and excludes other, inactive, and expired',
      () async {
    final scopes = [
      MemoryScope.chat('chat-1'),
      MemoryScope.group('group-1'),
      MemoryScope.characterPersona(
        characterId: 'character-1',
        personaId: 'persona-1',
      ),
      MemoryScope.character('character-1'),
    ];
    await repository.createAll([
      for (final (index, scope) in scopes.indexed)
        _memory(
          id: 'allowed-$index',
          scope: scope,
          content: 'Prefers jasmine tea.',
        ),
      _memory(
        id: 'other-chat',
        scope: MemoryScope.chat('chat-2'),
        content: 'Prefers jasmine tea.',
      ),
      _memory(
        id: 'candidate',
        scope: MemoryScope.chat('chat-1'),
        content: 'Prefers jasmine tea.',
        state: MemoryState.candidate,
      ),
      _memory(
        id: 'expired',
        scope: MemoryScope.character('character-1'),
        content: 'Prefers jasmine tea.',
        createdAt: now.subtract(const Duration(days: 2)),
        expiresAt: now.subtract(const Duration(hours: 1)),
      ),
    ]);

    final first = await service.select(query: 'jasmine', scopes: scopes);
    final second = await service.select(query: 'jasmine', scopes: scopes);

    expect(first.mode, MemoryRetrievalMode.fts);
    expect(
      first.matches.map((match) => match.memory.id),
      ['allowed-0', 'allowed-1', 'allowed-2', 'allowed-3'],
    );
    expect(
      second.matches.map((match) => match.memory.id),
      first.matches.map((match) => match.memory.id),
    );
    expect(
      first.matches.map((match) => match.memory.id),
      isNot(contains(anyOf('other-chat', 'candidate', 'expired'))),
    );

    final branch = await service.select(
      query: 'jasmine',
      scopes: [
        MemoryScope.chat('chat-2'),
        MemoryScope.character('character-1'),
      ],
    );
    expect(
      branch.matches.map((match) => match.memory.id),
      ['other-chat', 'allowed-3'],
    );
  });

  test('hybrid ranking can include a semantic-only memory', () async {
    final scope = MemoryScope.character('character-1');
    await repository.createAll([
      _memory(
        id: 'fts-match',
        scope: scope,
        content: 'Orchid details.',
        importance: 0,
      ),
      _memory(
        id: 'semantic-only',
        scope: scope,
        content: 'Favorite beverage is tea.',
        importance: 1,
      ),
    ]);

    final selection = await service.select(
      query: 'orchid',
      scopes: [scope],
      semanticThreshold: 0.7,
      semanticScorer: (_, candidates) async => {
        for (final candidate in candidates)
          candidate.id: candidate.id == 'semantic-only' ? 0.99 : 0.1,
      },
    );

    expect(selection.mode, MemoryRetrievalMode.hybrid);
    expect(
      selection.matches.map((match) => match.memory.id),
      ['semantic-only', 'fts-match'],
    );
    expect(selection.matches.first.ftsScore, isNull);
    expect(selection.matches.first.semanticScore, 0.99);
  });

  test('semantic timeout, errors, and malformed scores fall back to FTS',
      () async {
    final scope = MemoryScope.character('character-1');
    await repository.create(
      _memory(id: 'local', scope: scope, content: 'Local orchid result.'),
    );

    Future<void> expectFallback(
      LongTermMemoryContextService target,
      MemorySemanticScorer scorer,
      MemorySemanticFallbackReason reason,
    ) async {
      final selection = await target.select(
        query: 'orchid',
        scopes: [scope],
        semanticScorer: scorer,
      );
      expect(selection.mode, MemoryRetrievalMode.ftsFallback);
      expect(selection.fallbackReason, reason);
      expect(selection.matches.single.memory.id, 'local');
    }

    await expectFallback(
      service,
      (_, __) async => throw StateError('not configured'),
      MemorySemanticFallbackReason.unavailable,
    );
    await expectFallback(
      service,
      (_, __) async => const {},
      MemorySemanticFallbackReason.invalidResponse,
    );
    await expectFallback(
      LongTermMemoryContextService(
        repository: repository,
        semanticTimeout: const Duration(milliseconds: 1),
      ),
      (_, __) => Completer<Map<String, double>>().future,
      MemorySemanticFallbackReason.timeout,
    );
  });

  test('contributor uses current user text and keeps body out of metadata',
      () async {
    const body = 'Jasmine tea is the preferred drink.';
    await repository.create(
      _memory(
        id: 'traceable',
        scope: MemoryScope.chat('chat-1'),
        content: body,
      ),
    );
    ChatContextRequest? observedRequest;
    final contributor = LongTermMemoryContextContributor(
      service: service,
      resolveScopes: (request) async {
        observedRequest = request;
        return [MemoryScope.chat(request.chatId)];
      },
      enabled: () => true,
      tokenBudget: () => 512,
      semanticEnabled: () => false,
      semanticThreshold: () => 0.7,
      semanticScorer: (_, __) async => const {},
    );
    final request = ChatContextRequest(
      sessionId: 'session-1',
      chatId: 'chat-1',
      characterId: 'character-1',
      mode: ChatGenerationMode.regenerate,
      baseMessages: const [
        {'role': 'user', 'content': 'old query'},
        {'role': 'assistant', 'content': 'old answer'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'jasmine'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png'}
            },
          ],
        },
      ],
      inputTokenBudget: 4096,
      availableContributionTokens: 512,
      conversationStartIndex: 0,
      cancellationToken: ChatCancellationToken(),
    );

    final contribution = await contributor.contribute(request);

    expect(observedRequest, same(request));
    expect(contribution.itemIds, ['traceable']);
    expect(contribution.messages.single['content'], contains(body));
    expect(contribution.placement,
        ContextContributionPlacement.beforeConversation);
    final encodedMetadata = jsonEncode(contribution.metadata);
    expect(encodedMetadata, contains('traceable'));
    expect(encodedMetadata, isNot(contains(body)));
  });
}

LongTermMemory _memory({
  required String id,
  required MemoryScope scope,
  required String content,
  MemoryState state = MemoryState.active,
  double importance = 0.5,
  DateTime? createdAt,
  DateTime? expiresAt,
}) {
  final effectiveCreatedAt = createdAt ?? DateTime.utc(2026, 8, 8, 12);
  return LongTermMemory(
    id: id,
    kind: MemoryKind.preference,
    scope: scope,
    state: state,
    content: content,
    importance: importance,
    confidence: 0.9,
    createdAt: effectiveCreatedAt,
    expiresAt: expiresAt,
    normalizedIdentityKey: id,
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
    'INSERT INTO chats (id, character_id, created_at, updated_at) '
        "VALUES ('chat-2', 'character-1', 1, 1)",
  ];
  for (final statement in statements) {
    await database.customStatement(statement);
  }
}

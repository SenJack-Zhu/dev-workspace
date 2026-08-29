import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/models/data_bank_context.dart';
import 'package:native_tavern/data/models/vector_storage.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/data_bank_context_service.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/tokenizer_service.dart';

void main() {
  test('disabled contributor leaves the assembled prompt byte-for-byte intact',
      () async {
    final repository = _SearchRepository({});
    final contributor = DataBankContextContributor(
      service: DataBankContextService(repository: repository),
      settings: () => const DataBankContextSettings(enabled: false),
      embeddingSettings: () => const VectorStorageSettings(),
    );
    final registry = ChatExtensionRegistry()..registerContributor(contributor);
    final pipeline = ChatGenerationPipeline(registry: registry);
    final session = pipeline.startSession(
      chatId: 'chat-1',
      characterId: 'character-1',
      mode: ChatGenerationMode.send,
      config: _config,
    );
    final baseline = <ChatMessageMap>[
      {'role': 'system', 'content': 'Stay in character.'},
      {'role': 'user', 'content': 'eastern harbor'},
    ];

    final assembly = await session.assemble(baseline);

    expect(assembly.messages, baseline);
    expect(assembly.traces.single.status, ContextContributionStatus.disabled);
    expect(repository.queries, isEmpty);
    session.close();
    await pipeline.dispose();
  });

  test('rewrites into fused local queries and applies scope and diversity',
      () async {
    final repository = _SearchRepository({
      'Where is it?': [
        _result('a-1', 'document-a', rank: -4),
        _result('a-2', 'document-a', rank: -3),
        _result('b-1', 'document-b', rank: -2),
      ],
      'eastern harbor': [
        _result('c-1', 'document-c', rank: -8),
      ],
    });
    final service = DataBankContextService(repository: repository);

    final payload = await service.retrieve(
      request: _request(const [
        {'role': 'user', 'content': 'eastern harbor'},
        {'role': 'assistant', 'content': 'It is near the cliffs.'},
        {'role': 'user', 'content': 'Where is it?'},
      ]),
      settings: const DataBankContextSettings(
        queryRewriteEnabled: true,
        topK: 3,
        maxChunksPerDocument: 1,
        maxTokens: 800,
      ),
      embeddingSettings: const VectorStorageSettings(),
    );

    expect(payload.snapshot.queries, ['Where is it?', 'eastern harbor']);
    expect(
      payload.snapshot.sources
          .map((source) => source.citation.documentId)
          .toSet(),
      {'document-a', 'document-b', 'document-c'},
    );
    expect(payload.prompt, contains('Document: document-a.md'));
    expect(payload.prompt, contains('chapter "Reference"'));
    expect(payload.prompt, contains('page 7'));
    expect(
      repository.filters,
      everyElement(
        isA<DataBankSearchFilter>()
            .having((filter) => filter.includeUnbound, 'includeUnbound', false)
            .having(
                (filter) => filter.characterId, 'characterId', 'character-1')
            .having((filter) => filter.chatId, 'chatId', 'chat-1'),
      ),
    );
  });

  test('semantic reranking changes hybrid order', () async {
    final repository = _SearchRepository({
      'compass': [
        _result('local-first', 'document-a', rank: -10),
        _result('semantic-first', 'document-b', rank: -2),
      ],
    });
    final service = DataBankContextService(
      repository: repository,
      embedBatch: (texts, settings) async => [
        [1, 0],
        [0, 1],
        [1, 0],
      ],
    );

    final payload = await service.retrieve(
      request: _request(const [
        {'role': 'user', 'content': 'compass'},
      ]),
      settings: const DataBankContextSettings(
        semanticRerankingEnabled: true,
        semanticWeight: 0.9,
        topK: 2,
      ),
      embeddingSettings: const VectorStorageSettings(
        embeddingProvider: EmbeddingProvider.custom,
        embeddingEndpoint: 'http://localhost:11434/v1',
      ),
    );

    expect(payload.snapshot.mode, DataBankRetrievalMode.semanticReranked);
    expect(payload.snapshot.sources.first.citation.chunkId, 'semantic-first');
  });

  test('embedding failure preserves original FTS order', () async {
    final repository = _SearchRepository({
      'offline archive': [
        _result('fts-first', 'document-a', rank: -10),
        _result('fts-second', 'document-b', rank: -2),
      ],
    });
    final service = DataBankContextService(
      repository: repository,
      embedBatch: (texts, settings) async => throw StateError('offline'),
    );

    final payload = await service.retrieve(
      request: _request(const [
        {'role': 'user', 'content': 'offline archive'},
      ]),
      settings: const DataBankContextSettings(
        semanticRerankingEnabled: true,
        topK: 2,
      ),
      embeddingSettings: const VectorStorageSettings(),
    );

    expect(payload.snapshot.mode, DataBankRetrievalMode.semanticFallback);
    expect(payload.snapshot.fallbackReason, contains('offline'));
    expect(
      payload.snapshot.sources.map((source) => source.citation.chunkId),
      ['fts-first', 'fts-second'],
    );
  });

  test('assembled source text stays inside the contributor token budget',
      () async {
    final repository = _SearchRepository({
      'large reference': [
        _result(
          'large',
          'large-document',
          rank: -10,
          text: List.filled(400, 'large reference passage').join(' '),
        ),
      ],
    });
    final service = DataBankContextService(repository: repository);

    final payload = await service.retrieve(
      request: _request(const [
        {'role': 'user', 'content': 'large reference'},
      ]),
      settings: const DataBankContextSettings(maxTokens: 180),
      embeddingSettings: const VectorStorageSettings(),
    );

    expect(payload.snapshot.sources, hasLength(1));
    expect(
        payload.snapshot.sources.single.injectedText, contains('[truncated]'));
    expect(
      TokenizerService().estimateTokenCount(payload.prompt!) + 4,
      lessThanOrEqualTo(180),
    );
  });

  test('citation metadata remains aligned when swipes are appended or removed',
      () {
    final first = _snapshot('session-1', _result('chunk-1', 'document-a'));
    final second = _snapshot('session-2', _result('chunk-2', 'document-b'));
    var metadata = appendDataBankContextMetadata(
      metadata: const {},
      existingSwipeCount: 0,
      snapshot: first,
    );
    metadata = appendDataBankContextMetadata(
      metadata: metadata,
      existingSwipeCount: 1,
      snapshot: second,
    );

    expect(dataBankContextForSwipe(metadata, 0)?.sessionId, 'session-1');
    expect(dataBankContextForSwipe(metadata, 1)?.sessionId, 'session-2');

    metadata = removeDataBankContextMetadataAt(
      metadata: metadata,
      swipeIndex: 0,
    );
    expect(dataBankContextForSwipe(metadata, 0)?.sessionId, 'session-2');
  });

  test('section-only locators retain a useful citation location', () async {
    final locator = DataBankSourceLocator(
      documentVersionId: 'version-1',
      sectionId: 'section-1',
    );
    final chunk = DataBankTextChunk(
      id: 'chunk-1',
      documentVersionId: 'version-1',
      sectionId: 'section-1',
      ordinal: 0,
      text: 'Section-only reference.',
      locator: locator,
    );
    final result = DataBankSearchResult(
      chunk: chunk,
      citation: chunk.toCitation('document-1'),
      documentName: 'reference.md',
      snippet: chunk.text,
      rank: -1,
    );
    final service = DataBankContextService(
      repository: _SearchRepository({
        'reference': [result],
      }),
    );

    final payload = await service.retrieve(
      request: _request(const [
        {'role': 'user', 'content': 'reference'},
      ]),
      settings: const DataBankContextSettings(),
      embeddingSettings: const VectorStorageSettings(),
    );

    expect(payload.snapshot.sources.single.locationLabel, 'Section section-1');
    expect(payload.prompt, contains('Location: section section-1'));
  });
}

const _config = LLMConfig(
  provider: LLMProvider.openAICompatible,
  model: 'test-model',
  apiKey: '',
  apiUrl: 'http://localhost',
  contextLength: 4096,
  maxTokens: 256,
  streamEnabled: false,
  autoSummarizeEnabled: false,
);

ChatContextRequest _request(List<ChatMessageMap> messages) {
  return ChatContextRequest(
    sessionId: 'session-1',
    chatId: 'chat-1',
    characterId: 'character-1',
    mode: ChatGenerationMode.send,
    baseMessages: messages,
    inputTokenBudget: 4096,
    availableContributionTokens: 2048,
    cancellationToken: ChatCancellationToken(),
  );
}

DataBankContextSnapshot _snapshot(
  String sessionId,
  DataBankSearchResult result,
) {
  return DataBankContextSnapshot(
    sessionId: sessionId,
    originalQuery: 'query',
    queries: const ['query'],
    mode: DataBankRetrievalMode.localFts,
    sources: [
      DataBankContextSource(
        label: 'D1',
        documentName: result.documentName,
        snippet: result.snippet,
        injectedText: result.chunk.text,
        citation: result.citation,
      ),
    ],
  );
}

DataBankSearchResult _result(
  String chunkId,
  String documentId, {
  double rank = -1,
  String? text,
}) {
  final content = text ?? 'The eastern channel is safe before dawn.';
  final locator = DataBankSourceLocator(
    documentVersionId: '$documentId-version',
    sectionId: '$documentId-section',
    chapter: 'Reference',
    pageStart: 7,
    startOffset: 10,
    endOffset: 10 + content.length,
  );
  final chunk = DataBankTextChunk(
    id: chunkId,
    documentVersionId: '$documentId-version',
    sectionId: '$documentId-section',
    ordinal: 0,
    text: content,
    locator: locator,
  );
  return DataBankSearchResult(
    chunk: chunk,
    citation: chunk.toCitation(documentId),
    documentName: '$documentId.md',
    snippet: content,
    rank: rank,
  );
}

final class _SearchRepository implements DataBankSearchRepository {
  final Map<String, List<DataBankSearchResult>> results;
  final List<String> queries = [];
  final List<DataBankSearchFilter> filters = [];

  _SearchRepository(this.results);

  @override
  Future<void> rebuildSearchIndex() async {}

  @override
  Future<List<DataBankSearchResult>> search(
    String query, {
    int topK = 20,
    DataBankSearchFilter filter = const DataBankSearchFilter(),
  }) async {
    queries.add(query);
    filters.add(filter);
    return (results[query] ?? const []).take(topK).toList(growable: false);
  }
}

import 'dart:math';

import 'package:native_tavern/data/models/data_bank_context.dart';
import 'package:native_tavern/data/models/vector_storage.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/tokenizer_service.dart';

typedef DataBankEmbeddingBatch = Future<List<List<double>>> Function(
  List<String> texts,
  VectorStorageSettings settings,
);

abstract interface class DataBankQueryRewriter {
  List<String> rewrite(ChatContextRequest request, String latestQuery);
}

final class RecentConversationDataBankQueryRewriter
    implements DataBankQueryRewriter {
  final int maxQueries;

  const RecentConversationDataBankQueryRewriter({this.maxQueries = 3});

  @override
  List<String> rewrite(ChatContextRequest request, String latestQuery) {
    final queries = <String>[latestQuery];
    for (final message in request.baseMessages.reversed) {
      if (message['role'] != 'user') continue;
      final text = dataBankTextFromMessage(message).trim();
      if (text.isEmpty || text == latestQuery || queries.contains(text)) {
        continue;
      }
      queries.add(text);
      if (queries.length >= maxQueries) break;
    }
    return List<String>.unmodifiable(queries);
  }
}

final class DataBankContextPayload {
  final DataBankContextSnapshot snapshot;
  final String? prompt;

  const DataBankContextPayload({required this.snapshot, this.prompt});
}

final class DataBankContextService {
  final DataBankSearchRepository _repository;
  final DataBankEmbeddingBatch? _embedBatch;
  final DataBankQueryRewriter _queryRewriter;
  final TokenizerService _tokenizer;

  DataBankContextService({
    required DataBankSearchRepository repository,
    DataBankEmbeddingBatch? embedBatch,
    DataBankQueryRewriter queryRewriter =
        const RecentConversationDataBankQueryRewriter(),
    TokenizerService? tokenizer,
  })  : _repository = repository,
        _embedBatch = embedBatch,
        _queryRewriter = queryRewriter,
        _tokenizer = tokenizer ?? TokenizerService();

  Future<DataBankContextPayload> retrieve({
    required ChatContextRequest request,
    required DataBankContextSettings settings,
    required VectorStorageSettings embeddingSettings,
  }) async {
    final originalQuery = latestDataBankQuery(request.baseMessages);
    final queries = originalQuery.isEmpty
        ? const <String>[]
        : settings.queryRewriteEnabled
            ? _queryRewriter.rewrite(request, originalQuery)
            : <String>[originalQuery];
    final normalizedQueries = queries
        .map((query) => query.trim())
        .where((query) => query.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalizedQueries.isEmpty) {
      return DataBankContextPayload(
        snapshot: DataBankContextSnapshot(
          sessionId: request.sessionId,
          originalQuery: originalQuery,
          queries: const [],
          mode: DataBankRetrievalMode.localFts,
          sources: const [],
        ),
      );
    }

    final candidates = await _retrieveFused(
      normalizedQueries,
      topK: max(20, settings.topK * 4),
      filter: DataBankSearchFilter.forContext(
        characterId: request.characterId,
        chatId: request.chatId,
      ),
    );
    var ranked = candidates;
    var mode = DataBankRetrievalMode.localFts;
    String? fallbackReason;
    if (settings.semanticRerankingEnabled && candidates.isNotEmpty) {
      try {
        ranked = await _semanticRerank(
          query: originalQuery,
          candidates: candidates,
          settings: embeddingSettings,
          semanticWeight: settings.semanticWeight,
        );
        mode = DataBankRetrievalMode.semanticReranked;
      } catch (error) {
        ranked = candidates;
        mode = DataBankRetrievalMode.semanticFallback;
        fallbackReason = error.toString();
      }
    }

    final diverse = _selectDiverse(
      ranked,
      topK: settings.topK,
      maxPerDocument: settings.maxChunksPerDocument,
    );
    final assembled = _assemblePrompt(
      diverse,
      maxTokens: min(settings.maxTokens, request.availableContributionTokens),
    );
    return DataBankContextPayload(
      snapshot: DataBankContextSnapshot(
        sessionId: request.sessionId,
        originalQuery: originalQuery,
        queries: normalizedQueries,
        mode: mode,
        sources: assembled.sources,
        fallbackReason: fallbackReason,
      ),
      prompt: assembled.prompt,
    );
  }

  Future<List<DataBankSearchResult>> _retrieveFused(
    List<String> queries, {
    required int topK,
    required DataBankSearchFilter filter,
  }) async {
    final fused = <String, _FusedResult>{};
    for (var queryIndex = 0; queryIndex < queries.length; queryIndex++) {
      final results = await _repository.search(
        queries[queryIndex],
        topK: topK,
        filter: filter,
      );
      final queryWeight = (queries.length - queryIndex) / queries.length;
      for (var rankIndex = 0; rankIndex < results.length; rankIndex++) {
        final result = results[rankIndex];
        final score = queryWeight / (60 + rankIndex + 1);
        final existing = fused[result.chunk.id];
        if (existing == null) {
          fused[result.chunk.id] = _FusedResult(result, score);
        } else {
          existing.score += score;
        }
      }
    }
    final ordered = fused.values.toList()
      ..sort((left, right) {
        final byScore = right.score.compareTo(left.score);
        if (byScore != 0) return byScore;
        final byRank = left.result.rank.compareTo(right.result.rank);
        if (byRank != 0) return byRank;
        return left.result.chunk.id.compareTo(right.result.chunk.id);
      });
    return ordered.map((item) => item.result).toList(growable: false);
  }

  Future<List<DataBankSearchResult>> _semanticRerank({
    required String query,
    required List<DataBankSearchResult> candidates,
    required VectorStorageSettings settings,
    required double semanticWeight,
  }) async {
    final embedBatch = _embedBatch;
    if (embedBatch == null) {
      throw StateError('Embedding service is unavailable.');
    }
    final embeddings = await embedBatch([
      query,
      ...candidates.map((result) => result.chunk.text),
    ], settings);
    if (embeddings.length != candidates.length + 1 ||
        embeddings.first.isEmpty) {
      throw const FormatException('Embedding response size is invalid.');
    }
    final queryEmbedding = embeddings.first;
    final scored = <_SemanticResult>[];
    for (var index = 0; index < candidates.length; index++) {
      final embedding = embeddings[index + 1];
      if (embedding.length != queryEmbedding.length || embedding.isEmpty) {
        throw const FormatException('Embedding dimensions do not match.');
      }
      final semanticScore = (_cosine(queryEmbedding, embedding) + 1) / 2;
      final localScore = 1 / (index + 1);
      scored.add(
        _SemanticResult(
          candidates[index],
          semanticWeight * semanticScore + (1 - semanticWeight) * localScore,
          index,
        ),
      );
    }
    scored.sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) return byScore;
      return left.localIndex.compareTo(right.localIndex);
    });
    return scored.map((item) => item.result).toList(growable: false);
  }

  List<DataBankSearchResult> _selectDiverse(
    List<DataBankSearchResult> candidates, {
    required int topK,
    required int maxPerDocument,
  }) {
    final selected = <DataBankSearchResult>[];
    final selectedChunks = <String>{};
    final perDocument = <String, int>{};

    for (final result in candidates) {
      final documentId = result.citation.documentId;
      if (perDocument.containsKey(documentId)) continue;
      selected.add(result);
      selectedChunks.add(result.chunk.id);
      perDocument[documentId] = 1;
      if (selected.length >= topK) return selected;
    }
    for (final result in candidates) {
      if (selectedChunks.contains(result.chunk.id)) continue;
      final documentId = result.citation.documentId;
      final count = perDocument[documentId] ?? 0;
      if (count >= maxPerDocument) continue;
      selected.add(result);
      selectedChunks.add(result.chunk.id);
      perDocument[documentId] = count + 1;
      if (selected.length >= topK) break;
    }
    return selected;
  }

  _AssembledDataBankPrompt _assemblePrompt(
    List<DataBankSearchResult> results, {
    required int maxTokens,
  }) {
    if (results.isEmpty || maxTokens < 24) {
      return const _AssembledDataBankPrompt(null, []);
    }
    const intro = 'Relevant Data Bank sources for the current request follow. '
        'Use them only when relevant and preserve the source labels when '
        'referring to factual details.';
    final blocks = <String>[];
    final sources = <DataBankContextSource>[];
    for (final result in results) {
      final label = 'D${sources.length + 1}';
      var quote = result.chunk.text.trim();
      var block = _sourceBlock(result, label, quote);
      var candidatePrompt = _joinPrompt(intro, [...blocks, block]);
      if (_messageTokens(candidatePrompt) > maxTokens) {
        final remainingTokens =
            maxTokens - _messageTokens(_joinPrompt(intro, blocks));
        if (remainingTokens < 32) continue;
        final maximumCharacters = max(
          24,
          ((remainingTokens - 20) * TokenizerService.charsPerTokenRatio)
              .floor(),
        );
        if (quote.length <= maximumCharacters) continue;
        quote = '${quote.substring(0, maximumCharacters)}\n[truncated]';
        block = _sourceBlock(result, label, quote);
        candidatePrompt = _joinPrompt(intro, [...blocks, block]);
        while (
            _messageTokens(candidatePrompt) > maxTokens && quote.length > 40) {
          final end = max(24, quote.length - 16);
          quote = '${quote.substring(0, end)}\n[truncated]';
          block = _sourceBlock(result, label, quote);
          candidatePrompt = _joinPrompt(intro, [...blocks, block]);
        }
        if (_messageTokens(candidatePrompt) > maxTokens) continue;
      }
      blocks.add(block);
      sources.add(
        DataBankContextSource(
          label: label,
          documentName: result.documentName,
          snippet: result.snippet,
          injectedText: quote,
          citation: result.citation,
        ),
      );
    }
    if (sources.isEmpty) return const _AssembledDataBankPrompt(null, []);
    return _AssembledDataBankPrompt(_joinPrompt(intro, blocks), sources);
  }

  int _messageTokens(String text) => _tokenizer.estimateTokenCount(text) + 4;
}

final class DataBankContextContributor extends ContextContributor {
  final DataBankContextService _service;
  final DataBankContextSettings Function() _settings;
  final VectorStorageSettings Function() _embeddingSettings;
  final void Function(DataBankContextSnapshot snapshot)? _onRetrieved;

  DataBankContextContributor({
    required DataBankContextService service,
    required DataBankContextSettings Function() settings,
    required VectorStorageSettings Function() embeddingSettings,
    void Function(DataBankContextSnapshot snapshot)? onRetrieved,
  })  : _service = service,
        _settings = settings,
        _embeddingSettings = embeddingSettings,
        _onRetrieved = onRetrieved;

  @override
  String get id => 'data-bank.retrieval';

  @override
  int get order => 300;

  @override
  int get maxTokens => _settings().maxTokens;

  @override
  bool isEnabled(ChatContextRequest request) => _settings().enabled;

  @override
  Future<ContextContribution> contribute(ChatContextRequest request) async {
    final payload = await _service.retrieve(
      request: request,
      settings: _settings(),
      embeddingSettings: _embeddingSettings(),
    );
    _onRetrieved?.call(payload.snapshot);
    final prompt = payload.prompt;
    return ContextContribution(
      messages: prompt == null
          ? const []
          : [
              {'role': 'system', 'content': prompt},
            ],
      placement: ContextContributionPlacement.beforeConversation,
    );
  }
}

String latestDataBankQuery(List<ChatMessageMap> messages) {
  for (final message in messages.reversed) {
    if (message['role'] != 'user') continue;
    final text = dataBankTextFromMessage(message).trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

String dataBankTextFromMessage(ChatMessageMap message) {
  final content = message['content'];
  if (content is String) return content;
  if (content is List) {
    return content
        .whereType<Map<Object?, Object?>>()
        .where((part) => part['text'] is String)
        .map((part) => part['text'] as String)
        .join('\n');
  }
  return '';
}

String _sourceBlock(DataBankSearchResult result, String label, String quote) {
  final locator = result.citation.locator;
  final locationDetails = [
    if (locator.chapter != null) 'chapter "${locator.chapter}"',
    if (locator.pageStart != null)
      locator.effectivePageEnd == locator.pageStart
          ? 'page ${locator.pageStart}'
          : 'pages ${locator.pageStart}-${locator.effectivePageEnd}',
    if (locator.startOffset != null)
      'characters ${locator.startOffset}-${locator.endOffset}',
  ];
  final location = locationDetails.isNotEmpty
      ? locationDetails.join(', ')
      : locator.sectionId == null
          ? 'document'
          : 'section ${locator.sectionId}';
  return '[$label]\n'
      'Document: ${result.documentName}\n'
      'Location: $location\n'
      'Excerpt:\n$quote';
}

String _joinPrompt(String intro, List<String> blocks) =>
    '$intro\n\n${blocks.join('\n\n')}';

double _cosine(List<double> left, List<double> right) {
  var dot = 0.0;
  var leftNorm = 0.0;
  var rightNorm = 0.0;
  for (var index = 0; index < left.length; index++) {
    dot += left[index] * right[index];
    leftNorm += left[index] * left[index];
    rightNorm += right[index] * right[index];
  }
  if (leftNorm == 0 || rightNorm == 0) return -1;
  return dot / (sqrt(leftNorm) * sqrt(rightNorm));
}

final class _FusedResult {
  final DataBankSearchResult result;
  double score;

  _FusedResult(this.result, this.score);
}

final class _SemanticResult {
  final DataBankSearchResult result;
  final double score;
  final int localIndex;

  const _SemanticResult(this.result, this.score, this.localIndex);
}

final class _AssembledDataBankPrompt {
  final String? prompt;
  final List<DataBankContextSource> sources;

  const _AssembledDataBankPrompt(this.prompt, this.sources);
}

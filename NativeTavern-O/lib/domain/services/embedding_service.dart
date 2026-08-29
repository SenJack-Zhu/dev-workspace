import 'package:dio/dio.dart';
import 'package:native_tavern/data/models/vector_storage.dart';
import 'package:native_tavern/domain/services/ai_data_sharing_consent_service.dart';
import 'package:native_tavern/domain/services/external_call_audit_service.dart';

/// Generates text embeddings for RAG / vector storage.
///
/// Supports OpenAI-compatible endpoints (OpenAI, SiliconFlow, custom),
/// Cohere, Google Gemini, and Ollama's /api/embed.
class EmbeddingService {
  final Dio _dio;

  EmbeddingService({
    Dio? dio,
    ExternalCallAuditRepository auditRepository =
        const NoopExternalCallAuditRepository(),
    AiDataSharingConsentRepository consentRepository =
        const AllowAllAiDataSharingConsentRepository(),
  }) : _dio = dio ?? Dio() {
    _dio.interceptors.add(ExternalCallAuditInterceptor(
      repository: auditRepository,
      capabilityId: 'embedding',
      classifyData: (request) => metadataForGet(
        request,
        const {ExternalDataType.documentText},
      ),
      consentRepository: consentRepository,
    ));
  }

  /// Embed a single text
  Future<List<double>> embed(
    String text,
    VectorStorageSettings settings,
  ) async {
    final results = await embedBatch([text], settings);
    return results.first;
  }

  /// Embed a batch of texts
  Future<List<List<double>>> embedBatch(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    if (texts.isEmpty) return [];

    _validateConfiguration(settings);

    try {
      switch (settings.embeddingProvider) {
        case EmbeddingProvider.openai:
        case EmbeddingProvider.siliconflow:
        case EmbeddingProvider.custom:
          return await _embedOpenAICompatible(texts, settings);
        case EmbeddingProvider.cohere:
          return await _embedCohere(texts, settings);
        case EmbeddingProvider.gemini:
          return await _embedGemini(texts, settings);
        case EmbeddingProvider.ollama:
          return await _embedOllama(texts, settings);
        case EmbeddingProvider.local:
          throw UnsupportedError('On-device embeddings are not available yet. '
              'Use Ollama or a cloud provider.');
      }
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final endpoint = effectiveEndpoint(settings);
      throw Exception(
        status == null
            ? 'Could not connect to the embedding API at $endpoint.'
            : 'Embedding API returned HTTP $status at $endpoint. '
                'Check the endpoint, API key, and embedding model.',
      );
    }
  }

  void _validateConfiguration(VectorStorageSettings settings) {
    final requiresApiKey =
        settings.embeddingProvider == EmbeddingProvider.openai ||
            settings.embeddingProvider == EmbeddingProvider.siliconflow ||
            settings.embeddingProvider == EmbeddingProvider.cohere ||
            settings.embeddingProvider == EmbeddingProvider.gemini;
    if (requiresApiKey &&
        (settings.embeddingApiKey == null ||
            settings.embeddingApiKey!.trim().isEmpty)) {
      throw StateError('An embedding API key is required for this provider.');
    }
  }

  /// Resolve a base URL that can safely have a provider path appended.
  String effectiveEndpoint(VectorStorageSettings settings) {
    final configured = settings.embeddingEndpoint?.trim();
    final endpoint = configured == null || configured.isEmpty
        ? settings.embeddingProvider.defaultEndpoint
        : configured;
    final uri = Uri.tryParse(endpoint);
    if (uri == null) return endpoint.replaceFirst(RegExp(r'/+$'), '');

    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final isOpenAICompatible =
        settings.embeddingProvider == EmbeddingProvider.openai ||
            settings.embeddingProvider == EmbeddingProvider.siliconflow ||
            settings.embeddingProvider == EmbeddingProvider.custom;
    if (isOpenAICompatible && path.endsWith('/embeddings')) {
      path = path.substring(0, path.length - '/embeddings'.length);
    }
    path = path.replaceFirst(RegExp(r'/+$'), '');
    if (isOpenAICompatible && path.isEmpty) path = '/v1';

    return uri.replace(path: path).toString().replaceFirst(RegExp(r'/+$'), '');
  }

  String _model(VectorStorageSettings settings) {
    final model = settings.embeddingModel;
    if (model != null && model.isNotEmpty) return model;
    return settings.embeddingProvider.defaultModel;
  }

  Future<List<List<double>>> _embedOpenAICompatible(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '${effectiveEndpoint(settings)}/embeddings',
      options: Options(headers: {
        'Authorization': 'Bearer ${settings.embeddingApiKey ?? ''}',
        'Content-Type': 'application/json',
      }),
      data: {
        'model': _model(settings),
        'input': texts,
      },
    );
    final data = response.data?['data'] as List<dynamic>? ?? [];
    if (data.isEmpty) {
      throw const FormatException('Embedding API returned no vectors.');
    }
    // Preserve input order via the index field
    final results =
        List<List<double>>.filled(texts.length, const [], growable: false);
    for (final item in data) {
      final map = item as Map<String, dynamic>;
      final index = map['index'] as int? ?? 0;
      final embedding = (map['embedding'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList();
      if (index < results.length) results[index] = embedding;
    }
    if (results.any((embedding) => embedding.isEmpty)) {
      throw const FormatException(
          'Embedding API returned fewer vectors than requested.');
    }
    return results;
  }

  Future<List<List<double>>> _embedCohere(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '${effectiveEndpoint(settings)}/v1/embed',
      options: Options(headers: {
        'Authorization': 'Bearer ${settings.embeddingApiKey ?? ''}',
        'Content-Type': 'application/json',
      }),
      data: {
        'model': _model(settings),
        'texts': texts,
        'input_type': 'search_document',
      },
    );
    final embeddings = response.data?['embeddings'] as List<dynamic>? ?? [];
    return embeddings
        .map((e) =>
            (e as List<dynamic>).map((v) => (v as num).toDouble()).toList())
        .toList();
  }

  Future<List<List<double>>> _embedGemini(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    final model = _model(settings);
    final response = await _dio.post<Map<String, dynamic>>(
      '${effectiveEndpoint(settings)}/models/$model:batchEmbedContents'
      '?key=${settings.embeddingApiKey ?? ''}',
      options: Options(headers: {'Content-Type': 'application/json'}),
      data: {
        'requests': texts
            .map((t) => {
                  'model': 'models/$model',
                  'content': {
                    'parts': [
                      {'text': t}
                    ]
                  },
                })
            .toList(),
      },
    );
    final embeddings = response.data?['embeddings'] as List<dynamic>? ?? [];
    return embeddings
        .map((e) => ((e as Map<String, dynamic>)['values'] as List<dynamic>)
            .map((v) => (v as num).toDouble())
            .toList())
        .toList();
  }

  Future<List<List<double>>> _embedOllama(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    // Ollama's /api/embed accepts batched input (ST migrated to this)
    final response = await _dio.post<Map<String, dynamic>>(
      '${effectiveEndpoint(settings)}/api/embed',
      options: Options(headers: {'Content-Type': 'application/json'}),
      data: {
        'model': _model(settings),
        'input': texts,
      },
    );
    final embeddings = response.data?['embeddings'] as List<dynamic>? ?? [];
    return embeddings
        .map((e) =>
            (e as List<dynamic>).map((v) => (v as num).toDouble()).toList())
        .toList();
  }
}

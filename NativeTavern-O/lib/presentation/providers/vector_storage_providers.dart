import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:native_tavern/data/models/vector_storage.dart';
import 'package:native_tavern/domain/services/embedding_service.dart';
import 'package:native_tavern/domain/services/vector_storage_service.dart';
import 'package:native_tavern/presentation/providers/ai_data_sharing_consent_providers.dart';
import 'package:native_tavern/presentation/providers/external_call_audit_providers.dart';

/// Provider for VectorStorageService (loads persisted collections)
final vectorStorageServiceProvider = Provider<VectorStorageService>((ref) {
  final service = VectorStorageService();
  service.load();
  return service;
});

/// Provider for EmbeddingService
final embeddingServiceProvider = Provider<EmbeddingService>((ref) {
  return EmbeddingService(
    auditRepository: ref.watch(externalCallAuditRepositoryProvider),
    consentRepository: ref.watch(aiDataSharingConsentRepositoryProvider),
  );
});

/// Provider for vector storage settings
final vectorStorageSettingsProvider =
    StateNotifierProvider<VectorStorageSettingsNotifier, VectorStorageSettings>(
        (ref) {
  return VectorStorageSettingsNotifier();
});

/// Notifier for managing vector storage settings
class VectorStorageSettingsNotifier
    extends StateNotifier<VectorStorageSettings> {
  static const _storageKey = 'vector_storage_settings';

  VectorStorageSettingsNotifier() : super(const VectorStorageSettings()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_storageKey);
      if (json != null) {
        state = VectorStorageSettings.deserialize(json);
      }
    } catch (e) {
      // Keep default settings on error
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _storageKey, VectorStorageSettings.serialize(state));
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Toggle enabled state
  void setEnabled(bool enabled) {
    state = state.copyWith(enabled: enabled);
    _saveSettings();
  }

  /// Set active collection
  void setActiveCollection(String? collectionId) {
    if (collectionId == null) {
      state = state.copyWith(clearActiveCollection: true);
    } else {
      state = state.copyWith(activeCollectionId: collectionId);
    }
    _saveSettings();
  }

  /// Set top K results
  void setTopK(int topK) {
    state = state.copyWith(topK: topK.clamp(1, 20));
    _saveSettings();
  }

  /// Set similarity threshold
  void setSimilarityThreshold(double threshold) {
    state = state.copyWith(similarityThreshold: threshold.clamp(0.0, 1.0));
    _saveSettings();
  }

  /// Toggle include in prompt
  void setIncludeInPrompt(bool include) {
    state = state.copyWith(includeInPrompt: include);
    _saveSettings();
  }

  /// Set prompt template
  void setPromptTemplate(String template) {
    state = state.copyWith(promptTemplate: template);
    _saveSettings();
  }

  /// Set embedding provider
  void setEmbeddingProvider(EmbeddingProvider provider) {
    state = state.copyWith(
      embeddingProvider: provider,
      embeddingModel: provider.defaultModel,
      embeddingEndpoint: provider.defaultEndpoint,
    );
    _saveSettings();
  }

  /// Set embedding model
  void setEmbeddingModel(String model) {
    state = state.copyWith(embeddingModel: model);
    _saveSettings();
  }

  /// Set embedding API endpoint
  void setEmbeddingEndpoint(String endpoint) {
    state = state.copyWith(embeddingEndpoint: endpoint);
    _saveSettings();
  }

  /// Set embedding API key
  void setEmbeddingApiKey(String apiKey) {
    state = state.copyWith(embeddingApiKey: apiKey);
    _saveSettings();
  }

  /// Reuse an OpenAI-compatible chat connection for embeddings.
  void useChatConnection({
    required String endpoint,
    required String apiKey,
  }) {
    state = state.copyWith(
      embeddingProvider: EmbeddingProvider.custom,
      embeddingEndpoint: endpoint.trim(),
      embeddingApiKey: apiKey.trim(),
    );
    _saveSettings();
  }

  /// Reset to defaults
  void resetToDefaults() {
    state = const VectorStorageSettings();
    _saveSettings();
  }
}

/// Provider for collections list
final vectorCollectionsProvider =
    StateNotifierProvider<VectorCollectionsNotifier, List<VectorCollection>>(
        (ref) {
  final service = ref.watch(vectorStorageServiceProvider);
  return VectorCollectionsNotifier(service);
});

/// Notifier for managing collections
class VectorCollectionsNotifier extends StateNotifier<List<VectorCollection>> {
  final VectorStorageService _service;

  VectorCollectionsNotifier(this._service) : super([]) {
    _loadCollections();
  }

  Future<void> _loadCollections() async {
    await _service.load();
    if (!mounted) return;
    state = _service.collections;
  }

  /// Create a new collection
  VectorCollection createCollection({
    required String name,
    String? description,
    int dimensions = 1536,
  }) {
    final collection = _service.createCollection(
      name: name,
      description: description,
      dimensions: dimensions,
    );
    state = _service.collections;
    return collection;
  }

  /// Update a collection
  void updateCollection(VectorCollection collection) {
    _service.updateCollection(collection);
    state = _service.collections;
  }

  /// Delete a collection
  void deleteCollection(String id) {
    _service.deleteCollection(id);
    state = _service.collections;
  }

  /// Add document to collection
  VectorDocument addDocument({
    required String collectionId,
    required String content,
    List<double>? embedding,
    Map<String, dynamic>? metadata,
  }) {
    final doc = _service.addDocument(
      collectionId: collectionId,
      content: content,
      embedding: embedding,
      metadata: metadata,
    );
    state = _service.collections;
    return doc;
  }

  /// Remove document from collection
  void removeDocument(String collectionId, String documentId) {
    _service.removeDocument(collectionId, documentId);
    state = _service.collections;
  }

  /// Import collection from JSON
  VectorCollection importCollection(String json) {
    final collection = _service.importCollection(json);
    state = _service.collections;
    return collection;
  }

  /// Export collection to JSON
  String exportCollection(String collectionId) {
    return _service.exportCollection(collectionId);
  }

  /// Refresh collections list
  void refresh() {
    state = _service.collections;
  }
}

/// Provider for active collection
final activeCollectionProvider = Provider<VectorCollection?>((ref) {
  final settings = ref.watch(vectorStorageSettingsProvider);
  final collections = ref.watch(vectorCollectionsProvider);

  if (settings.activeCollectionId == null) return null;

  try {
    return collections.firstWhere((c) => c.id == settings.activeCollectionId);
  } catch (_) {
    return null;
  }
});

/// Provider for collection statistics
final collectionStatisticsProvider =
    Provider.family<CollectionStatistics, String>((ref, collectionId) {
  final service = ref.watch(vectorStorageServiceProvider);
  return service.getStatistics(collectionId);
});

/// Provider for search results
final vectorSearchProvider =
    FutureProvider.family<List<VectorSearchResult>, VectorSearchRequest>(
        (ref, request) async {
  final service = ref.watch(vectorStorageServiceProvider);
  final settings = ref.watch(vectorStorageSettingsProvider);

  if (request.queryEmbedding == null) {
    return [];
  }

  return service.search(
    collectionId: request.collectionId,
    queryEmbedding: request.queryEmbedding!,
    topK: request.topK ?? settings.topK,
    similarityThreshold:
        request.similarityThreshold ?? settings.similarityThreshold,
  );
});

/// Request for vector search
class VectorSearchRequest {
  final String collectionId;
  final List<double>? queryEmbedding;
  final int? topK;
  final double? similarityThreshold;

  const VectorSearchRequest({
    required this.collectionId,
    this.queryEmbedding,
    this.topK,
    this.similarityThreshold,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VectorSearchRequest &&
        other.collectionId == collectionId &&
        other.topK == topK &&
        other.similarityThreshold == similarityThreshold;
  }

  @override
  int get hashCode => Object.hash(collectionId, topK, similarityThreshold);
}

/// Provider for chunking text
final textChunkerProvider = Provider<TextChunker>((ref) {
  final service = ref.watch(vectorStorageServiceProvider);
  return TextChunker(service);
});

/// Helper class for text chunking
class TextChunker {
  final VectorStorageService _service;

  TextChunker(this._service);

  List<String> chunk(String text, ChunkingOptions options) {
    return _service.chunkText(text, options);
  }
}

/// Provider for checking if RAG is active
final isRAGActiveProvider = Provider<bool>((ref) {
  final settings = ref.watch(vectorStorageSettingsProvider);
  final activeCollection = ref.watch(activeCollectionProvider);
  return settings.enabled && activeCollection != null;
});

/// Embeds all documents in a collection that don't have embeddings yet.
/// Returns the number of documents embedded.
final embedCollectionProvider =
    Provider<Future<int> Function(String collectionId)>((ref) {
  return (collectionId) async {
    final service = ref.read(vectorStorageServiceProvider);
    final embedder = ref.read(embeddingServiceProvider);
    final settings = ref.read(vectorStorageSettingsProvider);

    final collection = service.getCollection(collectionId);
    if (collection == null) return 0;

    final pending =
        collection.documents.where((d) => d.embedding == null).toList();
    if (pending.isEmpty) return 0;

    // Embed in batches of 32 to stay within API limits
    var embedded = 0;
    for (var i = 0; i < pending.length; i += 32) {
      final batch =
          pending.sublist(i, i + 32 > pending.length ? pending.length : i + 32);
      final embeddings = await embedder.embedBatch(
        batch.map((d) => d.content).toList(),
        settings,
      );
      for (var j = 0; j < batch.length; j++) {
        if (j < embeddings.length && embeddings[j].isNotEmpty) {
          service.updateDocumentEmbedding(
              collectionId, batch[j].id, embeddings[j]);
          embedded++;
        }
      }
    }

    ref.read(vectorCollectionsProvider.notifier).refresh();
    return embedded;
  };
});

/// Retrieves RAG context for a query from the active collection.
/// Returns the formatted context block, or null when RAG is inactive,
/// nothing matches, or embedding fails.
final ragContextProvider =
    Provider<Future<String?> Function(String query)>((ref) {
  return (query) async {
    final settings = ref.read(vectorStorageSettingsProvider);
    final collection = ref.read(activeCollectionProvider);
    if (!settings.enabled ||
        !settings.includeInPrompt ||
        collection == null ||
        query.trim().isEmpty) {
      return null;
    }

    try {
      final embedder = ref.read(embeddingServiceProvider);
      final service = ref.read(vectorStorageServiceProvider);
      final queryEmbedding = await embedder.embed(query, settings);

      final results = service.search(
        collectionId: collection.id,
        queryEmbedding: queryEmbedding,
        topK: settings.topK,
        similarityThreshold: settings.similarityThreshold,
      );
      if (results.isEmpty) return null;

      final context = results.map((r) => '- ${r.document.content}').join('\n');
      return settings.promptTemplate.replaceAll('{{context}}', context);
    } catch (e) {
      // RAG is best-effort: never block generation on retrieval failure
      return null;
    }
  };
});

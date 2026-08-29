import 'package:native_tavern/data/models/data_bank.dart';

/// Binding-aware filters for local Data Bank retrieval.
final class DataBankSearchFilter {
  final Set<String> documentIds;
  final String? characterId;
  final String? chatId;
  final bool includeGlobal;
  final bool includeUnbound;

  const DataBankSearchFilter({
    this.documentIds = const <String>{},
    this.characterId,
    this.chatId,
    this.includeGlobal = true,
    this.includeUnbound = true,
  });

  const DataBankSearchFilter.forContext({
    this.characterId,
    this.chatId,
    this.includeGlobal = true,
    this.documentIds = const <String>{},
  }) : includeUnbound = false;
}

/// One FTS match with enough provenance to render and verify a citation.
final class DataBankSearchResult {
  final DataBankTextChunk chunk;
  final DataBankCitation citation;
  final String documentName;
  final String snippet;
  final double rank;

  const DataBankSearchResult({
    required this.chunk,
    required this.citation,
    required this.documentName,
    required this.snippet,
    required this.rank,
  });
}

/// Persistence boundary for Data Bank document metadata.
abstract interface class DataBankDocumentRepository {
  Future<DataBankDocument?> getDocument(String documentId);

  Future<List<DataBankDocument>> listDocuments({bool includeDeleted = false});

  Future<void> saveDocument(DataBankDocument document);
}

/// Persistence boundary for immutable source versions of a document.
abstract interface class DataBankVersionRepository {
  Future<DataBankDocumentVersion?> getVersion(String versionId);

  Future<List<DataBankDocumentVersion>> listVersions(String documentId);

  Future<void> saveVersion(DataBankDocumentVersion version);
}

/// Persistence boundary for parsed sections and their source locations.
abstract interface class DataBankSectionRepository {
  Future<List<DataBankSection>> listSections(String documentVersionId);

  Future<void> replaceSections(
    String documentVersionId,
    List<DataBankSection> sections,
  );
}

/// Persistence boundary for citation-preserving source text chunks.
abstract interface class DataBankChunkRepository {
  Future<DataBankTextChunk?> getChunk(String chunkId);

  Future<List<DataBankTextChunk>> listChunks(String documentVersionId);

  Future<void> replaceChunks(
    String documentVersionId,
    List<DataBankTextChunk> chunks,
  );
}

/// Local full-text retrieval over the canonical chunk records.
abstract interface class DataBankSearchRepository {
  Future<List<DataBankSearchResult>> search(
    String query, {
    int topK = 20,
    DataBankSearchFilter filter = const DataBankSearchFilter(),
  });

  /// Recreates the derived FTS index from canonical chunk records.
  Future<void> rebuildSearchIndex();
}

/// Persistence boundary for global, character, and chat bindings.
abstract interface class DataBankBindingRepository {
  Future<List<DataBankBinding>> listBindingsForDocument(
    String documentId, {
    bool includeDisabled = false,
  });

  Future<List<DataBankBinding>> listBindingsForScope(
    DataBankBindingScope scope, {
    String? targetId,
    bool includeDisabled = false,
  });

  Future<void> saveBinding(DataBankBinding binding);

  Future<void> deleteBinding(String bindingId);
}

/// Atomic lifecycle operations that coordinate document and version records.
///
/// Implementations must reject transitions that fail
/// [DataBankProcessingStateTransitions.canTransitionTo]. Replacing a version
/// must preserve the previous version and atomically update the document's
/// current version pointer.
abstract interface class DataBankLifecycleRepository {
  Future<void> replaceCurrentVersion({
    required String documentId,
    required String expectedCurrentVersionId,
    required DataBankDocumentVersion replacement,
  });

  Future<void> transitionDocument({
    required String documentId,
    required DataBankProcessingState from,
    required DataBankProcessingState to,
    DataBankFailure? failure,
  });

  Future<void> transitionVersion({
    required String versionId,
    required DataBankProcessingState from,
    required DataBankProcessingState to,
    DataBankFailure? failure,
  });

  Future<void> requestReprocessing({
    required String documentId,
    required String versionId,
    required String reason,
    required DateTime requestedAt,
  });

  Future<void> setDocumentEnabled(String documentId, bool enabled);

  Future<void> markDocumentDeleted(String documentId);
}

/// Atomic persistence operations used by the Data Bank management workflow.
abstract interface class DataBankManagementRepository {
  Future<DataBankDocumentVersion?> findVersionByContentHash(
    DataBankContentHash contentHash,
  );

  Future<void> createPendingDocument({
    required DataBankDocument document,
    required DataBankDocumentVersion version,
    required DataBankBinding initialBinding,
  });

  Future<void> beginProcessing({
    required String documentId,
    required String versionId,
    required DateTime startedAt,
  });

  Future<void> completeProcessing({
    required String documentId,
    required String versionId,
    required List<DataBankSection> sections,
    required List<DataBankTextChunk> chunks,
    required DateTime completedAt,
  });

  Future<void> failProcessing({
    required String documentId,
    required String versionId,
    required DataBankFailure failure,
  });

  /// Permanently removes the document and all database-owned descendants.
  Future<void> purgeDocument(String documentId);
}

/// Complete persistence surface used by production Data Bank workflows.
abstract interface class DataBankRepository
    implements
        DataBankDocumentRepository,
        DataBankVersionRepository,
        DataBankSectionRepository,
        DataBankChunkRepository,
        DataBankSearchRepository,
        DataBankBindingRepository,
        DataBankLifecycleRepository,
        DataBankManagementRepository {}

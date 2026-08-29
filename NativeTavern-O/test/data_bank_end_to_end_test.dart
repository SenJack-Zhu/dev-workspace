import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';

void main() {
  test('document lifecycle works through JSON-backed repository boundaries',
      () async {
    final importedAt = DateTime.utc(2026, 8, 7, 12);
    final repository = _JsonDataBankRepository();
    final firstVersion = DataBankDocumentVersion(
      id: 'version-1',
      documentId: 'document-1',
      versionNumber: 1,
      originalFileName: 'field-guide.pdf',
      mediaType: 'application/pdf',
      byteSize: 4096,
      contentHash: DataBankContentHash(
        algorithm: DataBankHashAlgorithm.sha256,
        digest: '1' * 64,
      ),
      importedAt: importedAt,
    );
    final document = DataBankDocument(
      id: firstVersion.documentId,
      currentVersionId: firstVersion.id,
      createdAt: importedAt,
      updatedAt: importedAt,
    );

    await repository.saveVersion(firstVersion);
    await repository.saveDocument(document);
    await repository.transitionVersion(
      versionId: firstVersion.id,
      from: DataBankProcessingState.pending,
      to: DataBankProcessingState.processing,
    );
    await repository.transitionDocument(
      documentId: document.id,
      from: DataBankProcessingState.pending,
      to: DataBankProcessingState.processing,
    );
    await repository.transitionVersion(
      versionId: firstVersion.id,
      from: DataBankProcessingState.processing,
      to: DataBankProcessingState.ready,
    );
    await repository.transitionDocument(
      documentId: document.id,
      from: DataBankProcessingState.processing,
      to: DataBankProcessingState.ready,
    );

    final sourceLocator = DataBankSourceLocator(
      documentVersionId: firstVersion.id,
      sectionId: 'chapter-1',
      pageStart: 7,
      chapter: 'Safe Harbor',
      startOffset: 320,
      endOffset: 460,
    );
    final section = DataBankSection(
      id: 'chapter-1',
      documentVersionId: firstVersion.id,
      kind: DataBankSectionKind.chapter,
      title: 'Safe Harbor',
      ordinal: 0,
      locator: sourceLocator,
    );
    final chunk = DataBankTextChunk(
      id: 'chunk-1',
      documentVersionId: firstVersion.id,
      sectionId: section.id,
      ordinal: 0,
      text: 'Ships enter the harbor from the eastern channel.',
      locator: sourceLocator,
    );
    await repository.replaceSections(firstVersion.id, [section]);
    await repository.replaceChunks(firstVersion.id, [chunk]);

    final bindings = <DataBankBinding>[
      DataBankBinding(
        id: 'binding-global',
        documentId: document.id,
        scope: DataBankBindingScope.global,
        createdAt: importedAt,
        updatedAt: importedAt,
      ),
      DataBankBinding(
        id: 'binding-character',
        documentId: document.id,
        scope: DataBankBindingScope.character,
        characterId: 'character-1',
        createdAt: importedAt,
        updatedAt: importedAt,
      ),
      DataBankBinding(
        id: 'binding-chat-disabled',
        documentId: document.id,
        scope: DataBankBindingScope.chat,
        chatId: 'chat-1',
        enabled: false,
        createdAt: importedAt,
        updatedAt: importedAt,
      ),
    ];
    for (final binding in bindings) {
      await repository.saveBinding(binding);
    }

    final restoredChunk = await repository.getChunk(chunk.id);
    final citation = restoredChunk!.toCitation(document.id);
    expect(citation.documentId, document.id);
    expect(citation.documentVersionId, firstVersion.id);
    expect(citation.chunkId, chunk.id);
    expect(citation.locator.pageStart, 7);
    expect(citation.locator.chapter, 'Safe Harbor');
    expect(await repository.listSections(firstVersion.id), hasLength(1));
    expect(await repository.listChunks(firstVersion.id), hasLength(1));
    expect(
      await repository.listBindingsForDocument(document.id),
      hasLength(2),
    );
    expect(
      await repository.listBindingsForDocument(
        document.id,
        includeDisabled: true,
      ),
      hasLength(3),
    );
    expect(
      await repository.listBindingsForScope(
        DataBankBindingScope.character,
        targetId: 'character-1',
      ),
      hasLength(1),
    );

    final reprocessAt = importedAt.add(const Duration(hours: 1));
    await repository.requestReprocessing(
      documentId: document.id,
      versionId: firstVersion.id,
      reason: 'Parser upgraded',
      requestedAt: reprocessAt,
    );
    final queuedDocument = await repository.getDocument(document.id);
    final queuedVersion = await repository.getVersion(firstVersion.id);
    expect(queuedDocument?.processingState, DataBankProcessingState.pending);
    expect(queuedDocument?.indexState, DataBankIndexState.stale);
    expect(queuedVersion?.reprocessing.attemptCount, 1);
    expect(queuedVersion?.reprocessing.reason, 'Parser upgraded');

    final replacement = DataBankDocumentVersion(
      id: 'version-2',
      documentId: document.id,
      versionNumber: 2,
      supersedesVersionId: firstVersion.id,
      originalFileName: 'field-guide-revised.pdf',
      mediaType: 'application/pdf',
      byteSize: 5120,
      contentHash: DataBankContentHash(
        algorithm: DataBankHashAlgorithm.sha256,
        digest: '2' * 64,
      ),
      importedAt: reprocessAt.add(const Duration(minutes: 5)),
    );
    await repository.replaceCurrentVersion(
      documentId: document.id,
      expectedCurrentVersionId: firstVersion.id,
      replacement: replacement,
    );

    final replacedDocument = await repository.getDocument(document.id);
    expect(replacedDocument?.currentVersionId, replacement.id);
    expect(await repository.listVersions(document.id), hasLength(2));
    expect(
      (await repository.getVersion(replacement.id))?.supersedesVersionId,
      firstVersion.id,
    );

    await repository.setDocumentEnabled(document.id, false);
    final disabledDocument = await repository.getDocument(document.id);
    expect(disabledDocument?.isEnabled, isFalse);
    expect(disabledDocument?.indexState, DataBankIndexState.disabled);

    await repository.setDocumentEnabled(document.id, true);
    expect(
      (await repository.getDocument(document.id))?.processingState,
      DataBankProcessingState.pending,
    );

    await repository.markDocumentDeleted(document.id);
    expect(await repository.listDocuments(), isEmpty);
    expect(await repository.listDocuments(includeDeleted: true), hasLength(1));
    expect(
      (await repository.getDocument(document.id))?.processingState,
      DataBankProcessingState.deleted,
    );
  });
}

/// Exercises the public contract through the same JSON boundary a future
/// persistence adapter will use, without choosing a production backend.
final class _JsonDataBankRepository
    implements
        DataBankDocumentRepository,
        DataBankVersionRepository,
        DataBankSectionRepository,
        DataBankChunkRepository,
        DataBankBindingRepository,
        DataBankLifecycleRepository {
  final Map<String, String> _documents = {};
  final Map<String, String> _versions = {};
  final Map<String, String> _sectionsByVersion = {};
  final Map<String, String> _chunksByVersion = {};
  final Map<String, String> _bindings = {};

  @override
  Future<DataBankDocument?> getDocument(String documentId) async {
    return _readDocument(documentId);
  }

  @override
  Future<List<DataBankDocument>> listDocuments({
    bool includeDeleted = false,
  }) async {
    final documents = _documents.keys
        .map(_readDocument)
        .whereType<DataBankDocument>()
        .where(
          (document) =>
              includeDeleted ||
              document.processingState != DataBankProcessingState.deleted,
        )
        .toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    return documents;
  }

  @override
  Future<void> saveDocument(DataBankDocument document) async {
    _writeDocument(document);
  }

  @override
  Future<DataBankDocumentVersion?> getVersion(String versionId) async {
    return _readVersion(versionId);
  }

  @override
  Future<List<DataBankDocumentVersion>> listVersions(String documentId) async {
    final versions = _versions.keys
        .map(_readVersion)
        .whereType<DataBankDocumentVersion>()
        .where((version) => version.documentId == documentId)
        .toList()
      ..sort(
        (left, right) => left.versionNumber.compareTo(right.versionNumber),
      );
    return versions;
  }

  @override
  Future<void> saveVersion(DataBankDocumentVersion version) async {
    _writeVersion(version);
  }

  @override
  Future<List<DataBankSection>> listSections(String documentVersionId) async {
    final encoded = _sectionsByVersion[documentVersionId];
    if (encoded == null) return [];
    return (jsonDecode(encoded) as List<dynamic>)
        .map(
          (value) => DataBankSection.fromJson(value as Map<String, dynamic>),
        )
        .toList(growable: false);
  }

  @override
  Future<void> replaceSections(
    String documentVersionId,
    List<DataBankSection> sections,
  ) async {
    _requireVersion(documentVersionId);
    if (sections.any(
      (section) => section.documentVersionId != documentVersionId,
    )) {
      throw ArgumentError('Every section must belong to $documentVersionId.');
    }
    _sectionsByVersion[documentVersionId] =
        jsonEncode(sections.map((section) => section.toJson()).toList());
  }

  @override
  Future<DataBankTextChunk?> getChunk(String chunkId) async {
    for (final versionId in _chunksByVersion.keys) {
      final chunks = await listChunks(versionId);
      for (final chunk in chunks) {
        if (chunk.id == chunkId) return chunk;
      }
    }
    return null;
  }

  @override
  Future<List<DataBankTextChunk>> listChunks(
    String documentVersionId,
  ) async {
    final encoded = _chunksByVersion[documentVersionId];
    if (encoded == null) return [];
    return (jsonDecode(encoded) as List<dynamic>)
        .map(
          (value) => DataBankTextChunk.fromJson(value as Map<String, dynamic>),
        )
        .toList(growable: false);
  }

  @override
  Future<void> replaceChunks(
    String documentVersionId,
    List<DataBankTextChunk> chunks,
  ) async {
    _requireVersion(documentVersionId);
    if (chunks.any(
      (chunk) => chunk.documentVersionId != documentVersionId,
    )) {
      throw ArgumentError('Every chunk must belong to $documentVersionId.');
    }
    _chunksByVersion[documentVersionId] =
        jsonEncode(chunks.map((chunk) => chunk.toJson()).toList());
  }

  @override
  Future<List<DataBankBinding>> listBindingsForDocument(
    String documentId, {
    bool includeDisabled = false,
  }) async {
    return _allBindings()
        .where((binding) => binding.documentId == documentId)
        .where((binding) => includeDisabled || binding.enabled)
        .toList(growable: false);
  }

  @override
  Future<List<DataBankBinding>> listBindingsForScope(
    DataBankBindingScope scope, {
    String? targetId,
    bool includeDisabled = false,
  }) async {
    if ((scope == DataBankBindingScope.global) != (targetId == null)) {
      throw ArgumentError(
        'Global scope requires no target; other scopes require one.',
      );
    }
    return _allBindings()
        .where((binding) => binding.scope == scope)
        .where((binding) => binding.targetId == targetId)
        .where((binding) => includeDisabled || binding.enabled)
        .toList(growable: false);
  }

  @override
  Future<void> saveBinding(DataBankBinding binding) async {
    _requireDocument(binding.documentId);
    _bindings[binding.id] = jsonEncode(binding.toJson());
  }

  @override
  Future<void> deleteBinding(String bindingId) async {
    _bindings.remove(bindingId);
  }

  @override
  Future<void> replaceCurrentVersion({
    required String documentId,
    required String expectedCurrentVersionId,
    required DataBankDocumentVersion replacement,
  }) async {
    final document = _requireDocument(documentId);
    final previous = _requireVersion(expectedCurrentVersionId);
    if (document.currentVersionId != expectedCurrentVersionId) {
      throw StateError('The current version changed before replacement.');
    }
    if (replacement.documentId != documentId ||
        replacement.supersedesVersionId != previous.id ||
        replacement.versionNumber != previous.versionNumber + 1) {
      throw ArgumentError('Replacement version lineage is invalid.');
    }

    _writeVersion(replacement);
    _writeDocument(
      DataBankDocument(
        id: document.id,
        currentVersionId: replacement.id,
        processingState: replacement.processingState,
        indexState: replacement.indexState,
        failure: replacement.failure,
        reprocessing: replacement.reprocessing,
        createdAt: document.createdAt,
        updatedAt: replacement.importedAt,
      ),
    );
  }

  @override
  Future<void> transitionDocument({
    required String documentId,
    required DataBankProcessingState from,
    required DataBankProcessingState to,
    DataBankFailure? failure,
  }) async {
    final document = _requireDocument(documentId);
    if (document.processingState != from) {
      throw StateError('Document $documentId is not in ${from.name}.');
    }
    from.validateTransitionTo(to);
    _writeDocument(
      _transitionedDocument(document, to: to, failure: failure),
    );
  }

  @override
  Future<void> transitionVersion({
    required String versionId,
    required DataBankProcessingState from,
    required DataBankProcessingState to,
    DataBankFailure? failure,
  }) async {
    final version = _requireVersion(versionId);
    if (version.processingState != from) {
      throw StateError('Version $versionId is not in ${from.name}.');
    }
    from.validateTransitionTo(to);
    _writeVersion(_transitionedVersion(version, to: to, failure: failure));
  }

  @override
  Future<void> requestReprocessing({
    required String documentId,
    required String versionId,
    required String reason,
    required DateTime requestedAt,
  }) async {
    final document = _requireDocument(documentId);
    final version = _requireVersion(versionId);
    if (version.documentId != documentId ||
        document.currentVersionId != versionId) {
      throw ArgumentError('Only the current document version can reprocess.');
    }
    document.processingState.validateTransitionTo(
      DataBankProcessingState.pending,
    );
    version.processingState.validateTransitionTo(
      DataBankProcessingState.pending,
    );
    final metadata = DataBankReprocessingMetadata(
      attemptCount: version.reprocessing.attemptCount + 1,
      requestedAt: requestedAt,
      lastAttemptAt: requestedAt,
      reason: reason,
    );
    _writeDocument(
      DataBankDocument(
        id: document.id,
        currentVersionId: document.currentVersionId,
        processingState: DataBankProcessingState.pending,
        indexState: DataBankIndexState.stale,
        reprocessing: metadata,
        createdAt: document.createdAt,
        updatedAt: requestedAt,
      ),
    );
    _writeVersion(
      DataBankDocumentVersion(
        id: version.id,
        documentId: version.documentId,
        versionNumber: version.versionNumber,
        supersedesVersionId: version.supersedesVersionId,
        originalFileName: version.originalFileName,
        mediaType: version.mediaType,
        byteSize: version.byteSize,
        contentHash: version.contentHash,
        importedAt: version.importedAt,
        processingState: DataBankProcessingState.pending,
        indexState: DataBankIndexState.stale,
        reprocessing: metadata,
      ),
    );
  }

  @override
  Future<void> setDocumentEnabled(String documentId, bool enabled) async {
    final document = _requireDocument(documentId);
    if (document.processingState == DataBankProcessingState.deleted) {
      throw StateError('Deleted documents cannot be enabled or disabled.');
    }
    if (enabled == document.isEnabled) return;
    final next = enabled
        ? DataBankProcessingState.pending
        : DataBankProcessingState.disabled;
    document.processingState.validateTransitionTo(next);
    _writeDocument(_transitionedDocument(document, to: next));
  }

  @override
  Future<void> markDocumentDeleted(String documentId) async {
    final document = _requireDocument(documentId);
    document.processingState.validateTransitionTo(
      DataBankProcessingState.deleted,
    );
    _writeDocument(
      _transitionedDocument(
        document,
        to: DataBankProcessingState.deleted,
      ),
    );
  }

  Iterable<DataBankBinding> _allBindings() sync* {
    for (final encoded in _bindings.values) {
      yield DataBankBinding.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
    }
  }

  DataBankDocument? _readDocument(String id) {
    final encoded = _documents[id];
    if (encoded == null) return null;
    return DataBankDocument.fromJson(
      jsonDecode(encoded) as Map<String, dynamic>,
    );
  }

  DataBankDocumentVersion? _readVersion(String id) {
    final encoded = _versions[id];
    if (encoded == null) return null;
    return DataBankDocumentVersion.fromJson(
      jsonDecode(encoded) as Map<String, dynamic>,
    );
  }

  DataBankDocument _requireDocument(String id) {
    final document = _readDocument(id);
    if (document == null) throw StateError('Document $id does not exist.');
    return document;
  }

  DataBankDocumentVersion _requireVersion(String id) {
    final version = _readVersion(id);
    if (version == null) throw StateError('Version $id does not exist.');
    return version;
  }

  void _writeDocument(DataBankDocument document) {
    _documents[document.id] = jsonEncode(document.toJson());
  }

  void _writeVersion(DataBankDocumentVersion version) {
    _versions[version.id] = jsonEncode(version.toJson());
  }

  DataBankDocument _transitionedDocument(
    DataBankDocument document, {
    required DataBankProcessingState to,
    DataBankFailure? failure,
  }) {
    return DataBankDocument(
      id: document.id,
      currentVersionId: document.currentVersionId,
      processingState: to,
      indexState: _indexStateAfterTransition(document.indexState, to),
      failure: failure,
      reprocessing: document.reprocessing,
      createdAt: document.createdAt,
      updatedAt: document.updatedAt,
    );
  }

  DataBankDocumentVersion _transitionedVersion(
    DataBankDocumentVersion version, {
    required DataBankProcessingState to,
    DataBankFailure? failure,
  }) {
    return DataBankDocumentVersion(
      id: version.id,
      documentId: version.documentId,
      versionNumber: version.versionNumber,
      supersedesVersionId: version.supersedesVersionId,
      originalFileName: version.originalFileName,
      mediaType: version.mediaType,
      byteSize: version.byteSize,
      contentHash: version.contentHash,
      importedAt: version.importedAt,
      processingState: to,
      indexState: _indexStateAfterTransition(version.indexState, to),
      failure: failure,
      reprocessing: version.reprocessing,
    );
  }

  DataBankIndexState _indexStateAfterTransition(
    DataBankIndexState current,
    DataBankProcessingState processing,
  ) {
    return switch (processing) {
      DataBankProcessingState.disabled => DataBankIndexState.disabled,
      DataBankProcessingState.deleted => DataBankIndexState.deleted,
      _
          when current == DataBankIndexState.disabled ||
              current == DataBankIndexState.deleted =>
        DataBankIndexState.notIndexed,
      _ => current,
    };
  }
}

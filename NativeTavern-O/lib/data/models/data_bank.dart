/// Storage-independent contracts for documents managed by the local Data Bank.
///
/// These models deliberately contain no parser, database, embedding, or file
/// system concerns. Stable document IDs can later be referenced by chat
/// attachments without coupling [DataBankDocument] to image-only attachments.
library;

enum DataBankProcessingState {
  pending,
  processing,
  ready,
  failed,
  disabled,
  deleted,
}

extension DataBankProcessingStateTransitions on DataBankProcessingState {
  bool canTransitionTo(DataBankProcessingState next) {
    if (next == this) return false;

    return switch (this) {
      DataBankProcessingState.pending =>
        next == DataBankProcessingState.processing ||
            next == DataBankProcessingState.disabled ||
            next == DataBankProcessingState.deleted,
      DataBankProcessingState.processing =>
        next == DataBankProcessingState.ready ||
            next == DataBankProcessingState.failed ||
            next == DataBankProcessingState.disabled ||
            next == DataBankProcessingState.deleted,
      DataBankProcessingState.ready =>
        next == DataBankProcessingState.pending ||
            next == DataBankProcessingState.disabled ||
            next == DataBankProcessingState.deleted,
      DataBankProcessingState.failed =>
        next == DataBankProcessingState.pending ||
            next == DataBankProcessingState.disabled ||
            next == DataBankProcessingState.deleted,
      DataBankProcessingState.disabled =>
        next == DataBankProcessingState.pending ||
            next == DataBankProcessingState.deleted,
      DataBankProcessingState.deleted => false,
    };
  }

  void validateTransitionTo(DataBankProcessingState next) {
    if (!canTransitionTo(next)) {
      throw DataBankValidationException(
        'processingState',
        'cannot transition from $name to ${next.name}',
      );
    }
  }
}

enum DataBankIndexState {
  notIndexed,
  queued,
  indexing,
  indexed,
  failed,
  stale,
  disabled,
  deleted,
}

enum DataBankHashAlgorithm { sha256 }

enum DataBankSectionKind { section, chapter }

enum DataBankBindingScope { global, character, chat }

final class DataBankValidationException implements Exception {
  final String field;
  final String message;

  const DataBankValidationException(this.field, this.message);

  @override
  String toString() => 'Invalid Data Bank $field: $message';
}

final class DataBankContentHash {
  final DataBankHashAlgorithm algorithm;
  final String digest;

  factory DataBankContentHash({
    required DataBankHashAlgorithm algorithm,
    required String digest,
  }) {
    final normalizedDigest = digest.toLowerCase();
    final expectedLength = switch (algorithm) {
      DataBankHashAlgorithm.sha256 => 64,
    };
    if (normalizedDigest.length != expectedLength ||
        !RegExp(r'^[0-9a-f]+$').hasMatch(normalizedDigest)) {
      throw DataBankValidationException(
        'contentHash',
        '${algorithm.name} digests must contain exactly '
            '$expectedLength hexadecimal characters',
      );
    }
    return DataBankContentHash._(algorithm, normalizedDigest);
  }

  const DataBankContentHash._(this.algorithm, this.digest);

  factory DataBankContentHash.fromJson(Map<String, dynamic> json) {
    return DataBankContentHash(
      algorithm: _readEnum(json, 'algorithm', DataBankHashAlgorithm.values),
      digest: _readString(json, 'digest'),
    );
  }

  Map<String, dynamic> toJson() => {
        'algorithm': algorithm.name,
        'digest': digest,
      };
}

final class DataBankFailure {
  final String code;
  final String message;
  final DateTime occurredAt;
  final bool retryable;

  factory DataBankFailure({
    required String code,
    required String message,
    required DateTime occurredAt,
    bool retryable = true,
  }) {
    _requireNonBlank(code, 'failure.code');
    _requireNonBlank(message, 'failure.message');
    return DataBankFailure._(code, message, occurredAt, retryable);
  }

  const DataBankFailure._(
    this.code,
    this.message,
    this.occurredAt,
    this.retryable,
  );

  factory DataBankFailure.fromJson(Map<String, dynamic> json) {
    return DataBankFailure(
      code: _readString(json, 'code'),
      message: _readString(json, 'message'),
      occurredAt: _readDateTime(json, 'occurredAt'),
      retryable: _readBool(json, 'retryable', fallback: true),
    );
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        'occurredAt': occurredAt.toIso8601String(),
        'retryable': retryable,
      };
}

final class DataBankReprocessingMetadata {
  final int attemptCount;
  final DateTime? requestedAt;
  final DateTime? lastAttemptAt;
  final String? reason;

  factory DataBankReprocessingMetadata({
    int attemptCount = 0,
    DateTime? requestedAt,
    DateTime? lastAttemptAt,
    String? reason,
  }) {
    if (attemptCount < 0) {
      throw const DataBankValidationException(
        'reprocessing.attemptCount',
        'must not be negative',
      );
    }
    if (attemptCount == 0 && lastAttemptAt != null) {
      throw const DataBankValidationException(
        'reprocessing.lastAttemptAt',
        'requires at least one processing attempt',
      );
    }
    _validateOptionalNonBlank(reason, 'reprocessing.reason');
    return DataBankReprocessingMetadata._(
      attemptCount,
      requestedAt,
      lastAttemptAt,
      reason,
    );
  }

  const DataBankReprocessingMetadata._(
    this.attemptCount,
    this.requestedAt,
    this.lastAttemptAt,
    this.reason,
  );

  factory DataBankReprocessingMetadata.fromJson(Map<String, dynamic> json) {
    return DataBankReprocessingMetadata(
      attemptCount: _readInt(json, 'attemptCount', fallback: 0),
      requestedAt: _readOptionalDateTime(json, 'requestedAt'),
      lastAttemptAt: _readOptionalDateTime(json, 'lastAttemptAt'),
      reason: _readOptionalString(json, 'reason'),
    );
  }

  Map<String, dynamic> toJson() => {
        'attemptCount': attemptCount,
        if (requestedAt != null) 'requestedAt': requestedAt!.toIso8601String(),
        if (lastAttemptAt != null)
          'lastAttemptAt': lastAttemptAt!.toIso8601String(),
        if (reason != null) 'reason': reason,
      };
}

final class DataBankDocument {
  final String id;
  final String currentVersionId;
  final DataBankProcessingState processingState;
  final DataBankIndexState indexState;
  final DataBankFailure? failure;
  final DataBankReprocessingMetadata reprocessing;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory DataBankDocument({
    required String id,
    required String currentVersionId,
    DataBankProcessingState processingState = DataBankProcessingState.pending,
    DataBankIndexState indexState = DataBankIndexState.notIndexed,
    DataBankFailure? failure,
    DataBankReprocessingMetadata? reprocessing,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    _requireId(id, 'document.id');
    _requireId(currentVersionId, 'document.currentVersionId');
    _validateTimestamps(createdAt, updatedAt, 'document');
    _validateStateMetadata(processingState, indexState, failure, 'document');
    return DataBankDocument._(
      id,
      currentVersionId,
      processingState,
      indexState,
      failure,
      reprocessing ?? DataBankReprocessingMetadata(),
      createdAt,
      updatedAt,
    );
  }

  const DataBankDocument._(
    this.id,
    this.currentVersionId,
    this.processingState,
    this.indexState,
    this.failure,
    this.reprocessing,
    this.createdAt,
    this.updatedAt,
  );

  bool get isEnabled =>
      processingState != DataBankProcessingState.disabled &&
      processingState != DataBankProcessingState.deleted;

  factory DataBankDocument.fromJson(Map<String, dynamic> json) {
    return DataBankDocument(
      id: _readString(json, 'id'),
      currentVersionId: _readString(json, 'currentVersionId'),
      processingState: _readEnum(
        json,
        'processingState',
        DataBankProcessingState.values,
        fallback: DataBankProcessingState.pending,
      ),
      indexState: _readEnum(
        json,
        'indexState',
        DataBankIndexState.values,
        fallback: DataBankIndexState.notIndexed,
      ),
      failure: _readOptionalObject(json, 'failure', DataBankFailure.fromJson),
      reprocessing: _readOptionalObject(
        json,
        'reprocessing',
        DataBankReprocessingMetadata.fromJson,
      ),
      createdAt: _readDateTime(json, 'createdAt'),
      updatedAt: _readDateTime(json, 'updatedAt'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'currentVersionId': currentVersionId,
        'processingState': processingState.name,
        'indexState': indexState.name,
        if (failure != null) 'failure': failure!.toJson(),
        'reprocessing': reprocessing.toJson(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };
}

final class DataBankDocumentVersion {
  final String id;
  final String documentId;
  final int versionNumber;
  final String? supersedesVersionId;
  final String originalFileName;
  final String mediaType;
  final int byteSize;
  final DataBankContentHash contentHash;
  final DateTime importedAt;
  final DataBankProcessingState processingState;
  final DataBankIndexState indexState;
  final DataBankFailure? failure;
  final DataBankReprocessingMetadata reprocessing;

  factory DataBankDocumentVersion({
    required String id,
    required String documentId,
    required int versionNumber,
    String? supersedesVersionId,
    required String originalFileName,
    required String mediaType,
    required int byteSize,
    required DataBankContentHash contentHash,
    required DateTime importedAt,
    DataBankProcessingState processingState = DataBankProcessingState.pending,
    DataBankIndexState indexState = DataBankIndexState.notIndexed,
    DataBankFailure? failure,
    DataBankReprocessingMetadata? reprocessing,
  }) {
    _requireId(id, 'version.id');
    _requireId(documentId, 'version.documentId');
    if (versionNumber < 1) {
      throw const DataBankValidationException(
        'version.versionNumber',
        'must be at least 1',
      );
    }
    _validateOptionalId(supersedesVersionId, 'version.supersedesVersionId');
    if (supersedesVersionId == id) {
      throw const DataBankValidationException(
        'version.supersedesVersionId',
        'must reference a different version',
      );
    }
    if (versionNumber == 1 && supersedesVersionId != null) {
      throw const DataBankValidationException(
        'version.supersedesVersionId',
        'the first version cannot supersede another version',
      );
    }
    if (versionNumber > 1 && supersedesVersionId == null) {
      throw const DataBankValidationException(
        'version.supersedesVersionId',
        'replacement versions must identify the version they supersede',
      );
    }
    _requireNonBlank(originalFileName, 'version.originalFileName');
    _validateMediaType(mediaType);
    if (byteSize < 0) {
      throw const DataBankValidationException(
        'version.byteSize',
        'must not be negative',
      );
    }
    _validateStateMetadata(processingState, indexState, failure, 'version');
    return DataBankDocumentVersion._(
      id,
      documentId,
      versionNumber,
      supersedesVersionId,
      originalFileName,
      mediaType,
      byteSize,
      contentHash,
      importedAt,
      processingState,
      indexState,
      failure,
      reprocessing ?? DataBankReprocessingMetadata(),
    );
  }

  const DataBankDocumentVersion._(
    this.id,
    this.documentId,
    this.versionNumber,
    this.supersedesVersionId,
    this.originalFileName,
    this.mediaType,
    this.byteSize,
    this.contentHash,
    this.importedAt,
    this.processingState,
    this.indexState,
    this.failure,
    this.reprocessing,
  );

  factory DataBankDocumentVersion.fromJson(Map<String, dynamic> json) {
    return DataBankDocumentVersion(
      id: _readString(json, 'id'),
      documentId: _readString(json, 'documentId'),
      versionNumber: _readInt(json, 'versionNumber'),
      supersedesVersionId: _readOptionalString(json, 'supersedesVersionId'),
      originalFileName: _readString(json, 'originalFileName'),
      mediaType: _readString(json, 'mediaType'),
      byteSize: _readInt(json, 'byteSize'),
      contentHash: DataBankContentHash.fromJson(_readMap(json, 'contentHash')),
      importedAt: _readDateTime(json, 'importedAt'),
      processingState: _readEnum(
        json,
        'processingState',
        DataBankProcessingState.values,
        fallback: DataBankProcessingState.pending,
      ),
      indexState: _readEnum(
        json,
        'indexState',
        DataBankIndexState.values,
        fallback: DataBankIndexState.notIndexed,
      ),
      failure: _readOptionalObject(json, 'failure', DataBankFailure.fromJson),
      reprocessing: _readOptionalObject(
        json,
        'reprocessing',
        DataBankReprocessingMetadata.fromJson,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'documentId': documentId,
        'versionNumber': versionNumber,
        if (supersedesVersionId != null)
          'supersedesVersionId': supersedesVersionId,
        'originalFileName': originalFileName,
        'mediaType': mediaType,
        'byteSize': byteSize,
        'contentHash': contentHash.toJson(),
        'importedAt': importedAt.toIso8601String(),
        'processingState': processingState.name,
        'indexState': indexState.name,
        if (failure != null) 'failure': failure!.toJson(),
        'reprocessing': reprocessing.toJson(),
      };
}

final class DataBankSourceLocator {
  final String documentVersionId;
  final String? sectionId;
  final int? pageStart;
  final int? pageEnd;
  final String? chapter;
  final int? startOffset;
  final int? endOffset;

  factory DataBankSourceLocator({
    required String documentVersionId,
    String? sectionId,
    int? pageStart,
    int? pageEnd,
    String? chapter,
    int? startOffset,
    int? endOffset,
  }) {
    _requireId(documentVersionId, 'locator.documentVersionId');
    _validateOptionalId(sectionId, 'locator.sectionId');
    _validateOptionalNonBlank(chapter, 'locator.chapter');
    if (pageStart == null && pageEnd != null) {
      throw const DataBankValidationException(
        'locator.pageEnd',
        'requires pageStart',
      );
    }
    if (pageStart != null && pageStart < 1) {
      throw const DataBankValidationException(
        'locator.pageStart',
        'page numbers start at 1',
      );
    }
    if (pageEnd != null && pageEnd < pageStart!) {
      throw const DataBankValidationException(
        'locator.pageEnd',
        'must not precede pageStart',
      );
    }
    if ((startOffset == null) != (endOffset == null)) {
      throw const DataBankValidationException(
        'locator.textOffsets',
        'startOffset and endOffset must be provided together',
      );
    }
    if (startOffset != null && startOffset < 0) {
      throw const DataBankValidationException(
        'locator.startOffset',
        'must not be negative',
      );
    }
    if (endOffset != null && endOffset <= startOffset!) {
      throw const DataBankValidationException(
        'locator.endOffset',
        'must be greater than startOffset',
      );
    }
    if (sectionId == null &&
        pageStart == null &&
        chapter == null &&
        startOffset == null) {
      throw const DataBankValidationException(
        'locator',
        'must include a section, page, chapter, or text range',
      );
    }
    return DataBankSourceLocator._(
      documentVersionId,
      sectionId,
      pageStart,
      pageEnd,
      chapter,
      startOffset,
      endOffset,
    );
  }

  const DataBankSourceLocator._(
    this.documentVersionId,
    this.sectionId,
    this.pageStart,
    this.pageEnd,
    this.chapter,
    this.startOffset,
    this.endOffset,
  );

  int? get effectivePageEnd => pageEnd ?? pageStart;

  factory DataBankSourceLocator.fromJson(Map<String, dynamic> json) {
    return DataBankSourceLocator(
      documentVersionId: _readString(json, 'documentVersionId'),
      sectionId: _readOptionalString(json, 'sectionId'),
      pageStart: _readOptionalInt(json, 'pageStart'),
      pageEnd: _readOptionalInt(json, 'pageEnd'),
      chapter: _readOptionalString(json, 'chapter'),
      startOffset: _readOptionalInt(json, 'startOffset'),
      endOffset: _readOptionalInt(json, 'endOffset'),
    );
  }

  Map<String, dynamic> toJson() => {
        'documentVersionId': documentVersionId,
        if (sectionId != null) 'sectionId': sectionId,
        if (pageStart != null) 'pageStart': pageStart,
        if (pageEnd != null) 'pageEnd': pageEnd,
        if (chapter != null) 'chapter': chapter,
        if (startOffset != null) 'startOffset': startOffset,
        if (endOffset != null) 'endOffset': endOffset,
      };
}

final class DataBankSection {
  final String id;
  final String documentVersionId;
  final DataBankSectionKind kind;
  final String? title;
  final int ordinal;
  final String? parentSectionId;
  final DataBankSourceLocator locator;

  factory DataBankSection({
    required String id,
    required String documentVersionId,
    required DataBankSectionKind kind,
    String? title,
    required int ordinal,
    String? parentSectionId,
    required DataBankSourceLocator locator,
  }) {
    _requireId(id, 'section.id');
    _requireId(documentVersionId, 'section.documentVersionId');
    _validateOptionalNonBlank(title, 'section.title');
    _validateOptionalId(parentSectionId, 'section.parentSectionId');
    if (kind == DataBankSectionKind.chapter && title == null) {
      throw const DataBankValidationException(
        'section.title',
        'chapters require a title',
      );
    }
    if (ordinal < 0) {
      throw const DataBankValidationException(
        'section.ordinal',
        'must not be negative',
      );
    }
    if (parentSectionId == id) {
      throw const DataBankValidationException(
        'section.parentSectionId',
        'a section cannot be its own parent',
      );
    }
    if (locator.documentVersionId != documentVersionId) {
      throw const DataBankValidationException(
        'section.locator.documentVersionId',
        'must match the section documentVersionId',
      );
    }
    if (locator.sectionId != null && locator.sectionId != id) {
      throw const DataBankValidationException(
        'section.locator.sectionId',
        'must match the section id when present',
      );
    }
    return DataBankSection._(
      id,
      documentVersionId,
      kind,
      title,
      ordinal,
      parentSectionId,
      locator,
    );
  }

  const DataBankSection._(
    this.id,
    this.documentVersionId,
    this.kind,
    this.title,
    this.ordinal,
    this.parentSectionId,
    this.locator,
  );

  factory DataBankSection.fromJson(Map<String, dynamic> json) {
    return DataBankSection(
      id: _readString(json, 'id'),
      documentVersionId: _readString(json, 'documentVersionId'),
      kind: _readEnum(json, 'kind', DataBankSectionKind.values),
      title: _readOptionalString(json, 'title'),
      ordinal: _readInt(json, 'ordinal'),
      parentSectionId: _readOptionalString(json, 'parentSectionId'),
      locator: DataBankSourceLocator.fromJson(_readMap(json, 'locator')),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'documentVersionId': documentVersionId,
        'kind': kind.name,
        if (title != null) 'title': title,
        'ordinal': ordinal,
        if (parentSectionId != null) 'parentSectionId': parentSectionId,
        'locator': locator.toJson(),
      };
}

final class DataBankTextChunk {
  final String id;
  final String documentVersionId;
  final String? sectionId;
  final int ordinal;
  final String text;
  final DataBankSourceLocator locator;

  factory DataBankTextChunk({
    required String id,
    required String documentVersionId,
    String? sectionId,
    required int ordinal,
    required String text,
    required DataBankSourceLocator locator,
  }) {
    _requireId(id, 'chunk.id');
    _requireId(documentVersionId, 'chunk.documentVersionId');
    _validateOptionalId(sectionId, 'chunk.sectionId');
    if (ordinal < 0) {
      throw const DataBankValidationException(
        'chunk.ordinal',
        'must not be negative',
      );
    }
    _requireNonBlank(text, 'chunk.text');
    if (locator.documentVersionId != documentVersionId) {
      throw const DataBankValidationException(
        'chunk.locator.documentVersionId',
        'must match the chunk documentVersionId',
      );
    }
    if (locator.sectionId != sectionId) {
      throw const DataBankValidationException(
        'chunk.locator.sectionId',
        'must match the chunk sectionId',
      );
    }
    return DataBankTextChunk._(
      id,
      documentVersionId,
      sectionId,
      ordinal,
      text,
      locator,
    );
  }

  const DataBankTextChunk._(
    this.id,
    this.documentVersionId,
    this.sectionId,
    this.ordinal,
    this.text,
    this.locator,
  );

  DataBankCitation toCitation(String documentId) {
    return DataBankCitation(
      documentId: documentId,
      documentVersionId: documentVersionId,
      chunkId: id,
      quote: text,
      locator: locator,
    );
  }

  factory DataBankTextChunk.fromJson(Map<String, dynamic> json) {
    return DataBankTextChunk(
      id: _readString(json, 'id'),
      documentVersionId: _readString(json, 'documentVersionId'),
      sectionId: _readOptionalString(json, 'sectionId'),
      ordinal: _readInt(json, 'ordinal'),
      text: _readString(json, 'text'),
      locator: DataBankSourceLocator.fromJson(_readMap(json, 'locator')),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'documentVersionId': documentVersionId,
        if (sectionId != null) 'sectionId': sectionId,
        'ordinal': ordinal,
        'text': text,
        'locator': locator.toJson(),
      };
}

final class DataBankCitation {
  final String documentId;
  final String documentVersionId;
  final String chunkId;
  final String quote;
  final DataBankSourceLocator locator;

  factory DataBankCitation({
    required String documentId,
    required String documentVersionId,
    required String chunkId,
    required String quote,
    required DataBankSourceLocator locator,
  }) {
    _requireId(documentId, 'citation.documentId');
    _requireId(documentVersionId, 'citation.documentVersionId');
    _requireId(chunkId, 'citation.chunkId');
    _requireNonBlank(quote, 'citation.quote');
    if (locator.documentVersionId != documentVersionId) {
      throw const DataBankValidationException(
        'citation.locator.documentVersionId',
        'must match the citation documentVersionId',
      );
    }
    return DataBankCitation._(
      documentId,
      documentVersionId,
      chunkId,
      quote,
      locator,
    );
  }

  const DataBankCitation._(
    this.documentId,
    this.documentVersionId,
    this.chunkId,
    this.quote,
    this.locator,
  );

  factory DataBankCitation.fromJson(Map<String, dynamic> json) {
    return DataBankCitation(
      documentId: _readString(json, 'documentId'),
      documentVersionId: _readString(json, 'documentVersionId'),
      chunkId: _readString(json, 'chunkId'),
      quote: _readString(json, 'quote'),
      locator: DataBankSourceLocator.fromJson(_readMap(json, 'locator')),
    );
  }

  Map<String, dynamic> toJson() => {
        'documentId': documentId,
        'documentVersionId': documentVersionId,
        'chunkId': chunkId,
        'quote': quote,
        'locator': locator.toJson(),
      };
}

final class DataBankBinding {
  final String id;
  final String documentId;
  final DataBankBindingScope scope;
  final String? characterId;
  final String? chatId;
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory DataBankBinding({
    required String id,
    required String documentId,
    required DataBankBindingScope scope,
    String? characterId,
    String? chatId,
    bool enabled = true,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    _requireId(id, 'binding.id');
    _requireId(documentId, 'binding.documentId');
    _validateOptionalId(characterId, 'binding.characterId');
    _validateOptionalId(chatId, 'binding.chatId');
    _validateTimestamps(createdAt, updatedAt, 'binding');

    switch (scope) {
      case DataBankBindingScope.global:
        if (characterId != null || chatId != null) {
          throw const DataBankValidationException(
            'binding.scope',
            'global bindings cannot target a character or chat',
          );
        }
      case DataBankBindingScope.character:
        if (characterId == null || chatId != null) {
          throw const DataBankValidationException(
            'binding.scope',
            'character bindings require only characterId',
          );
        }
      case DataBankBindingScope.chat:
        if (chatId == null || characterId != null) {
          throw const DataBankValidationException(
            'binding.scope',
            'chat bindings require only chatId',
          );
        }
    }

    return DataBankBinding._(
      id,
      documentId,
      scope,
      characterId,
      chatId,
      enabled,
      createdAt,
      updatedAt,
    );
  }

  const DataBankBinding._(
    this.id,
    this.documentId,
    this.scope,
    this.characterId,
    this.chatId,
    this.enabled,
    this.createdAt,
    this.updatedAt,
  );

  String? get targetId => switch (scope) {
        DataBankBindingScope.global => null,
        DataBankBindingScope.character => characterId,
        DataBankBindingScope.chat => chatId,
      };

  factory DataBankBinding.fromJson(Map<String, dynamic> json) {
    return DataBankBinding(
      id: _readString(json, 'id'),
      documentId: _readString(json, 'documentId'),
      scope: _readEnum(json, 'scope', DataBankBindingScope.values),
      characterId: _readOptionalString(json, 'characterId'),
      chatId: _readOptionalString(json, 'chatId'),
      enabled: _readBool(json, 'enabled', fallback: true),
      createdAt: _readDateTime(json, 'createdAt'),
      updatedAt: _readDateTime(json, 'updatedAt'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'documentId': documentId,
        'scope': scope.name,
        if (characterId != null) 'characterId': characterId,
        if (chatId != null) 'chatId': chatId,
        'enabled': enabled,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };
}

void _validateStateMetadata(
  DataBankProcessingState processingState,
  DataBankIndexState indexState,
  DataBankFailure? failure,
  String owner,
) {
  final requiresFailure = processingState == DataBankProcessingState.failed ||
      indexState == DataBankIndexState.failed;
  if (requiresFailure && failure == null) {
    throw DataBankValidationException(
      '$owner.failure',
      'is required when processing or indexing has failed',
    );
  }
  if (!requiresFailure && failure != null) {
    throw DataBankValidationException(
      '$owner.failure',
      'is only valid when processing or indexing has failed',
    );
  }

  if (processingState == DataBankProcessingState.disabled &&
      indexState != DataBankIndexState.disabled) {
    throw DataBankValidationException(
      '$owner.indexState',
      'must be disabled when processing is disabled',
    );
  }
  if (processingState == DataBankProcessingState.deleted &&
      indexState != DataBankIndexState.deleted) {
    throw DataBankValidationException(
      '$owner.indexState',
      'must be deleted when processing is deleted',
    );
  }
  if (processingState != DataBankProcessingState.disabled &&
      processingState != DataBankProcessingState.deleted &&
      (indexState == DataBankIndexState.disabled ||
          indexState == DataBankIndexState.deleted)) {
    throw DataBankValidationException(
      '$owner.indexState',
      '${indexState.name} requires the matching processing state',
    );
  }
}

void _validateTimestamps(DateTime createdAt, DateTime updatedAt, String owner) {
  if (updatedAt.isBefore(createdAt)) {
    throw DataBankValidationException(
      '$owner.updatedAt',
      'must not precede createdAt',
    );
  }
}

void _validateMediaType(String value) {
  _requireNonBlank(value, 'version.mediaType');
  if (!RegExp(r'^[^\s/]+/[^\s/]+$').hasMatch(value)) {
    throw const DataBankValidationException(
      'version.mediaType',
      'must use a valid type/subtype media type',
    );
  }
}

void _requireId(String value, String field) {
  _requireNonBlank(value, field);
  if (value != value.trim()) {
    throw DataBankValidationException(
      field,
      'must not contain outer whitespace',
    );
  }
}

void _validateOptionalId(String? value, String field) {
  if (value != null) _requireId(value, field);
}

void _requireNonBlank(String value, String field) {
  if (value.trim().isEmpty) {
    throw DataBankValidationException(field, 'must not be blank');
  }
}

void _validateOptionalNonBlank(String? value, String field) {
  if (value != null) _requireNonBlank(value, field);
}

String _readString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! String) {
    throw DataBankValidationException(field, 'must be a string');
  }
  return value;
}

String? _readOptionalString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String) {
    throw DataBankValidationException(field, 'must be a string');
  }
  return value;
}

int _readInt(Map<String, dynamic> json, String field, {int? fallback}) {
  final value = json[field];
  if (value == null && fallback != null) return fallback;
  if (value is! int) {
    throw DataBankValidationException(field, 'must be an integer');
  }
  return value;
}

int? _readOptionalInt(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! int) {
    throw DataBankValidationException(field, 'must be an integer');
  }
  return value;
}

bool _readBool(
  Map<String, dynamic> json,
  String field, {
  required bool fallback,
}) {
  final value = json[field];
  if (value == null) return fallback;
  if (value is! bool) {
    throw DataBankValidationException(field, 'must be a boolean');
  }
  return value;
}

DateTime _readDateTime(Map<String, dynamic> json, String field) {
  final value = _readString(json, field);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw DataBankValidationException(field, 'must be an ISO-8601 timestamp');
  }
  return parsed;
}

DateTime? _readOptionalDateTime(Map<String, dynamic> json, String field) {
  if (json[field] == null) return null;
  return _readDateTime(json, field);
}

Map<String, dynamic> _readMap(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! Map<String, dynamic>) {
    throw DataBankValidationException(field, 'must be a JSON object');
  }
  return value;
}

T? _readOptionalObject<T>(
  Map<String, dynamic> json,
  String field,
  T Function(Map<String, dynamic>) decode,
) {
  if (json[field] == null) return null;
  return decode(_readMap(json, field));
}

T _readEnum<T extends Enum>(
  Map<String, dynamic> json,
  String field,
  List<T> values, {
  T? fallback,
}) {
  final raw = json[field];
  if (raw == null && fallback != null) return fallback;
  if (raw is! String) {
    throw DataBankValidationException(field, 'must be a string');
  }
  for (final value in values) {
    if (value.name == raw) return value;
  }
  throw DataBankValidationException(
    field,
    'unknown value "$raw"; expected one of '
    '${values.map((value) => value.name).join(', ')}',
  );
}

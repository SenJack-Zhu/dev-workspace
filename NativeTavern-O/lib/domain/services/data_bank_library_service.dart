// Managed document files are user-triggered and intentionally asynchronous.
// ignore_for_file: avoid_slow_async_io

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/data_bank_ingestion_service.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

typedef DataBankClock = DateTime Function();
typedef DataBankIdFactory = String Function();

final class DataBankDuplicateDocumentException implements Exception {
  final String existingDocumentId;

  const DataBankDuplicateDocumentException(this.existingDocumentId);

  @override
  String toString() => 'This file is already in the Data Bank.';
}

final class DataBankLibraryEntry {
  final DataBankDocument document;
  final DataBankDocumentVersion version;
  final List<DataBankBinding> bindings;
  final int chunkCount;
  final List<String> managedPaths;

  const DataBankLibraryEntry({
    required this.document,
    required this.version,
    required this.bindings,
    required this.chunkCount,
    required this.managedPaths,
  });
}

final class DataBankDocumentPreview {
  final DataBankDocument document;
  final DataBankDocumentVersion version;
  final List<DataBankSection> sections;
  final List<DataBankTextChunk> chunks;

  const DataBankDocumentPreview({
    required this.document,
    required this.version,
    required this.sections,
    required this.chunks,
  });
}

final class DataBankDeletionPreview {
  final String documentId;
  final String documentName;
  final int versionCount;
  final int chunkCount;
  final int bindingCount;
  final List<String> managedPaths;

  const DataBankDeletionPreview({
    required this.documentId,
    required this.documentName,
    required this.versionCount,
    required this.chunkCount,
    required this.bindingCount,
    required this.managedPaths,
  });
}

abstract interface class DataBankLibraryOperations {
  Future<List<DataBankLibraryEntry>> listDocuments();

  Future<DataBankLibraryEntry> importDocument(
    File source, {
    DataBankProgressCallback? onProgress,
  });

  Future<DataBankLibraryEntry> retryDocument(
    String documentId, {
    DataBankProgressCallback? onProgress,
  });

  Future<void> setDocumentEnabled(String documentId, bool enabled);

  Future<void> rebuildSearchIndex();

  Future<List<DataBankSearchResult>> search(
    String query, {
    int topK = 20,
    DataBankSearchFilter filter = const DataBankSearchFilter(),
  });

  Future<DataBankDocumentPreview> previewDocument(String documentId);

  Future<DataBankBinding> saveBinding({
    required String documentId,
    required DataBankBindingScope scope,
    String? targetId,
    bool enabled = true,
  });

  Future<void> removeBinding(String bindingId);

  Future<DataBankDeletionPreview> previewDeletion(String documentId);

  Future<void> deleteDocument(String documentId);

  Future<void> recoverInterruptedImports();
}

final class DataBankManagedSource {
  final File file;
  final int byteSize;
  final DataBankContentHash contentHash;

  const DataBankManagedSource({
    required this.file,
    required this.byteSize,
    required this.contentHash,
  });
}

abstract interface class DataBankManagedFileStore {
  Future<DataBankManagedSource> storeSource({
    required File source,
    required String documentId,
    required String versionId,
  });

  Future<File?> sourceFor({
    required String documentId,
    required String versionId,
  });

  Future<List<String>> listManagedPaths(String documentId);

  Future<DataBankStagedFileDeletion> stageDeletion(String documentId);

  Future<void> cleanTrash();
}

final class DataBankStagedFileDeletion {
  final Directory? _original;
  final Directory? _staged;
  bool _settled = false;

  DataBankStagedFileDeletion._(this._original, this._staged);

  Future<void> commit() async {
    if (_settled) return;
    _settled = true;
    if (_staged != null && await _staged.exists()) {
      await _staged.delete(recursive: true);
    }
  }

  Future<void> restore() async {
    if (_settled) return;
    _settled = true;
    if (_original != null &&
        _staged != null &&
        await _staged.exists() &&
        !await _original.exists()) {
      await _staged.rename(_original.path);
    }
  }
}

final class FileDataBankManagedFileStore implements DataBankManagedFileStore {
  final Directory root;
  final DataBankIdFactory _idFactory;

  FileDataBankManagedFileStore({
    required this.root,
    DataBankIdFactory? idFactory,
  }) : _idFactory = idFactory ?? const Uuid().v4;

  @override
  Future<DataBankManagedSource> storeSource({
    required File source,
    required String documentId,
    required String versionId,
  }) async {
    if (!await source.exists()) {
      throw DataBankIngestionException(
        DataBankIngestionFailureCode.sourceNotFound,
        'Source file does not exist: ${source.path}',
      );
    }
    final versionDirectory = Directory(
      path.join(root.path, documentId, versionId),
    );
    await versionDirectory.create(recursive: true);
    final extension = path.extension(source.path).toLowerCase();
    final destination = File(
      path.join(versionDirectory.path, 'source$extension'),
    );
    final temporary = File('${destination.path}.importing');
    try {
      await source.openRead().pipe(temporary.openWrite());
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
      final digest = await sha256.bind(destination.openRead()).first;
      return DataBankManagedSource(
        file: destination,
        byteSize: await destination.length(),
        contentHash: DataBankContentHash(
          algorithm: DataBankHashAlgorithm.sha256,
          digest: digest.toString(),
        ),
      );
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  @override
  Future<File?> sourceFor({
    required String documentId,
    required String versionId,
  }) async {
    final directory = Directory(path.join(root.path, documentId, versionId));
    if (!await directory.exists()) return null;
    await for (final entry in directory.list()) {
      if (entry is File &&
          path.basename(entry.path).startsWith('source') &&
          !entry.path.endsWith('.importing')) {
        return entry;
      }
    }
    return null;
  }

  @override
  Future<List<String>> listManagedPaths(String documentId) async {
    final directory = Directory(path.join(root.path, documentId));
    if (!await directory.exists()) return const [];
    final paths = <String>[];
    await for (final entry in directory.list(recursive: true)) {
      if (entry is File) paths.add(entry.path);
    }
    paths.sort();
    return paths;
  }

  @override
  Future<DataBankStagedFileDeletion> stageDeletion(String documentId) async {
    final original = Directory(path.join(root.path, documentId));
    if (!await original.exists()) {
      return DataBankStagedFileDeletion._(null, null);
    }
    final trash = Directory(path.join(root.path, '.trash'));
    await trash.create(recursive: true);
    final staged = Directory(
      path.join(trash.path, '$documentId-${_idFactory()}'),
    );
    await original.rename(staged.path);
    return DataBankStagedFileDeletion._(original, staged);
  }

  @override
  Future<void> cleanTrash() async {
    final trash = Directory(path.join(root.path, '.trash'));
    if (!await trash.exists()) return;
    await for (final entry in trash.list()) {
      await entry.delete(recursive: true);
    }
  }
}

final class DataBankLibraryService implements DataBankLibraryOperations {
  final DataBankRepository _repository;
  final DataBankIngestionService _ingestion;
  final DataBankManagedFileStore _files;
  final DataBankClock _clock;
  final DataBankIdFactory _idFactory;

  DataBankLibraryService({
    required DataBankRepository repository,
    required DataBankManagedFileStore files,
    DataBankIngestionService? ingestion,
    DataBankClock? clock,
    DataBankIdFactory? idFactory,
  })  : _repository = repository,
        _files = files,
        _ingestion = ingestion ?? DataBankIngestionService(),
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _idFactory = idFactory ?? const Uuid().v4;

  @override
  Future<List<DataBankLibraryEntry>> listDocuments() async {
    final entries = <DataBankLibraryEntry>[];
    for (final document in await _repository.listDocuments()) {
      entries.add(await _entryFor(document));
    }
    entries.sort((left, right) {
      final updated = right.document.updatedAt.compareTo(
        left.document.updatedAt,
      );
      if (updated != 0) return updated;
      return left.version.originalFileName.compareTo(
        right.version.originalFileName,
      );
    });
    return entries;
  }

  @override
  Future<DataBankLibraryEntry> importDocument(
    File source, {
    DataBankProgressCallback? onProgress,
  }) async {
    final mediaType = _mediaTypeFor(source.path);
    final documentId = _idFactory();
    final versionId = _idFactory();
    final managed = await _files.storeSource(
      source: source,
      documentId: documentId,
      versionId: versionId,
    );
    var persisted = false;
    try {
      final duplicate = await _repository.findVersionByContentHash(
        managed.contentHash,
      );
      if (duplicate != null) {
        final deletion = await _files.stageDeletion(documentId);
        await deletion.commit();
        throw DataBankDuplicateDocumentException(duplicate.documentId);
      }

      final now = _clock().toUtc();
      final version = DataBankDocumentVersion(
        id: versionId,
        documentId: documentId,
        versionNumber: 1,
        originalFileName: path.basename(source.path),
        mediaType: mediaType,
        byteSize: managed.byteSize,
        contentHash: managed.contentHash,
        importedAt: now,
      );
      final document = DataBankDocument(
        id: documentId,
        currentVersionId: versionId,
        createdAt: now,
        updatedAt: now,
      );
      final binding = DataBankBinding(
        id: _idFactory(),
        documentId: documentId,
        scope: DataBankBindingScope.global,
        createdAt: now,
        updatedAt: now,
      );
      await _repository.createPendingDocument(
        document: document,
        version: version,
        initialBinding: binding,
      );
      persisted = true;
      return _process(document, version, managed.file, onProgress: onProgress);
    } catch (_) {
      if (!persisted) {
        final deletion = await _files.stageDeletion(documentId);
        await deletion.commit();
      }
      rethrow;
    }
  }

  @override
  Future<DataBankLibraryEntry> retryDocument(
    String documentId, {
    DataBankProgressCallback? onProgress,
  }) async {
    var document = await _requireDocument(documentId);
    final version = await _requireVersion(document.currentVersionId);
    if (document.processingState == DataBankProcessingState.disabled) {
      await _repository.setDocumentEnabled(documentId, true);
      document = await _requireDocument(documentId);
    } else if (document.processingState == DataBankProcessingState.ready ||
        document.processingState == DataBankProcessingState.failed) {
      await _repository.requestReprocessing(
        documentId: documentId,
        versionId: version.id,
        reason: 'User requested rebuild',
        requestedAt: _clock().toUtc(),
      );
      document = await _requireDocument(documentId);
    }
    final source = await _files.sourceFor(
      documentId: documentId,
      versionId: version.id,
    );
    if (source == null) {
      const error = DataBankIngestionException(
        DataBankIngestionFailureCode.sourceNotFound,
        'The managed source file is missing.',
      );
      await _recordFailure(documentId, version.id, error);
      throw error;
    }
    return _process(document, version, source, onProgress: onProgress);
  }

  Future<DataBankLibraryEntry> _process(
    DataBankDocument document,
    DataBankDocumentVersion version,
    File source, {
    DataBankProgressCallback? onProgress,
  }) async {
    try {
      await _repository.beginProcessing(
        documentId: document.id,
        versionId: version.id,
        startedAt: _clock().toUtc(),
      );
      final result = await _ingestion.ingest(
        DataBankIngestionRequest(
          sourceFile: source,
          documentVersionId: version.id,
          mediaType: version.mediaType,
          onProgress: onProgress,
        ),
      );
      await _repository.completeProcessing(
        documentId: document.id,
        versionId: version.id,
        sections: result.sections,
        chunks: result.chunks,
        completedAt: _clock().toUtc(),
      );
      return _entryFor(await _requireDocument(document.id));
    } catch (error) {
      await _recordFailure(document.id, version.id, error);
      rethrow;
    }
  }

  Future<void> _recordFailure(
    String documentId,
    String versionId,
    Object error,
  ) async {
    final code = error is DataBankIngestionException
        ? error.code.name
        : 'processingFailed';
    final message = error is DataBankIngestionException
        ? error.message
        : 'The document could not be processed.';
    await _repository.failProcessing(
      documentId: documentId,
      versionId: versionId,
      failure: DataBankFailure(
        code: code,
        message: message,
        occurredAt: _clock().toUtc(),
        retryable: error is! DataBankIngestionException ||
            error.code == DataBankIngestionFailureCode.ioFailure ||
            error.code == DataBankIngestionFailureCode.sourceNotFound ||
            error.code == DataBankIngestionFailureCode.cancelled,
      ),
    );
  }

  @override
  Future<void> setDocumentEnabled(String documentId, bool enabled) async {
    final document = await _requireDocument(documentId);
    if (enabled == document.isEnabled) return;
    await _repository.setDocumentEnabled(documentId, enabled);
    if (enabled) await retryDocument(documentId);
  }

  @override
  Future<void> rebuildSearchIndex() => _repository.rebuildSearchIndex();

  @override
  Future<List<DataBankSearchResult>> search(
    String query, {
    int topK = 20,
    DataBankSearchFilter filter = const DataBankSearchFilter(),
  }) {
    return _repository.search(query, topK: topK, filter: filter);
  }

  @override
  Future<DataBankDocumentPreview> previewDocument(String documentId) async {
    final document = await _requireDocument(documentId);
    final version = await _requireVersion(document.currentVersionId);
    return DataBankDocumentPreview(
      document: document,
      version: version,
      sections: await _repository.listSections(version.id),
      chunks: await _repository.listChunks(version.id),
    );
  }

  @override
  Future<DataBankBinding> saveBinding({
    required String documentId,
    required DataBankBindingScope scope,
    String? targetId,
    bool enabled = true,
  }) async {
    await _requireDocument(documentId);
    final matching = (await _repository.listBindingsForDocument(
      documentId,
      includeDisabled: true,
    ))
        .where(
          (binding) => binding.scope == scope && binding.targetId == targetId,
        )
        .toList(growable: false);
    final existing = matching.isEmpty ? null : matching.first;
    final now = _clock().toUtc();
    final binding = DataBankBinding(
      id: existing?.id ?? _idFactory(),
      documentId: documentId,
      scope: scope,
      characterId: scope == DataBankBindingScope.character ? targetId : null,
      chatId: scope == DataBankBindingScope.chat ? targetId : null,
      enabled: enabled,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await _repository.saveBinding(binding);
    return binding;
  }

  @override
  Future<void> removeBinding(String bindingId) {
    return _repository.deleteBinding(bindingId);
  }

  @override
  Future<DataBankDeletionPreview> previewDeletion(String documentId) async {
    final entry = await _entryFor(await _requireDocument(documentId));
    final versions = await _repository.listVersions(documentId);
    var chunks = 0;
    for (final version in versions) {
      chunks += (await _repository.listChunks(version.id)).length;
    }
    return DataBankDeletionPreview(
      documentId: documentId,
      documentName: entry.version.originalFileName,
      versionCount: versions.length,
      chunkCount: chunks,
      bindingCount: entry.bindings.length,
      managedPaths: entry.managedPaths,
    );
  }

  @override
  Future<void> deleteDocument(String documentId) async {
    await _requireDocument(documentId);
    final staged = await _files.stageDeletion(documentId);
    try {
      await _repository.purgeDocument(documentId);
    } catch (_) {
      await staged.restore();
      rethrow;
    }
    await staged.commit();
  }

  @override
  Future<void> recoverInterruptedImports() async {
    try {
      await _files.cleanTrash();
    } on FileSystemException {
      // Trash cleanup is best-effort and must not hide the document library.
    }
    final documents = await _repository.listDocuments();
    for (final document in documents.where(
      (entry) =>
          entry.processingState == DataBankProcessingState.pending ||
          entry.processingState == DataBankProcessingState.processing,
    )) {
      try {
        await retryDocument(document.id);
      } catch (_) {
        // The retry records a visible failure and the remaining imports continue.
      }
    }
  }

  Future<DataBankLibraryEntry> _entryFor(DataBankDocument document) async {
    final version = await _requireVersion(document.currentVersionId);
    return DataBankLibraryEntry(
      document: document,
      version: version,
      bindings: await _repository.listBindingsForDocument(
        document.id,
        includeDisabled: true,
      ),
      chunkCount: (await _repository.listChunks(version.id)).length,
      managedPaths: await _files.listManagedPaths(document.id),
    );
  }

  Future<DataBankDocument> _requireDocument(String id) async {
    final document = await _repository.getDocument(id);
    if (document == null) throw StateError('Document $id does not exist.');
    return document;
  }

  Future<DataBankDocumentVersion> _requireVersion(String id) async {
    final version = await _repository.getVersion(id);
    if (version == null) throw StateError('Version $id does not exist.');
    return version;
  }
}

String _mediaTypeFor(String filePath) {
  return switch (path.extension(filePath).toLowerCase()) {
    '.txt' => 'text/plain',
    '.md' || '.markdown' => 'text/markdown',
    '.html' || '.htm' => 'text/html',
    '.pdf' => 'application/pdf',
    '.epub' => 'application/epub+zip',
    final extension => throw DataBankIngestionException(
        DataBankIngestionFailureCode.unsupportedFormat,
        'Unsupported document format: $extension',
      ),
  };
}

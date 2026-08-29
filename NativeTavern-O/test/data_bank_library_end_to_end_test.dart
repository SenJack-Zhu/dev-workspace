// Test fixtures intentionally exercise real asynchronous file I/O.
// ignore_for_file: avoid_slow_async_io

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/repositories/drift_data_bank_repository.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/data_bank_ingestion_service.dart';
import 'package:native_tavern/domain/services/data_bank_library_service.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporary;
  late Directory input;
  late Directory managed;
  late AppDatabase database;
  late DriftDataBankRepository repository;
  late FileDataBankManagedFileStore fileStore;
  late DataBankLibraryService service;
  late int idSequence;
  final now = DateTime.utc(2026, 8, 8, 12);

  setUp(() async {
    temporary =
        await Directory.systemTemp.createTemp('data_bank_library_test_');
    input = Directory(path.join(temporary.path, 'input'))..createSync();
    managed = Directory(path.join(temporary.path, 'managed'))..createSync();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    await database.customStatement(
      'INSERT INTO characters (id, name, created_at, modified_at) '
      "VALUES ('character-1', 'Character', 1, 1)",
    );
    repository = DriftDataBankRepository(database);
    idSequence = 0;
    String nextId() => 'generated-${idSequence++}';
    fileStore = FileDataBankManagedFileStore(
      root: managed,
      idFactory: nextId,
    );
    service = DataBankLibraryService(
      repository: repository,
      files: fileStore,
      clock: () => now.add(Duration(seconds: idSequence)),
      idFactory: nextId,
    );
  });

  tearDown(() async {
    await database.close();
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('import, search, bind, disable, rebuild, preview, and delete end to end',
      () async {
    final source = File(path.join(input.path, 'harbor.md'))
      ..writeAsStringSync('''
# Safe Harbor

Ships enter through the eastern channel before dawn.
''');
    final phases = <DataBankIngestionPhase>[];

    var entry = await service.importDocument(
      source,
      onProgress: (progress) => phases.add(progress.phase),
    );

    expect(entry.document.processingState, DataBankProcessingState.ready);
    expect(entry.document.indexState, DataBankIndexState.indexed);
    expect(entry.version.originalFileName, 'harbor.md');
    expect(entry.chunkCount, greaterThan(0));
    expect(entry.managedPaths, hasLength(1));
    expect(File(entry.managedPaths.single).existsSync(), isTrue);
    expect(phases, containsAll(DataBankIngestionPhase.values));

    var matches = await service.search('eastern channel');
    expect(matches, hasLength(1));
    expect(matches.single.citation.locator.sectionId, isNotNull);
    expect(
      matches.single.citation.locator.documentVersionId,
      entry.version.id,
    );

    await service.saveBinding(
      documentId: entry.document.id,
      scope: DataBankBindingScope.character,
      targetId: 'character-1',
    );
    entry = (await service.listDocuments()).single;
    expect(entry.bindings, hasLength(2));
    matches = await service.search(
      'eastern',
      filter: const DataBankSearchFilter.forContext(
        includeGlobal: false,
        characterId: 'character-1',
      ),
    );
    expect(matches, hasLength(1));

    await service.setDocumentEnabled(entry.document.id, false);
    expect(await service.search('eastern'), isEmpty);
    await service.setDocumentEnabled(entry.document.id, true);
    expect(await service.search('eastern'), hasLength(1));

    await database.customStatement('DROP TABLE data_bank_text_chunks_fts');
    await service.rebuildSearchIndex();
    expect(await service.search('eastern'), hasLength(1));

    final preview = await service.previewDocument(entry.document.id);
    expect(preview.sections, isNotEmpty);
    expect(
      preview.chunks.map((chunk) => chunk.text).join('\n'),
      contains('eastern channel'),
    );
    final deletion = await service.previewDeletion(entry.document.id);
    expect(deletion.chunkCount, preview.chunks.length);
    expect(deletion.bindingCount, 2);
    expect(deletion.managedPaths, hasLength(1));

    await service.deleteDocument(entry.document.id);

    expect(await service.listDocuments(), isEmpty);
    expect(await service.search('eastern'), isEmpty);
    expect(await repository.getVersion(entry.version.id), isNull);
    expect(Directory(path.join(managed.path, entry.document.id)).existsSync(),
        isFalse);
  });

  test('duplicate and parse failure paths leave recoverable, visible state',
      () async {
    final source = File(path.join(input.path, 'duplicate.txt'))
      ..writeAsStringSync('A unique searchable document.');
    await service.importDocument(source);

    await expectLater(
      service.importDocument(source),
      throwsA(isA<DataBankDuplicateDocumentException>()),
    );
    expect(await service.listDocuments(), hasLength(1));

    final empty = File(path.join(input.path, 'empty.txt'))
      ..writeAsStringSync('');
    await expectLater(
      service.importDocument(empty),
      throwsA(
        isA<DataBankIngestionException>().having(
          (error) => error.code,
          'code',
          DataBankIngestionFailureCode.emptyDocument,
        ),
      ),
    );

    final entries = await service.listDocuments();
    final failed = entries.singleWhere(
      (entry) =>
          entry.document.processingState == DataBankProcessingState.failed,
    );
    expect(failed.document.failure?.code, 'emptyDocument');
    expect(failed.managedPaths, hasLength(1));

    File(failed.managedPaths.single)
        .writeAsStringSync('The repaired document is searchable.');
    final repaired = await service.retryDocument(failed.document.id);
    expect(repaired.document.processingState, DataBankProcessingState.ready);
    expect(await service.search('repaired'), hasLength(1));
  });

  test('restart recovery resumes managed imports and isolates missing sources',
      () async {
    final resumableSource = File(path.join(input.path, 'resumable.txt'))
      ..writeAsStringSync('A resumable lighthouse reference.');
    final managedSource = await fileStore.storeSource(
      source: resumableSource,
      documentId: 'resumable',
      versionId: 'resumable-version',
    );
    await _createPending(
      repository,
      documentId: 'resumable',
      versionId: 'resumable-version',
      fileName: 'resumable.txt',
      byteSize: managedSource.byteSize,
      contentHash: managedSource.contentHash,
      now: now,
    );
    await _createPending(
      repository,
      documentId: 'missing',
      versionId: 'missing-version',
      fileName: 'missing.txt',
      byteSize: 10,
      contentHash: DataBankContentHash(
        algorithm: DataBankHashAlgorithm.sha256,
        digest: 'b' * 64,
      ),
      now: now,
    );

    await service.recoverInterruptedImports();

    expect(
      (await repository.getDocument('resumable'))?.processingState,
      DataBankProcessingState.ready,
    );
    expect(await service.search('lighthouse'), hasLength(1));
    final missing = await repository.getDocument('missing');
    expect(missing?.processingState, DataBankProcessingState.failed);
    expect(missing?.failure?.code, 'sourceNotFound');
  });
}

Future<void> _createPending(
  DriftDataBankRepository repository, {
  required String documentId,
  required String versionId,
  required String fileName,
  required int byteSize,
  required DataBankContentHash contentHash,
  required DateTime now,
}) async {
  final version = DataBankDocumentVersion(
    id: versionId,
    documentId: documentId,
    versionNumber: 1,
    originalFileName: fileName,
    mediaType: 'text/plain',
    byteSize: byteSize,
    contentHash: contentHash,
    importedAt: now,
  );
  await repository.createPendingDocument(
    document: DataBankDocument(
      id: documentId,
      currentVersionId: versionId,
      createdAt: now,
      updatedAt: now,
    ),
    version: version,
    initialBinding: DataBankBinding(
      id: '$documentId-binding',
      documentId: documentId,
      scope: DataBankBindingScope.global,
      createdAt: now,
      updatedAt: now,
    ),
  );
}

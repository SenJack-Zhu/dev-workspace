import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/repositories/drift_data_bank_repository.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';

void main() {
  late AppDatabase database;
  late DriftDataBankRepository repository;
  final now = DateTime.utc(2026, 8, 8, 12);

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    await _seedOwners(database);
    repository = DriftDataBankRepository(database);
  });

  tearDown(() => database.close());

  test('FTS returns stable citation-bearing results and treats input as text',
      () async {
    await _createReadyDocument(
      repository,
      id: 'harbor',
      content: 'Ships enter the eastern harbor channel before dawn.',
      binding: DataBankBindingScope.global,
      now: now,
    );

    final matches = await repository.search('eastern harbor');

    expect(matches, hasLength(1));
    expect(matches.single.documentName, 'harbor.md');
    expect(matches.single.snippet, contains('eastern'));
    expect(matches.single.citation.documentId, 'harbor');
    expect(matches.single.citation.locator.chapter, 'Reference');
    expect(
      await repository.search('eastern OR absent'),
      isEmpty,
    );
    expect(await repository.search('" ) ( *'), isEmpty);
    await expectLater(repository.search('harbor', topK: 0), throwsRangeError);
  });

  test(
      'binding filters include only applicable global, character, and chat data',
      () async {
    await _createReadyDocument(
      repository,
      id: 'global',
      content: 'shared compass reference',
      binding: DataBankBindingScope.global,
      now: now,
    );
    await _createReadyDocument(
      repository,
      id: 'character-a',
      content: 'shared compass reference',
      binding: DataBankBindingScope.character,
      targetId: 'character-1',
      now: now,
    );
    await _createReadyDocument(
      repository,
      id: 'character-b',
      content: 'shared compass reference',
      binding: DataBankBindingScope.character,
      targetId: 'character-2',
      now: now,
    );
    await _createReadyDocument(
      repository,
      id: 'chat',
      content: 'shared compass reference',
      binding: DataBankBindingScope.chat,
      targetId: 'chat-1',
      now: now,
    );

    final matches = await repository.search(
      'compass',
      filter: const DataBankSearchFilter.forContext(
        characterId: 'character-1',
        chatId: 'chat-1',
      ),
    );

    expect(
      matches.map((result) => result.citation.documentId).toSet(),
      {'global', 'character-a', 'chat'},
    );
    expect(
      await repository.search(
        'compass',
        filter: const DataBankSearchFilter.forContext(
          includeGlobal: false,
          characterId: 'missing-character',
        ),
      ),
      isEmpty,
    );
  });

  test('chunk replacement, disable, rebuild, and purge stay synchronized',
      () async {
    final versionId = await _createReadyDocument(
      repository,
      id: 'lifecycle',
      content: 'recoverable archive marker',
      binding: DataBankBindingScope.global,
      now: now,
    );
    expect(await repository.search('archive'), hasLength(1));

    await repository.replaceChunks(versionId, [
      _chunk(
        documentId: 'lifecycle',
        versionId: versionId,
        content: 'replacement library marker',
      ),
    ]);
    expect(await repository.search('archive'), isEmpty);
    expect(await repository.search('library'), hasLength(1));

    await repository.setDocumentEnabled('lifecycle', false);
    expect(await repository.search('library'), isEmpty);

    await repository.setDocumentEnabled('lifecycle', true);
    await repository.beginProcessing(
      documentId: 'lifecycle',
      versionId: versionId,
      startedAt: now.add(const Duration(minutes: 1)),
    );
    await repository.completeProcessing(
      documentId: 'lifecycle',
      versionId: versionId,
      sections: [_section('lifecycle', versionId)],
      chunks: [
        _chunk(
          documentId: 'lifecycle',
          versionId: versionId,
          content: 'replacement library marker',
        ),
      ],
      completedAt: now.add(const Duration(minutes: 2)),
    );
    expect(await repository.search('library'), hasLength(1));

    await database.customStatement('DROP TABLE data_bank_text_chunks_fts');
    await repository.rebuildSearchIndex();
    expect(await repository.search('library'), hasLength(1));

    await repository.purgeDocument('lifecycle');
    expect(await repository.search('library'), isEmpty);
    expect(await repository.getVersion(versionId), isNull);
    expect(await repository.listBindingsForDocument('lifecycle'), isEmpty);
  });
}

Future<String> _createReadyDocument(
  DriftDataBankRepository repository, {
  required String id,
  required String content,
  required DataBankBindingScope binding,
  String? targetId,
  required DateTime now,
}) async {
  final versionId = '$id-version';
  final version = DataBankDocumentVersion(
    id: versionId,
    documentId: id,
    versionNumber: 1,
    originalFileName: '$id.md',
    mediaType: 'text/markdown',
    byteSize: content.length,
    contentHash: DataBankContentHash(
      algorithm: DataBankHashAlgorithm.sha256,
      digest: 'a' * 64,
    ),
    importedAt: now,
  );
  final document = DataBankDocument(
    id: id,
    currentVersionId: versionId,
    createdAt: now,
    updatedAt: now,
  );
  await repository.createPendingDocument(
    document: document,
    version: version,
    initialBinding: DataBankBinding(
      id: '$id-binding',
      documentId: id,
      scope: binding,
      characterId: binding == DataBankBindingScope.character ? targetId : null,
      chatId: binding == DataBankBindingScope.chat ? targetId : null,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await repository.beginProcessing(
    documentId: id,
    versionId: versionId,
    startedAt: now,
  );
  await repository.completeProcessing(
    documentId: id,
    versionId: versionId,
    sections: [_section(id, versionId)],
    chunks: [
      _chunk(documentId: id, versionId: versionId, content: content),
    ],
    completedAt: now,
  );
  return versionId;
}

DataBankSection _section(String documentId, String versionId) {
  final sectionId = '$documentId-section';
  return DataBankSection(
    id: sectionId,
    documentVersionId: versionId,
    kind: DataBankSectionKind.chapter,
    title: 'Reference',
    ordinal: 0,
    locator: DataBankSourceLocator(
      documentVersionId: versionId,
      sectionId: sectionId,
      chapter: 'Reference',
      startOffset: 0,
      endOffset: 1,
    ),
  );
}

DataBankTextChunk _chunk({
  required String documentId,
  required String versionId,
  required String content,
}) {
  final sectionId = '$documentId-section';
  return DataBankTextChunk(
    id: '$documentId-chunk',
    documentVersionId: versionId,
    sectionId: sectionId,
    ordinal: 0,
    text: content,
    locator: DataBankSourceLocator(
      documentVersionId: versionId,
      sectionId: sectionId,
      chapter: 'Reference',
      startOffset: 0,
      endOffset: content.length,
    ),
  );
}

Future<void> _seedOwners(AppDatabase database) async {
  const statements = [
    'INSERT INTO characters (id, name, created_at, modified_at) '
        "VALUES ('character-1', 'One', 1, 1)",
    'INSERT INTO characters (id, name, created_at, modified_at) '
        "VALUES ('character-2', 'Two', 1, 1)",
    'INSERT INTO chats (id, character_id, created_at, updated_at) '
        "VALUES ('chat-1', 'character-1', 1, 1)",
  ];
  for (final statement in statements) {
    await database.customStatement(statement);
  }
}

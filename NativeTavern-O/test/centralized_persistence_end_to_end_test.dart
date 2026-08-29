import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/data/repositories/drift_data_bank_repository.dart';
import 'package:native_tavern/data/repositories/drift_long_term_memory_repository.dart';
import 'package:native_tavern/data/repositories/drift_rpg_persistence_repository.dart';

void main() {
  late AppDatabase database;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    await _seedOwners(database);
  });

  tearDown(() => database.close());

  test('long-term memories round-trip with scopes and source messages',
      () async {
    final now = DateTime.utc(2026, 8, 8, 10);
    final repository = DriftLongTermMemoryRepository(
      database,
      now: () => now.add(const Duration(hours: 2)),
    );
    final memory = LongTermMemory(
      id: 'memory-1',
      kind: MemoryKind.commitment,
      scope: MemoryScope.characterPersona(
        characterId: 'character-1',
        personaId: 'persona-1',
      ),
      state: MemoryState.active,
      content: 'Meet at the station.',
      source: MemorySource.generated(
        sourceChatId: 'chat-1',
        sourceMessageIds: const ['message-1', 'message-2'],
        extractedAt: now,
        providerId: 'provider-1',
        modelId: 'model-1',
      ),
      importance: 0.8,
      confidence: 0.9,
      createdAt: now.add(const Duration(minutes: 1)),
      normalizedIdentityKey: 'commitment:station',
    );

    expect(await repository.create(memory), memory);
    expect(
      await repository.findByScope(
        memory.scope,
        states: {MemoryState.active},
      ),
      [memory],
    );
    expect(
      await repository.findBySource(
        chatId: 'chat-1',
        messageId: 'message-2',
      ),
      [memory],
    );
    final searchResults = await repository.search(
      'station',
      scope: memory.scope,
    );
    expect(searchResults.map((result) => result.memory), [memory]);
    expect(
      searchResults.single.memory.source.sourceMessageIds,
      ['message-1', 'message-2'],
    );

    final replacement = LongTermMemory(
      id: 'memory-2',
      kind: memory.kind,
      scope: memory.scope,
      state: MemoryState.active,
      content: 'Meet at the library.',
      createdAt: now.add(const Duration(hours: 1)),
    );
    await repository.create(replacement);
    await repository.updateStates(
      memoryIds: {memory.id},
      state: MemoryState.superseded,
      supersededByMemoryId: replacement.id,
    );
    expect(
      (await repository.getById(memory.id))?.supersededByMemoryId,
      replacement.id,
    );

    await (database.delete(database.messages)
          ..where((table) => table.id.equals('message-2')))
        .go();
    expect(
      (await repository.getById(memory.id))?.source.sourceMessageIds,
      ['message-1'],
    );
    await (database.delete(database.messages)
          ..where((table) => table.id.equals('message-1')))
        .go();
    final withoutSource = await repository.getById(memory.id);
    expect(withoutSource?.source.origin, MemoryOrigin.manual);
    expect(withoutSource?.source.sourceChatId, isA<Null>());
    expect(withoutSource?.source.sourceMessageIds, isEmpty);
    expect(await _foreignKeyViolations(database), isEmpty);
  });

  test('RPG scenarios, current state, and snapshot lineage round-trip',
      () async {
    final repository = DriftRpgPersistenceRepository(database);
    final scenario = _scenario();
    await repository.saveScenario(scenario);

    final snapshot = RpgStateSnapshot(
      metadata: RpgSnapshotMetadata(
        id: 'snapshot-1',
        scenarioId: scenario.metadata.id,
        scenarioVersion: scenario.metadata.version,
        branchId: 'main',
        turn: scenario.initialState.turn,
        randomState: scenario.initialState.random.state,
        rollsConsumed: scenario.initialState.random.rollsConsumed,
        createdAt: DateTime.utc(2026, 8, 8, 11),
      ),
      state: scenario.initialState,
    );
    await repository.saveSnapshot(snapshot);
    await repository.saveCurrentState(
      chatId: 'chat-1',
      scenarioId: scenario.metadata.id,
      state: scenario.initialState,
      currentSnapshotId: snapshot.metadata.id,
      updatedAt: snapshot.metadata.createdAt,
    );

    expect((await repository.getScenario(scenario.metadata.id))?.toJson(),
        scenario.toJson());
    expect((await repository.getSnapshot(snapshot.metadata.id))?.toJson(),
        snapshot.toJson());
    expect((await repository.getCurrentState('chat-1'))?.toJson(),
        scenario.initialState.toJson());
    expect(
        await repository.getCurrentSnapshotId('chat-1'), snapshot.metadata.id);
    expect(
      await repository.listSnapshots(
        scenarioId: scenario.metadata.id,
        branchId: 'main',
      ),
      hasLength(1),
    );

    await repository.deleteScenario(scenario.metadata.id);
    expect(await repository.getSnapshot(snapshot.metadata.id), isA<Null>());
    expect(await repository.getCurrentState('chat-1'), isA<Null>());
    expect(await _foreignKeyViolations(database), isEmpty);
  });

  test('Data Bank persists lifecycle, source locators, and scoped bindings',
      () async {
    final repository = DriftDataBankRepository(database);
    final importedAt = DateTime.utc(2026, 8, 8, 12);
    final version = DataBankDocumentVersion(
      id: 'version-1',
      documentId: 'document-1',
      versionNumber: 1,
      originalFileName: 'guide.md',
      mediaType: 'text/markdown',
      byteSize: 128,
      contentHash: DataBankContentHash(
        algorithm: DataBankHashAlgorithm.sha256,
        digest: 'a' * 64,
      ),
      importedAt: importedAt,
    );
    final document = DataBankDocument(
      id: version.documentId,
      currentVersionId: version.id,
      createdAt: importedAt,
      updatedAt: importedAt,
    );

    await repository.saveVersion(version);
    expect(await repository.getDocument(document.id), isA<Null>());
    await repository.saveDocument(document);

    final parentLocator = DataBankSourceLocator(
      documentVersionId: version.id,
      sectionId: 'section-parent',
      chapter: 'One',
    );
    final childLocator = DataBankSourceLocator(
      documentVersionId: version.id,
      sectionId: 'section-child',
      pageStart: 2,
    );
    final child = DataBankSection(
      id: 'section-child',
      documentVersionId: version.id,
      kind: DataBankSectionKind.section,
      ordinal: 1,
      parentSectionId: 'section-parent',
      locator: childLocator,
    );
    final parent = DataBankSection(
      id: 'section-parent',
      documentVersionId: version.id,
      kind: DataBankSectionKind.chapter,
      title: 'One',
      ordinal: 0,
      locator: parentLocator,
    );
    await repository.replaceSections(version.id, [child, parent]);
    await repository.replaceChunks(version.id, [
      DataBankTextChunk(
        id: 'chunk-1',
        documentVersionId: version.id,
        sectionId: child.id,
        ordinal: 0,
        text: 'The source can be traced.',
        locator: childLocator,
      ),
    ]);
    await repository.saveBinding(
      DataBankBinding(
        id: 'binding-1',
        documentId: document.id,
        scope: DataBankBindingScope.character,
        characterId: 'character-2',
        createdAt: importedAt,
        updatedAt: importedAt,
      ),
    );

    expect((await repository.getDocument(document.id))?.toJson(),
        document.toJson());
    expect(
      (await repository.listSections(version.id))
          .map((section) => section.toJson())
          .toList(),
      [parent.toJson(), child.toJson()],
    );
    expect((await repository.getChunk('chunk-1'))?.locator.pageStart, 2);
    expect(
      await repository.listBindingsForScope(
        DataBankBindingScope.character,
        targetId: 'character-2',
      ),
      hasLength(1),
    );

    await repository.transitionDocument(
      documentId: document.id,
      from: DataBankProcessingState.pending,
      to: DataBankProcessingState.processing,
    );
    expect(
      (await repository.getDocument(document.id))?.processingState,
      DataBankProcessingState.processing,
    );

    await expectLater(
      database.customStatement('''
        UPDATE data_bank_documents
        SET current_version_id = 'missing-version'
        WHERE id = 'document-1'
      '''),
      throwsA(anything),
    );
    await (database.delete(database.characters)
          ..where((table) => table.id.equals('character-2')))
        .go();
    expect(
      await repository.listBindingsForDocument(document.id),
      isEmpty,
    );
    await (database.delete(database.dataBankDocuments)
          ..where((table) => table.id.equals(document.id)))
        .go();
    expect(await repository.getVersion(version.id), isA<Null>());
    expect(await repository.getChunk('chunk-1'), isA<Null>());
    expect(await _foreignKeyViolations(database), isEmpty);
  });
}

Future<void> _seedOwners(AppDatabase database) async {
  const statements = [
    'INSERT INTO characters (id, name, created_at, modified_at) '
        "VALUES ('character-1', 'Character', 1, 1)",
    'INSERT INTO characters (id, name, created_at, modified_at) '
        "VALUES ('character-2', 'Unbound Character', 1, 1)",
    'INSERT INTO personas (id, name, created_at, updated_at) '
        "VALUES ('persona-1', 'Persona', 1, 1)",
    'INSERT INTO groups (id, name, created_at, modified_at) '
        "VALUES ('group-1', 'Group', 1, 1)",
    'INSERT INTO chats (id, character_id, created_at, updated_at) '
        "VALUES ('chat-1', 'character-1', 1, 1)",
    'INSERT INTO messages (id, chat_id, role, content, timestamp) '
        "VALUES ('message-1', 'chat-1', 'user', 'First', 1)",
    'INSERT INTO messages (id, chat_id, role, content, timestamp) '
        "VALUES ('message-2', 'chat-1', 'assistant', 'Second', 2)",
  ];
  for (final statement in statements) {
    await database.customStatement(statement);
  }
}

RpgScenario _scenario() {
  const state = RpgRuntimeState(
    scenarioId: 'scenario-1',
    scenarioVersion: '1.0.0',
    turn: 2,
    random: RpgRandomState(initialSeed: 7, state: 11, rollsConsumed: 1),
  );
  return const RpgScenario(
    metadata: RpgScenarioMetadata(
      id: 'scenario-1',
      name: 'Scenario',
      version: '1.0.0',
    ),
    initialSeed: 7,
    initialState: state,
  );
}

Future<List<Map<String, Object?>>> _foreignKeyViolations(
  AppDatabase database,
) async {
  final rows = await database.customSelect('PRAGMA foreign_key_check').get();
  return rows.map((row) => row.data).toList();
}

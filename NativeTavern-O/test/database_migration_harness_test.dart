import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/repositories/drift_data_bank_repository.dart';
import 'package:native_tavern/data/repositories/drift_long_term_memory_repository.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/database_backup_service.dart';

import 'support/database_migration_harness.dart';

const _currentSchemaVersion = 23;

void main() {
  late MigrationTestHarness harness;

  setUp(() {
    harness = MigrationTestHarness.create();
  });

  tearDown(() async {
    await harness.dispose();
  });

  test('fresh databases create the complete current schema', () async {
    final database = harness.createCurrentDatabase();

    expect(await readSchemaVersion(database), _currentSchemaVersion);
    expect(await runIntegrityCheck(database), 'ok');
    expect(await findForeignKeyViolations(database), isEmpty);
    expect(
      await readTableNames(database),
      containsAll(currentSnapshotTables.map((table) => table.name)),
    );
  });

  test('v10 fixture migrates through v11-v15 without losing logical data',
      () async {
    final file = harness.createFixture(LegacyDatabaseFixtures.v10);
    final before = captureRawDatabaseSnapshot(
      file,
      legacyV10PreservedSnapshotTables,
    );
    final database = harness.openWithProductionMigrations(file);

    expect(await readSchemaVersion(database), _currentSchemaVersion);
    final after = await captureDatabaseSnapshot(
      database,
      legacyV10PreservedSnapshotTables,
    );

    expect(after.tables, before.tables);
    expect(await runIntegrityCheck(database), 'ok');
    expect(await findForeignKeyViolations(database), isEmpty);
    expect(await readTableNames(database), contains('global_states'));

    final worldInfo = await database.customSelect('''
      SELECT scan_depth, case_sensitive, match_whole_words,
             use_group_scoring, recursion_depth, extensions_json
      FROM world_infos WHERE id = 'world-1'
    ''').getSingle();
    expect(
      worldInfo.data,
      {
        'scan_depth': null,
        'case_sensitive': null,
        'match_whole_words': null,
        'use_group_scoring': null,
        'recursion_depth': null,
        'extensions_json': '{}',
      },
    );

    final persona = await database.customSelect('''
      SELECT connections_json, description_settings_json, lorebook_id,
             system_prompt_override, post_history_instructions, tags_json,
             creator_notes, is_favorite
      FROM personas WHERE id = 'persona-1'
    ''').getSingle();
    expect(
      persona.data,
      {
        'connections_json': '[]',
        'description_settings_json': '{}',
        'lorebook_id': null,
        'system_prompt_override': null,
        'post_history_instructions': null,
        'tags_json': '[]',
        'creator_notes': '',
        'is_favorite': 0,
      },
    );
  });

  test('v13 fixture preserves extended world-info and global-state data',
      () async {
    final file = harness.createFixture(LegacyDatabaseFixtures.v13);
    final before = captureRawDatabaseSnapshot(
      file,
      legacyV13PreservedSnapshotTables,
    );
    final database = harness.openWithProductionMigrations(file);

    expect(await readSchemaVersion(database), _currentSchemaVersion);
    final after = await captureDatabaseSnapshot(
      database,
      legacyV13PreservedSnapshotTables,
    );

    expect(after.tables, before.tables);
    expect(await runIntegrityCheck(database), 'ok');
    expect(await findForeignKeyViolations(database), isEmpty);
  });

  test('v14 fixture gains all domain tables and can be reopened', () async {
    final file = harness.createFixture(LegacyDatabaseFixtures.v14);
    final before = captureRawDatabaseSnapshot(
      file,
      legacyV13PreservedSnapshotTables,
    );
    var database = harness.openWithProductionMigrations(file);

    expect(await readSchemaVersion(database), _currentSchemaVersion);
    expect(
      (await captureDatabaseSnapshot(
        database,
        legacyV13PreservedSnapshotTables,
      ))
          .tables,
      before.tables,
    );
    expect(await runIntegrityCheck(database), 'ok');
    expect(await findForeignKeyViolations(database), isEmpty);
    expect(
      await readTableNames(database),
      containsAll(currentSnapshotTables.map((table) => table.name)),
    );

    await harness.close(database);
    database = harness.openWithProductionMigrations(file);
    expect(await readSchemaVersion(database), _currentSchemaVersion);
    expect(await runIntegrityCheck(database), 'ok');
  });

  test('complete v15 schema recovers a version marker downgraded to v13',
      () async {
    final file = File('${harness.directory.path}/downgraded_marker.sqlite');
    var database = harness.openWithProductionMigrations(file);
    await seedCurrentRepresentativeData(database);
    final before =
        await captureDatabaseSnapshot(database, currentSnapshotTables);
    await harness.close(database);

    writeRawSchemaVersion(file, 13);
    expect(readRawSchemaVersion(file), 13);

    database = harness.openWithProductionMigrations(file);
    expect(await readSchemaVersion(database), _currentSchemaVersion);
    expect(
      (await captureDatabaseSnapshot(database, currentSnapshotTables)).tables,
      before.tables,
    );
    expect(await runIntegrityCheck(database), 'ok');
    expect(await findForeignKeyViolations(database), isEmpty);
  });

  test('opening a newer database version is rejected without relabeling it',
      () async {
    final file = File('${harness.directory.path}/newer_schema.sqlite');
    var database = harness.openWithProductionMigrations(file);
    await database.customSelect('SELECT 1').get();
    await harness.close(database);

    writeRawSchemaVersion(file, _currentSchemaVersion + 1);
    database = harness.openWithProductionMigrations(file);

    await expectLater(
      database.customSelect('SELECT 1').get(),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('schema 24 -> 23'),
        ),
      ),
    );
    await harness.close(database);

    expect(readRawSchemaVersion(file), _currentSchemaVersion + 1);
  });

  test('existing v15 data gains a rebuilt derived memory search index',
      () async {
    final file = File('${harness.directory.path}/derived_fts.sqlite');
    var database = harness.openWithProductionMigrations(file);
    await seedCurrentRepresentativeData(database);
    await database.customStatement('DROP TABLE long_term_memories_fts');
    await harness.close(database);

    database = harness.openWithProductionMigrations(file);
    final repository = DriftLongTermMemoryRepository(database);
    final matches = await repository.search(
      'representative',
      scope: MemoryScope.characterPersona(
        characterId: 'character-1',
        personaId: 'persona-1',
      ),
    );

    expect(await readSchemaVersion(database), _currentSchemaVersion);
    expect(matches.map((result) => result.memory.id), ['memory-1']);
    expect(matches.single.memory.source.sourceMessageIds, ['message-1']);
  });

  test('existing v15 data recovers a missing Data Bank search index', () async {
    final file = File('${harness.directory.path}/data_bank_fts.sqlite');
    var database = harness.openWithProductionMigrations(file);
    await seedCurrentRepresentativeData(database);
    await database.customStatement('DROP TABLE data_bank_text_chunks_fts');
    await harness.close(database);

    database = harness.openWithProductionMigrations(file);
    final repository = DriftDataBankRepository(database);
    final matches = await repository.search(
      'Fixture source',
      filter: const DataBankSearchFilter.forContext(
        characterId: 'character-1',
        chatId: 'chat-1',
      ),
    );

    expect(await readSchemaVersion(database), _currentSchemaVersion);
    expect(matches.map((result) => result.chunk.id), ['chunk-1']);
    expect(matches.single.citation.documentId, 'document-1');
    expect(matches.single.citation.documentVersionId, 'version-1');
  });

  test('failed v15 migration rolls back every new table', () async {
    final file = harness.createFixture(
      LegacyDatabaseFixtures.interruptedV14,
      name: 'interrupted_v14',
    );
    final database = harness.openWithProductionMigrations(file);

    await expectLater(
        database.customSelect('SELECT 1').get(), throwsA(anything));
    await harness.close(database);

    expect(readRawSchemaVersion(file), 14);
    expect(readRawTableNames(file), isNot(contains('long_term_memories')));
    expect(readRawTableNames(file), contains('rpg_scenarios'));
  });

  test('failed migration rolls back schema changes and version advancement',
      () async {
    final file = harness.createFixture(
      LegacyDatabaseFixtures.interruptedV10,
      name: 'interrupted_v10',
    );
    final database = harness.openWithProductionMigrations(file);

    await expectLater(
      database.customSelect('SELECT 1').get(),
      throwsA(anything),
    );
    await harness.close(database);

    expect(readRawSchemaVersion(file), 10);
    final columns = readRawTableColumns(file, 'world_info_entries');
    expect(columns, contains('automation_id'));
    expect(columns, isNot(contains('use_group_scoring')));
    expect(columns, isNot(contains('delay_until_recursion')));
  });

  test('logical backup and restore produce equivalent current data', () async {
    final source = harness.createCurrentDatabase(name: 'backup_source');
    await seedCurrentRepresentativeData(source);
    final expected = await captureDatabaseSnapshot(
      source,
      currentSnapshotTables,
    );
    final backup = await DatabaseBackupService(source).exportAllData();
    await harness.close(source);

    final restored = harness.createCurrentDatabase(name: 'backup_restored');
    expect(await readSchemaVersion(restored), _currentSchemaVersion);
    final result = await DatabaseBackupService(restored).importData(
      data: backup,
      mode: ImportMode.addNewOnly,
    );
    final actual = await captureDatabaseSnapshot(
      restored,
      currentSnapshotTables,
    );

    expect(result.charactersAdded, 1);
    expect(result.chatsAdded, 1);
    expect(result.messagesAdded, 1);
    expect(result.personasAdded, 1);
    expect(actual.tables, expected.tables);
    expect(await runIntegrityCheck(restored), 'ok');
    expect(await findForeignKeyViolations(restored), isEmpty);
  });
}

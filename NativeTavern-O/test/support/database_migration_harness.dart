import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// A database schema and data seed captured from an older app release.
class LegacyDatabaseFixture {
  const LegacyDatabaseFixture({
    required this.schemaVersion,
    required this.schemaStatements,
    required this.seedStatements,
  });

  final int schemaVersion;
  final List<String> schemaStatements;
  final List<String> seedStatements;

  void writeTo(File file) {
    if (file.existsSync()) file.deleteSync();
    file.parent.createSync(recursive: true);

    final database = sqlite.sqlite3.open(file.path);
    try {
      database.execute('PRAGMA foreign_keys = OFF');
      database.execute('BEGIN');
      for (final statement in schemaStatements) {
        database.execute(statement);
      }
      for (final statement in seedStatements) {
        database.execute(statement);
      }
      database.execute('PRAGMA user_version = $schemaVersion');
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    } finally {
      database.dispose();
    }
  }
}

/// Historical fixtures derived from committed versions of database.dart.
abstract final class LegacyDatabaseFixtures {
  static const v10 = LegacyDatabaseFixture(
    schemaVersion: 10,
    schemaStatements: _v10SchemaStatements,
    seedStatements: _representativeLegacySeedStatements,
  );

  static const v13 = LegacyDatabaseFixture(
    schemaVersion: 13,
    schemaStatements: _v13SchemaStatements,
    seedStatements: [
      ..._representativeLegacySeedStatements,
      ..._v13SeedStatements,
    ],
  );

  static const v14 = LegacyDatabaseFixture(
    schemaVersion: 14,
    schemaStatements: _v14SchemaStatements,
    seedStatements: [
      ..._representativeLegacySeedStatements,
      ..._v14SeedStatements,
    ],
  );

  /// Models an interrupted v10-to-v11 upgrade: the second v11 column exists,
  /// while the first and third do not. Production migration must fail and
  /// roll back instead of advancing user_version or leaving another column.
  static const interruptedV10 = LegacyDatabaseFixture(
    schemaVersion: 10,
    schemaStatements: [
      ..._v10SchemaStatements,
      '''
        ALTER TABLE world_info_entries
        ADD COLUMN automation_id TEXT NOT NULL DEFAULT ''
      ''',
    ],
    seedStatements: _representativeLegacySeedStatements,
  );

  /// Models a v14 database where a failed prior attempt left one v15 table.
  /// The production transaction must roll back tables created before the
  /// collision and keep the database at v14.
  static const interruptedV14 = LegacyDatabaseFixture(
    schemaVersion: 14,
    schemaStatements: [
      ..._v14SchemaStatements,
      'CREATE TABLE rpg_scenarios (id TEXT NOT NULL PRIMARY KEY)',
    ],
    seedStatements: [
      ..._representativeLegacySeedStatements,
      ..._v14SeedStatements,
    ],
  );
}

class MigrationTestHarness {
  MigrationTestHarness._(this.directory);

  final Directory directory;
  final List<AppDatabase> _openDatabases = [];

  static MigrationTestHarness create() {
    return MigrationTestHarness._(
      Directory.systemTemp.createTempSync('native_tavern_migration_'),
    );
  }

  File createFixture(
    LegacyDatabaseFixture fixture, {
    String? name,
  }) {
    final file = File(
      '${directory.path}/${name ?? 'schema_v${fixture.schemaVersion}'}.sqlite',
    );
    fixture.writeTo(file);
    return file;
  }

  AppDatabase openWithProductionMigrations(File file) {
    final database = AppDatabase.forTesting(
      NativeDatabase(
        file,
        setup: (rawDatabase) {
          rawDatabase.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    _openDatabases.add(database);
    return database;
  }

  AppDatabase createCurrentDatabase({String? name}) {
    final file = File('${directory.path}/${name ?? 'current'}.sqlite');
    return openWithProductionMigrations(file);
  }

  Future<void> close(AppDatabase database) async {
    if (_openDatabases.remove(database)) {
      await database.close();
    }
  }

  Future<void> dispose() async {
    for (final database in _openDatabases.reversed.toList()) {
      await database.close();
    }
    _openDatabases.clear();
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }
}

class SnapshotTable {
  const SnapshotTable(
    this.name, {
    required this.orderBy,
    this.columns = const [],
  });

  final String name;
  final List<String> orderBy;
  final List<String> columns;

  String get selectSql {
    final selected =
        columns.isEmpty ? '*' : columns.map(_quoteIdentifier).join(', ');
    final ordering = orderBy.map(_quoteIdentifier).join(', ');
    return 'SELECT $selected FROM ${_quoteIdentifier(name)} '
        'ORDER BY $ordering';
  }
}

class LogicalDatabaseSnapshot {
  const LogicalDatabaseSnapshot(this.tables);

  final Map<String, List<Map<String, Object?>>> tables;
}

Future<LogicalDatabaseSnapshot> captureDatabaseSnapshot(
  AppDatabase database,
  Iterable<SnapshotTable> tables,
) async {
  final snapshot = <String, List<Map<String, Object?>>>{};
  for (final table in tables) {
    final rows = await database.customSelect(table.selectSql).get();
    snapshot[table.name] =
        rows.map((row) => _normalizeRow(row.data)).toList(growable: false);
  }
  return LogicalDatabaseSnapshot(snapshot);
}

LogicalDatabaseSnapshot captureRawDatabaseSnapshot(
  File file,
  Iterable<SnapshotTable> tables,
) {
  final database =
      sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
  try {
    final snapshot = <String, List<Map<String, Object?>>>{};
    for (final table in tables) {
      final rows = database.select(table.selectSql);
      snapshot[table.name] = rows
          .map((row) => _normalizeRow(Map<String, Object?>.from(row)))
          .toList(growable: false);
    }
    return LogicalDatabaseSnapshot(snapshot);
  } finally {
    database.dispose();
  }
}

Future<int> readSchemaVersion(AppDatabase database) async {
  final row = await database.customSelect('PRAGMA user_version').getSingle();
  return row.data.values.single as int;
}

int readRawSchemaVersion(File file) {
  final database =
      sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
  try {
    return database.userVersion;
  } finally {
    database.dispose();
  }
}

void writeRawSchemaVersion(File file, int version) {
  final database = sqlite.sqlite3.open(file.path);
  try {
    database.userVersion = version;
  } finally {
    database.dispose();
  }
}

Set<String> readRawTableColumns(File file, String tableName) {
  final database =
      sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
  try {
    return database
        .select('PRAGMA table_info(${_quoteIdentifier(tableName)})')
        .map((row) => row['name'] as String)
        .toSet();
  } finally {
    database.dispose();
  }
}

Set<String> readRawTableNames(File file) {
  final database =
      sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
  try {
    return database.select('''
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        ''').map((row) => row['name'] as String).toSet();
  } finally {
    database.dispose();
  }
}

Future<Set<String>> readTableNames(AppDatabase database) async {
  final rows = await database.customSelect('''
    SELECT name FROM sqlite_master
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name
  ''').get();
  return rows.map((row) => row.read<String>('name')).toSet();
}

Future<String> runIntegrityCheck(AppDatabase database) async {
  final row = await database.customSelect('PRAGMA integrity_check').getSingle();
  return row.data.values.single as String;
}

Future<List<Map<String, Object?>>> findForeignKeyViolations(
  AppDatabase database,
) async {
  final rows = await database.customSelect('PRAGMA foreign_key_check').get();
  return rows.map((row) => _normalizeRow(row.data)).toList(growable: false);
}

Future<void> seedCurrentRepresentativeData(AppDatabase database) async {
  for (final statement in _representativeLegacySeedStatements) {
    await database.customStatement(statement);
  }
  for (final statement in _currentOnlySeedStatements) {
    await database.customStatement(statement);
  }
}

const currentSnapshotTables = <SnapshotTable>[
  SnapshotTable('characters', orderBy: ['id']),
  SnapshotTable('chats', orderBy: ['id']),
  SnapshotTable('messages', orderBy: ['id']),
  SnapshotTable('world_infos', orderBy: ['id']),
  SnapshotTable('world_info_entries', orderBy: ['id']),
  SnapshotTable('llm_configs', orderBy: ['id']),
  SnapshotTable('personas', orderBy: ['id']),
  SnapshotTable('groups', orderBy: ['id']),
  SnapshotTable('bookmarks', orderBy: ['id']),
  SnapshotTable('tags', orderBy: ['id']),
  SnapshotTable('character_tags', orderBy: ['character_id', 'tag_id']),
  SnapshotTable('global_states', orderBy: ['key']),
  SnapshotTable('long_term_memories', orderBy: ['id']),
  SnapshotTable(
    'long_term_memory_source_messages',
    orderBy: ['memory_id', 'ordinal'],
  ),
  SnapshotTable('rpg_scenarios', orderBy: ['id']),
  SnapshotTable('rpg_state_snapshots', orderBy: ['id']),
  SnapshotTable('rpg_chat_states', orderBy: ['chat_id']),
  SnapshotTable('data_bank_documents', orderBy: ['id']),
  SnapshotTable('data_bank_document_versions', orderBy: ['id']),
  SnapshotTable('data_bank_sections', orderBy: ['id']),
  SnapshotTable('data_bank_text_chunks', orderBy: ['id']),
  SnapshotTable('data_bank_bindings', orderBy: ['id']),
  SnapshotTable('story_chapters', orderBy: ['id']),
  SnapshotTable('moment_posts', orderBy: ['id']),
  SnapshotTable('moment_comments', orderBy: ['id']),
];

const legacyV10PreservedSnapshotTables = <SnapshotTable>[
  SnapshotTable(
    'characters',
    orderBy: ['id'],
    columns: [
      'id',
      'name',
      'alternate_greetings',
      'assets_json',
      'character_book_json',
      'extensions_json',
      'tags',
      'is_favorite',
    ],
  ),
  SnapshotTable(
    'chats',
    orderBy: ['id'],
    columns: [
      'id',
      'character_id',
      'settings_json',
      'author_note',
      'author_note_depth',
      'author_note_enabled',
    ],
  ),
  SnapshotTable(
    'messages',
    orderBy: ['id'],
    columns: [
      'id',
      'chat_id',
      'content',
      'swipes',
      'metadata_json',
      'attachments_json',
    ],
  ),
  SnapshotTable(
    'world_infos',
    orderBy: ['id'],
    columns: ['id', 'name', 'character_id'],
  ),
  SnapshotTable(
    'world_info_entries',
    orderBy: ['id'],
    columns: [
      'id',
      'world_info_id',
      'keys',
      'secondary_keys',
      'content',
      'extensions_json',
    ],
  ),
  SnapshotTable(
    'personas',
    orderBy: ['id'],
    columns: ['id', 'name', 'description', 'is_default'],
  ),
  SnapshotTable(
    'groups',
    orderBy: ['id'],
    columns: ['id', 'members_json', 'settings_json'],
  ),
  SnapshotTable(
    'bookmarks',
    orderBy: ['id'],
    columns: ['id', 'chat_id', 'message_id', 'message_index'],
  ),
  SnapshotTable(
    'character_tags',
    orderBy: ['character_id', 'tag_id'],
  ),
];

const legacyV13PreservedSnapshotTables = <SnapshotTable>[
  ...legacyV10PreservedSnapshotTables,
  SnapshotTable(
    'world_infos',
    orderBy: ['id'],
    columns: [
      'id',
      'name',
      'character_id',
      'scan_depth',
      'case_sensitive',
      'match_whole_words',
      'use_group_scoring',
      'recursion_depth',
      'extensions_json',
    ],
  ),
  SnapshotTable(
    'world_info_entries',
    orderBy: ['id'],
    columns: [
      'id',
      'world_info_id',
      'keys',
      'secondary_keys',
      'content',
      'use_group_scoring',
      'automation_id',
      'delay_until_recursion',
      'extensions_json',
    ],
  ),
  SnapshotTable('global_states', orderBy: ['key']),
];

Map<String, Object?> _normalizeRow(Map<String, Object?> row) {
  return row.map((key, value) {
    if (value is Uint8List) {
      return MapEntry(key, List<int>.unmodifiable(value));
    }
    return MapEntry(key, value);
  });
}

String _quoteIdentifier(String identifier) {
  return '"${identifier.replaceAll('"', '""')}"';
}

const _v10SchemaStatements = <String>[
  '''
    CREATE TABLE characters (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      personality TEXT NOT NULL DEFAULT '',
      scenario TEXT NOT NULL DEFAULT '',
      first_message TEXT NOT NULL DEFAULT '',
      alternate_greetings TEXT NOT NULL DEFAULT '[]',
      example_dialogue TEXT NOT NULL DEFAULT '',
      system_prompt TEXT NOT NULL DEFAULT '',
      post_history_instructions TEXT NOT NULL DEFAULT '',
      creator_notes TEXT NOT NULL DEFAULT '',
      tags TEXT NOT NULL DEFAULT '[]',
      creator TEXT NOT NULL DEFAULT '',
      character_version TEXT NOT NULL DEFAULT '',
      avatar_path TEXT,
      assets_json TEXT NOT NULL DEFAULT '{}',
      character_book_json TEXT NOT NULL DEFAULT '',
      extensions_json TEXT NOT NULL DEFAULT '{}',
      is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE chats (
      id TEXT NOT NULL PRIMARY KEY,
      character_id TEXT NOT NULL REFERENCES characters (id),
      group_id TEXT,
      title TEXT NOT NULL DEFAULT 'New Chat',
      settings_json TEXT NOT NULL DEFAULT '{}',
      author_note TEXT NOT NULL DEFAULT '',
      author_note_depth INTEGER NOT NULL DEFAULT 4,
      author_note_enabled INTEGER NOT NULL DEFAULT 0
        CHECK (author_note_enabled IN (0, 1)),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE messages (
      id TEXT NOT NULL PRIMARY KEY,
      chat_id TEXT NOT NULL REFERENCES chats (id),
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      swipes TEXT NOT NULL DEFAULT '[]',
      current_swipe_index INTEGER NOT NULL DEFAULT 0,
      is_edited INTEGER NOT NULL DEFAULT 0 CHECK (is_edited IN (0, 1)),
      is_hidden INTEGER NOT NULL DEFAULT 0 CHECK (is_hidden IN (0, 1)),
      metadata_json TEXT NOT NULL DEFAULT '{}',
      character_id TEXT,
      character_name TEXT,
      attachments_json TEXT NOT NULL DEFAULT '[]'
    )
  ''',
  '''
    CREATE TABLE world_infos (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
      is_global INTEGER NOT NULL DEFAULT 0 CHECK (is_global IN (0, 1)),
      character_id TEXT REFERENCES characters (id),
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE world_info_entries (
      id TEXT NOT NULL PRIMARY KEY,
      world_info_id TEXT NOT NULL REFERENCES world_infos (id),
      keys TEXT NOT NULL DEFAULT '[]',
      secondary_keys TEXT NOT NULL DEFAULT '[]',
      content TEXT NOT NULL DEFAULT '',
      comment TEXT NOT NULL DEFAULT '',
      enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
      constant INTEGER NOT NULL DEFAULT 0 CHECK (constant IN (0, 1)),
      selective INTEGER NOT NULL DEFAULT 0 CHECK (selective IN (0, 1)),
      insertion_order INTEGER NOT NULL DEFAULT 0,
      case_sensitive INTEGER NOT NULL DEFAULT 0 CHECK (case_sensitive IN (0, 1)),
      match_whole_words INTEGER NOT NULL DEFAULT 0
        CHECK (match_whole_words IN (0, 1)),
      probability INTEGER NOT NULL DEFAULT 100,
      position INTEGER NOT NULL DEFAULT 1,
      depth INTEGER NOT NULL DEFAULT 4,
      "group" TEXT,
      group_weight INTEGER NOT NULL DEFAULT 100,
      prevent_recursion INTEGER NOT NULL DEFAULT 0
        CHECK (prevent_recursion IN (0, 1)),
      scan_depth INTEGER NOT NULL DEFAULT 1000,
      extensions_json TEXT NOT NULL DEFAULT '{}'
    )
  ''',
  '''
    CREATE TABLE llm_configs (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      provider TEXT NOT NULL,
      endpoint TEXT NOT NULL,
      api_key TEXT,
      model TEXT,
      enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
      is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
      default_settings_json TEXT NOT NULL DEFAULT '{}',
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE personas (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      avatar_path TEXT,
      is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE groups (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      members_json TEXT NOT NULL DEFAULT '[]',
      settings_json TEXT NOT NULL DEFAULT '{}',
      avatar_path TEXT,
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE bookmarks (
      id TEXT NOT NULL PRIMARY KEY,
      chat_id TEXT NOT NULL REFERENCES chats (id),
      name TEXT NOT NULL,
      description TEXT,
      message_id TEXT NOT NULL,
      message_index INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE tags (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      color TEXT,
      icon TEXT,
      created_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE character_tags (
      character_id TEXT NOT NULL REFERENCES characters (id),
      tag_id TEXT NOT NULL REFERENCES tags (id),
      PRIMARY KEY (character_id, tag_id)
    )
  ''',
];

const _v13SchemaStatements = <String>[
  ..._v10SchemaStatements,
  'ALTER TABLE world_info_entries '
      'ADD COLUMN use_group_scoring INTEGER NOT NULL DEFAULT 0 '
      'CHECK (use_group_scoring IN (0, 1))',
  "ALTER TABLE world_info_entries ADD COLUMN automation_id TEXT NOT NULL DEFAULT ''",
  'ALTER TABLE world_info_entries '
      'ADD COLUMN delay_until_recursion INTEGER NOT NULL DEFAULT 0 '
      'CHECK (delay_until_recursion IN (0, 1))',
  'ALTER TABLE world_infos ADD COLUMN scan_depth TEXT',
  'ALTER TABLE world_infos ADD COLUMN case_sensitive INTEGER '
      'CHECK (case_sensitive IN (0, 1))',
  'ALTER TABLE world_infos ADD COLUMN match_whole_words INTEGER '
      'CHECK (match_whole_words IN (0, 1))',
  'ALTER TABLE world_infos ADD COLUMN use_group_scoring INTEGER '
      'CHECK (use_group_scoring IN (0, 1))',
  'ALTER TABLE world_infos ADD COLUMN recursion_depth INTEGER',
  "ALTER TABLE world_infos ADD COLUMN extensions_json TEXT NOT NULL DEFAULT '{}'",
  '''
    CREATE TABLE global_states (
      key TEXT NOT NULL PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''',
];

const _v14SchemaStatements = <String>[
  ..._v13SchemaStatements,
  "ALTER TABLE personas ADD COLUMN connections_json TEXT NOT NULL DEFAULT '[]'",
  "ALTER TABLE personas ADD COLUMN description_settings_json TEXT NOT NULL DEFAULT '{}'",
  'ALTER TABLE personas ADD COLUMN lorebook_id TEXT',
  'ALTER TABLE personas ADD COLUMN system_prompt_override TEXT',
  'ALTER TABLE personas ADD COLUMN post_history_instructions TEXT',
  "ALTER TABLE personas ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]'",
  "ALTER TABLE personas ADD COLUMN creator_notes TEXT NOT NULL DEFAULT ''",
  'ALTER TABLE personas ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0 '
      'CHECK (is_favorite IN (0, 1))',
];

const _representativeLegacySeedStatements = <String>[
  '''
    INSERT INTO characters (
      id, name, description, personality, scenario, first_message,
      alternate_greetings, example_dialogue, system_prompt,
      post_history_instructions, creator_notes, tags, creator,
      character_version, avatar_path, assets_json, character_book_json,
      extensions_json, is_favorite, created_at, modified_at
    ) VALUES (
      'character-1', 'Legacy Hero', 'Preserved description', 'Steady',
      'A migration test', 'Hello {{user}}', '["Welcome","Greetings"]',
      '<START>\n{{char}}: Example', 'Stay in character', 'Remember the quest',
      'Imported from v10', '["legacy","favorite"]', 'Fixture Author', '1.0',
      '/tmp/avatar.png', '{"sprites":["smile.png"]}',
      '{"entries":[{"keys":["lore"],"content":"Stored lore"}]}',
      '{"talkativeness":"0.75"}', 1, 1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO chats (
      id, character_id, title, settings_json, author_note, author_note_depth,
      author_note_enabled, created_at, updated_at
    ) VALUES (
      'chat-1', 'character-1', 'Legacy chat',
      '{"startReplyWith":"Once ","nested":{"enabled":true}}',
      'Keep this note', 3, 1, 1704240000, 1704326400
    )
  ''',
  '''
    INSERT INTO messages (
      id, chat_id, role, content, timestamp, swipes, current_swipe_index,
      is_edited, is_hidden, metadata_json, attachments_json
    ) VALUES (
      'message-1', 'chat-1', 'assistant', 'Hello traveler', 1704240100,
      '["Hello traveler","Welcome back"]', 1, 1, 0,
      '{"reasoning":"fixture"}',
      '[{"id":"attachment-1","path":"/tmp/map.png","mimeType":"image/png"}]'
    )
  ''',
  '''
    INSERT INTO world_infos (
      id, name, description, enabled, is_global, character_id,
      created_at, modified_at
    ) VALUES (
      'world-1', 'Legacy lore', 'World description', 1, 0, 'character-1',
      1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO world_info_entries (
      id, world_info_id, keys, secondary_keys, content, comment, enabled,
      constant, selective, insertion_order, case_sensitive, match_whole_words,
      probability, position, depth, "group", group_weight, prevent_recursion,
      scan_depth, extensions_json
    ) VALUES (
      'entry-1', 'world-1', '["castle","keep"]', '["north"]',
      'The castle is guarded.', 'Legacy entry', 1, 0, 1, 7, 1, 0,
      80, 1, 4, 'places', 75, 0, 512, '{"displayIndex":3}'
    )
  ''',
  '''
    INSERT INTO llm_configs (
      id, name, provider, endpoint, api_key, model, enabled, is_default,
      default_settings_json, created_at, modified_at
    ) VALUES (
      'llm-1', 'Fixture config', 'openai', 'https://example.invalid/v1',
      NULL, 'fixture-model', 1, 1,
      '{"temperature":0.7,"stop":["END"]}', 1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO personas (
      id, name, description, is_default, created_at, updated_at
    ) VALUES (
      'persona-1', 'Legacy User', 'Persona description', 1,
      1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO groups (
      id, name, description, members_json, settings_json,
      created_at, modified_at
    ) VALUES (
      'group-1', 'Fixture party', 'Group description',
      '[{"characterId":"character-1","isMuted":false}]',
      '{"activationMode":"manual","generationMode":"swap"}',
      1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO bookmarks (
      id, chat_id, name, description, message_id, message_index, created_at
    ) VALUES (
      'bookmark-1', 'chat-1', 'Checkpoint', 'Before migration',
      'message-1', 0, 1704240200
    )
  ''',
  '''
    INSERT INTO tags (id, name, color, icon, created_at)
    VALUES ('tag-1', 'Legacy', '#336699', 'history', 1704067200)
  ''',
  '''
    INSERT INTO character_tags (character_id, tag_id)
    VALUES ('character-1', 'tag-1')
  ''',
];

const _v13SeedStatements = <String>[
  '''
    UPDATE world_infos SET
      scan_depth = '321',
      case_sensitive = 1,
      match_whole_words = 0,
      use_group_scoring = 1,
      recursion_depth = 2,
      extensions_json = '{"strategy":"v13"}'
    WHERE id = 'world-1'
  ''',
  '''
    UPDATE world_info_entries SET
      use_group_scoring = 1,
      automation_id = 'automation-1',
      delay_until_recursion = 1
    WHERE id = 'entry-1'
  ''',
  '''
    INSERT INTO global_states (key, value, updated_at)
    VALUES ('active_config', '{"provider":"llm-1"}', 1704326400)
  ''',
];

const _v14SeedStatements = <String>[
  ..._v13SeedStatements,
  '''
    UPDATE personas SET
      connections_json = '[{"characterId":"character-1","lockType":"character"}]',
      description_settings_json = '{"position":"atDepth","depth":3,"role":"user"}',
      lorebook_id = 'world-1',
      system_prompt_override = 'Persona system prompt',
      post_history_instructions = 'Persona post-history prompt',
      tags_json = '["fixture","migration"]',
      creator_notes = 'Private fixture note',
      is_favorite = 1
    WHERE id = 'persona-1'
  ''',
];

const _currentOnlySeedStatements = <String>[
  ..._v14SeedStatements,
  '''
    INSERT INTO long_term_memories (
      id, kind, scope_kind, character_id, persona_id, state, content,
      source_origin, source_chat_id, extracted_at, provider_id, model_id,
      importance, confidence, created_at, updated_at, locked,
      normalized_identity_key
    ) VALUES (
      'memory-1', 'event', 'characterPersona', 'character-1', 'persona-1',
      'active', 'A representative persisted memory.', 'generated', 'chat-1',
      1704240100, 'provider-1', 'model-1', 0.8, 0.9, 1704240200,
      1704240200, 0, 'event:representative'
    )
  ''',
  '''
    INSERT INTO long_term_memory_source_messages (memory_id, message_id, ordinal)
    VALUES ('memory-1', 'message-1', 0)
  ''',
  '''
    INSERT INTO rpg_scenarios (
      id, version, contract_schema_version, scenario_json, created_at, updated_at
    ) VALUES (
      'scenario-1', '1.0.0', 1,
      '{"schemaVersion":1,"metadata":{"id":"scenario-1","name":"Fixture","version":"1.0.0"},"initialSeed":7,"initialState":{"scenarioId":"scenario-1","scenarioVersion":"1.0.0","turn":1,"random":{"initialSeed":7,"state":11,"rollsConsumed":0}}}',
      1704240200, 1704240200
    )
  ''',
  '''
    INSERT INTO rpg_state_snapshots (
      id, scenario_id, scenario_version, branch_id, turn, random_state,
      rolls_consumed, created_at, snapshot_json
    ) VALUES (
      'snapshot-1', 'scenario-1', '1.0.0', 'main', 1, 11, 0, 1704240300,
      '{"metadata":{"id":"snapshot-1","scenarioId":"scenario-1","scenarioVersion":"1.0.0","branchId":"main","turn":1,"randomState":11,"rollsConsumed":0,"createdAt":"2024-01-03T00:05:00.000Z"},"state":{"scenarioId":"scenario-1","scenarioVersion":"1.0.0","turn":1,"random":{"initialSeed":7,"state":11,"rollsConsumed":0}}}'
    )
  ''',
  '''
    INSERT INTO rpg_chat_states (
      chat_id, scenario_id, current_snapshot_id, turn, state_json, updated_at
    ) VALUES (
      'chat-1', 'scenario-1', 'snapshot-1', 1,
      '{"scenarioId":"scenario-1","scenarioVersion":"1.0.0","turn":1,"random":{"initialSeed":7,"state":11,"rollsConsumed":0}}',
      1704240300
    )
  ''',
  '''
    INSERT INTO data_bank_documents (
      id, current_version_id, processing_state, index_state, failure_json,
      reprocessing_json, created_at, updated_at, is_placeholder
    ) VALUES (
      'document-1', NULL, 'ready', 'indexed', NULL,
      '{"attemptCount":0}', 1704240400, 1704240400, 1
    )
  ''',
  '''
    INSERT INTO data_bank_document_versions (
      id, document_id, version_number, original_file_name, media_type,
      byte_size, hash_algorithm, hash_digest, imported_at, processing_state,
      index_state, reprocessing_json
    ) VALUES (
      'version-1', 'document-1', 1, 'fixture.md', 'text/markdown', 42,
      'sha256', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      1704240400, 'ready', 'indexed', '{"attemptCount":0}'
    )
  ''',
  '''
    UPDATE data_bank_documents
    SET current_version_id = 'version-1', is_placeholder = 0
    WHERE id = 'document-1'
  ''',
  '''
    INSERT INTO data_bank_sections (
      id, document_version_id, kind, title, ordinal, locator_json
    ) VALUES (
      'section-1', 'version-1', 'chapter', 'Fixture', 0,
      '{"documentVersionId":"version-1","sectionId":"section-1","chapter":"Fixture"}'
    )
  ''',
  '''
    INSERT INTO data_bank_text_chunks (
      id, document_version_id, section_id, ordinal, text_content, locator_json
    ) VALUES (
      'chunk-1', 'version-1', 'section-1', 0, 'Fixture source text.',
      '{"documentVersionId":"version-1","sectionId":"section-1","chapter":"Fixture"}'
    )
  ''',
  '''
    INSERT INTO data_bank_bindings (
      id, document_id, scope, character_id, enabled, created_at, updated_at
    ) VALUES (
      'binding-1', 'document-1', 'character', 'character-1', 1,
      1704240400, 1704240400
    )
  ''',
  '''
    INSERT INTO story_chapters (
      id, chat_id, title, summary, start_message_id, end_message_id,
      start_ordinal, end_ordinal, origin, created_at, updated_at
    ) VALUES (
      'chapter-1', 'chat-1', 'Fixture chapter',
      'A representative persisted chapter.', 'message-1', 'message-1',
      0, 0, 'auto', 1704240500, 1704240500
    )
  ''',
  '''
    INSERT INTO moment_posts (
      id, chat_id, author_id, author_name, public_body, image_path, fact_body,
      chapter_id, origin, status, write_to_world, created_at, updated_at
    ) VALUES (
      'moment-1', 'chat-1', 'character-1', 'Fixture',
      'Nothing worth mentioning.', NULL, 'A representative persisted chapter.',
      'chapter-1', 'chapter', 'open', 0, 1704240600, 1704240600
    )
  ''',
];

import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/data/database/database.dart' hide Persona;
import 'package:native_tavern/data/models/persona.dart';
import 'package:native_tavern/core/services/initialization_service.dart';

/// Repository for managing personas
class PersonaRepository {
  final AppDatabase _db;

  PersonaRepository(this._db);

  /// Get all personas
  Future<List<Persona>> getAllPersonas() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM personas ORDER BY is_default DESC, name ASC',
        )
        .get();

    return rows.map((row) => _rowToPersona(row.data)).toList();
  }

  /// Get a persona by ID
  Future<Persona?> getPersona(String id) async {
    final rows = await _db.customSelect(
      'SELECT * FROM personas WHERE id = ?',
      variables: [Variable.withString(id)],
    ).get();

    if (rows.isEmpty) return null;
    return _rowToPersona(rows.first.data);
  }

  /// Get the default persona
  Future<Persona?> getDefaultPersona() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM personas WHERE is_default = 1 LIMIT 1',
        )
        .get();

    if (rows.isEmpty) return null;
    return _rowToPersona(rows.first.data);
  }

  /// Create a new persona
  Future<void> createPersona(Persona persona) async {
    await _db.customInsert(
      '''
      INSERT INTO personas (
        id, name, description, avatar_path, is_default,
        connections_json, description_settings_json, lorebook_id,
        system_prompt_override, post_history_instructions, tags_json,
        creator_notes, is_favorite, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable.withString(persona.id),
        Variable.withString(persona.name),
        Variable.withString(persona.description),
        persona.avatarPath != null
            ? Variable.withString(persona.avatarPath!)
            : const Variable(null),
        Variable.withBool(persona.isDefault),
        Variable.withString(jsonEncode(
          persona.connections.map((connection) => connection.toJson()).toList(),
        )),
        Variable.withString(jsonEncode(persona.descriptionSettings.toJson())),
        persona.lorebookId != null
            ? Variable.withString(persona.lorebookId!)
            : const Variable(null),
        persona.systemPromptOverride != null
            ? Variable.withString(persona.systemPromptOverride!)
            : const Variable(null),
        persona.postHistoryInstructions != null
            ? Variable.withString(persona.postHistoryInstructions!)
            : const Variable(null),
        Variable.withString(jsonEncode(persona.tags)),
        Variable.withString(persona.creatorNotes),
        Variable.withBool(persona.isFavorite),
        Variable.withDateTime(persona.createdAt),
        Variable.withDateTime(persona.updatedAt),
      ],
    );
  }

  /// Update a persona
  Future<void> updatePersona(Persona persona) async {
    await _db.customUpdate(
      '''
      UPDATE personas
      SET name = ?, description = ?, avatar_path = ?, is_default = ?,
          connections_json = ?, description_settings_json = ?, lorebook_id = ?,
          system_prompt_override = ?, post_history_instructions = ?, tags_json = ?,
          creator_notes = ?, is_favorite = ?, updated_at = ?
      WHERE id = ?
      ''',
      variables: [
        Variable.withString(persona.name),
        Variable.withString(persona.description),
        persona.avatarPath != null
            ? Variable.withString(persona.avatarPath!)
            : const Variable(null),
        Variable.withBool(persona.isDefault),
        Variable.withString(jsonEncode(
          persona.connections.map((connection) => connection.toJson()).toList(),
        )),
        Variable.withString(jsonEncode(persona.descriptionSettings.toJson())),
        persona.lorebookId != null
            ? Variable.withString(persona.lorebookId!)
            : const Variable(null),
        persona.systemPromptOverride != null
            ? Variable.withString(persona.systemPromptOverride!)
            : const Variable(null),
        persona.postHistoryInstructions != null
            ? Variable.withString(persona.postHistoryInstructions!)
            : const Variable(null),
        Variable.withString(jsonEncode(persona.tags)),
        Variable.withString(persona.creatorNotes),
        Variable.withBool(persona.isFavorite),
        Variable.withDateTime(persona.updatedAt),
        Variable.withString(persona.id),
      ],
      updates: {},
    );
  }

  /// Delete a persona
  Future<void> deletePersona(String id) async {
    await _db.customStatement(
      'DELETE FROM personas WHERE id = ?',
      [id],
    );
  }

  /// Set a persona as default (and unset others)
  Future<void> setDefaultPersona(String id) async {
    await _db.transaction(() async {
      // Unset all defaults
      await _db.customUpdate(
        'UPDATE personas SET is_default = 0',
        updates: {},
      );
      // Set the new default
      await _db.customUpdate(
        'UPDATE personas SET is_default = 1 WHERE id = ?',
        variables: [Variable.withString(id)],
        updates: {},
      );
    });
  }

  /// Ensure default persona exists
  Future<void> ensureDefaultPersonaExists() async {
    final defaultPersona = await getDefaultPersona();
    if (defaultPersona == null) {
      await createPersona(createDefaultPersona());
    }
  }

  Persona _rowToPersona(Map<String, dynamic> row) {
    return Persona(
      id: row['id'] as String,
      name: row['name'] as String,
      description: row['description'] as String? ?? '',
      avatarPath: row['avatar_path'] as String?,
      isDefault: (row['is_default'] as int) == 1,
      connections: _parseJsonList(row['connections_json'])
          .whereType<Map<String, dynamic>>()
          .map(PersonaConnection.fromJson)
          .toList(),
      descriptionSettings: _parseDescriptionSettings(
        row['description_settings_json'],
      ),
      lorebookId: row['lorebook_id'] as String?,
      systemPromptOverride: row['system_prompt_override'] as String?,
      postHistoryInstructions: row['post_history_instructions'] as String?,
      tags: _parseJsonList(row['tags_json']).map((value) => '$value').toList(),
      creatorNotes: row['creator_notes'] as String? ?? '',
      isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
      createdAt: _parseDateTime(row['created_at']),
      updatedAt: _parseDateTime(row['updated_at']),
    );
  }

  List<dynamic> _parseJsonList(dynamic value) {
    if (value is! String || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      return decoded is List<dynamic> ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }

  PersonaDescriptionSettings _parseDescriptionSettings(dynamic value) {
    if (value is! String || value.isEmpty) {
      return const PersonaDescriptionSettings();
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return PersonaDescriptionSettings.fromJson(decoded);
      }
    } catch (_) {
      // Fall back to defaults for malformed legacy data.
    }
    return const PersonaDescriptionSettings();
  }

  /// Parse DateTime from database value (can be int or String)
  DateTime _parseDateTime(dynamic value) {
    if (value is int) {
      // Unix timestamp in seconds
      return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    } else if (value is String) {
      return DateTime.parse(value);
    } else {
      return DateTime.now();
    }
  }
}

/// Provider for persona repository
final personaRepositoryProvider = Provider<PersonaRepository>((ref) {
  final db = ref.watch(databaseProvider);
  return PersonaRepository(db);
});

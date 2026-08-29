import 'package:drift/drift.dart';
import 'package:native_tavern/data/database/database.dart';

/// Adds schema-v15 domain tables to the existing logical backup format.
final class DatabaseBackupV15Adapter {
  const DatabaseBackupV15Adapter(this._database);

  final AppDatabase _database;

  Future<Map<String, dynamic>> exportData() async {
    final documents = await (_database.select(_database.dataBankDocuments)
          ..where((table) => table.isPlaceholder.equals(false)))
        .get();
    final documentIds = documents.map((row) => row.id);
    final versions = await (_database.select(
      _database.dataBankDocumentVersions,
    )..where((table) => table.documentId.isIn(documentIds)))
        .get();
    final versionIds = versions.map((row) => row.id);
    final sections = await (_database.select(_database.dataBankSections)
          ..where((table) => table.documentVersionId.isIn(versionIds)))
        .get();
    final chunks = await (_database.select(_database.dataBankTextChunks)
          ..where((table) => table.documentVersionId.isIn(versionIds)))
        .get();
    final bindings = await (_database.select(_database.dataBankBindings)
          ..where((table) => table.documentId.isIn(documentIds)))
        .get();
    return {
      'longTermMemories': _mapById(
        (await _database.select(_database.longTermMemories).get())
            .map((row) => row.toJson()),
      ),
      'longTermMemorySourceMessages':
          (await _database.select(_database.longTermMemorySourceMessages).get())
              .map((row) => row.toJson())
              .toList(),
      'rpgScenarios': _mapById(
        (await _database.select(_database.rpgScenarios).get())
            .map((row) => row.toJson()),
      ),
      'rpgStateSnapshots': _mapById(
        (await _database.select(_database.rpgStateSnapshots).get())
            .map((row) => row.toJson()),
      ),
      'rpgChatStates': _mapByKey(
        (await _database.select(_database.rpgChatStates).get())
            .map((row) => row.toJson()),
        'chatId',
      ),
      'dataBankDocuments': _mapById(
        documents.map((row) => row.toJson()),
      ),
      'dataBankDocumentVersions': _mapById(
        versions.map((row) => row.toJson()),
      ),
      'dataBankSections': _mapById(
        sections.map((row) => row.toJson()),
      ),
      'dataBankTextChunks': _mapById(
        chunks.map((row) => row.toJson()),
      ),
      'dataBankBindings': _mapById(
        bindings.map((row) => row.toJson()),
      ),
      'storyChapters': _mapById(
        (await _database.select(_database.storyChapters).get())
            .map((row) => row.toJson()),
      ),
      'momentPosts': _mapById(
        (await _database.select(_database.momentPosts).get())
            .map((row) => row.toJson()),
      ),
      'momentComments': _mapById(
        (await _database.select(_database.momentComments).get())
            .map((row) => row.toJson()),
      ),
      'momentPostLikes':
          (await _database.select(_database.momentPostLikes).get())
              .map((row) => row.toJson())
              .toList(),
    };
  }

  Future<void> importData(
    Map<String, dynamic> data, {
    required bool overwriteExisting,
  }) async {
    await _database.transaction(() async {
      for (final json in _rows(data, 'longTermMemories')) {
        await _insert(
          _database.longTermMemories,
          LongTermMemoryRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'longTermMemorySourceMessages')) {
        await _insert(
          _database.longTermMemorySourceMessages,
          LongTermMemorySourceMessageRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'rpgScenarios')) {
        await _insert(
          _database.rpgScenarios,
          RpgScenarioRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'rpgStateSnapshots')) {
        await _insert(
          _database.rpgStateSnapshots,
          RpgStateSnapshotRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'rpgChatStates')) {
        await _insert(
          _database.rpgChatStates,
          RpgChatStateRow.fromJson(json),
          overwriteExisting,
        );
      }

      final documentsToRestore = <String>{};
      final documentRows = _rows(data, 'dataBankDocuments')
          .map(DataBankDocumentRow.fromJson)
          .toList();
      for (final row in documentRows) {
        final existing = await (_database.select(_database.dataBankDocuments)
              ..where((table) => table.id.equals(row.id)))
            .getSingleOrNull();
        if (existing == null) {
          await _database.into(_database.dataBankDocuments).insert(
                DataBankDocumentsCompanion(
                  id: Value(row.id),
                  currentVersionId: const Value(null),
                  processingState: Value(row.processingState),
                  indexState: Value(row.indexState),
                  failureJson: Value(row.failureJson),
                  reprocessingJson: Value(row.reprocessingJson),
                  createdAt: Value(row.createdAt),
                  updatedAt: Value(row.updatedAt),
                  isPlaceholder: const Value(true),
                ),
              );
          documentsToRestore.add(row.id);
        } else if (overwriteExisting) {
          documentsToRestore.add(row.id);
        }
      }

      for (final json in _rows(data, 'dataBankDocumentVersions')) {
        await _insert(
          _database.dataBankDocumentVersions,
          DataBankDocumentVersionRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'dataBankSections')) {
        await _insert(
          _database.dataBankSections,
          DataBankSectionRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'dataBankTextChunks')) {
        await _insert(
          _database.dataBankTextChunks,
          DataBankTextChunkRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'dataBankBindings')) {
        await _insert(
          _database.dataBankBindings,
          DataBankBindingRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'storyChapters')) {
        await _insert(
          _database.storyChapters,
          StoryChapterRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'momentPosts')) {
        await _insert(
          _database.momentPosts,
          MomentPostRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'momentComments')) {
        await _insert(
          _database.momentComments,
          MomentCommentRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final json in _rows(data, 'momentPostLikes')) {
        await _insert(
          _database.momentPostLikes,
          MomentPostLikeRow.fromJson(json),
          overwriteExisting,
        );
      }
      for (final row in documentRows) {
        if (documentsToRestore.contains(row.id)) {
          await _database
              .into(_database.dataBankDocuments)
              .insertOnConflictUpdate(row);
        }
      }
    });
  }

  Future<void> _insert<T extends Table, D extends DataClass>(
    TableInfo<T, D> table,
    Insertable<D> row,
    bool overwriteExisting,
  ) async {
    if (overwriteExisting) {
      await _database.into(table).insertOnConflictUpdate(row);
    } else {
      await _database.into(table).insert(
            row,
            mode: InsertMode.insertOrIgnore,
          );
    }
  }
}

Map<String, dynamic> _mapById(Iterable<Map<String, dynamic>> rows) {
  return _mapByKey(rows, 'id');
}

Map<String, dynamic> _mapByKey(
  Iterable<Map<String, dynamic>> rows,
  String key,
) {
  return {
    for (final row in rows) row[key].toString(): row,
  };
}

Iterable<Map<String, dynamic>> _rows(
  Map<String, dynamic> data,
  String key,
) sync* {
  final value = data[key];
  final values = switch (value) {
    Map<dynamic, dynamic>() => value.values,
    List<dynamic>() => value,
    _ => const <dynamic>[],
  };
  for (final row in values) {
    if (row is Map<dynamic, dynamic>) {
      yield Map<String, dynamic>.from(row);
    }
  }
}

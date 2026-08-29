import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/domain/repositories/rpg_persistence_repository.dart';

class DriftRpgPersistenceRepository implements RpgPersistenceRepository {
  const DriftRpgPersistenceRepository(this._database);

  final AppDatabase _database;

  @override
  Future<RpgScenario?> getScenario(String scenarioId) async {
    final row = await (_database.select(_database.rpgScenarios)
          ..where((table) => table.id.equals(scenarioId)))
        .getSingleOrNull();
    return row == null ? null : _scenarioFromJson(row.scenarioJson);
  }

  @override
  Future<List<RpgScenario>> listScenarios() async {
    final rows = await (_database.select(_database.rpgScenarios)
          ..orderBy([(table) => OrderingTerm.asc(table.id)]))
        .get();
    return rows.map((row) => _scenarioFromJson(row.scenarioJson)).toList();
  }

  @override
  Future<void> saveScenario(RpgScenario scenario) async {
    const RpgScenarioValidator().validate(scenario).throwIfInvalid();
    final encoded = jsonEncode(scenario.toJson());
    await _database.transaction(() async {
      final existing = await (_database.select(_database.rpgScenarios)
            ..where((table) => table.id.equals(scenario.metadata.id)))
          .getSingleOrNull();
      if (existing != null && existing.scenarioJson != encoded) {
        final snapshot = await (_database.select(_database.rpgStateSnapshots)
              ..where(
                (table) => table.scenarioId.equals(scenario.metadata.id),
              )
              ..limit(1))
            .getSingleOrNull();
        final chatState = await (_database.select(_database.rpgChatStates)
              ..where(
                (table) => table.scenarioId.equals(scenario.metadata.id),
              )
              ..limit(1))
            .getSingleOrNull();
        if (snapshot != null || chatState != null) {
          throw StateError(
            'Cannot replace an RPG scenario with persisted sessions.',
          );
        }
      }
      final now = DateTime.now().toUtc();
      await _database.into(_database.rpgScenarios).insertOnConflictUpdate(
            RpgScenariosCompanion.insert(
              id: scenario.metadata.id,
              version: scenario.metadata.version,
              contractSchemaVersion: scenario.schemaVersion,
              scenarioJson: encoded,
              createdAt: existing?.createdAt ?? now,
              updatedAt: now,
            ),
          );
    });
  }

  @override
  Future<void> deleteScenario(String scenarioId) async {
    await (_database.delete(_database.rpgScenarios)
          ..where((table) => table.id.equals(scenarioId)))
        .go();
  }

  @override
  Future<RpgRuntimeState?> getCurrentState(String chatId) async {
    final row = await (_database.select(_database.rpgChatStates)
          ..where((table) => table.chatId.equals(chatId)))
        .getSingleOrNull();
    if (row == null) return null;
    return RpgRuntimeState.fromJson(
      jsonDecode(row.stateJson) as Map<String, dynamic>,
    );
  }

  @override
  Future<String?> getCurrentSnapshotId(String chatId) async {
    final row = await (_database.select(_database.rpgChatStates)
          ..where((table) => table.chatId.equals(chatId)))
        .getSingleOrNull();
    return row?.currentSnapshotId;
  }

  @override
  Future<void> saveCurrentState({
    required String chatId,
    required String scenarioId,
    required RpgRuntimeState state,
    String? currentSnapshotId,
    String? expectedCurrentSnapshotId,
    required DateTime updatedAt,
  }) =>
      _database.transaction(
        () => _saveCurrentStateValidated(
          chatId: chatId,
          scenarioId: scenarioId,
          state: state,
          currentSnapshotId: currentSnapshotId,
          expectedCurrentSnapshotId: expectedCurrentSnapshotId,
          updatedAt: updatedAt,
        ),
      );

  Future<void> _saveCurrentStateValidated({
    required String chatId,
    required String scenarioId,
    required RpgRuntimeState state,
    required String? currentSnapshotId,
    required String? expectedCurrentSnapshotId,
    required DateTime updatedAt,
  }) async {
    if (state.scenarioId != scenarioId) {
      throw ArgumentError('Runtime state must belong to $scenarioId.');
    }
    final scenario = await _requireScenario(scenarioId);
    if (state.scenarioVersion != scenario.metadata.version) {
      throw ArgumentError('Runtime state scenario version is not current.');
    }
    const RpgScenarioValidator()
        .validateRuntimeState(scenario, state)
        .throwIfInvalid();
    if (currentSnapshotId != null) {
      final snapshot = await _requireSnapshot(currentSnapshotId);
      if (snapshot.metadata.scenarioId != scenarioId ||
          snapshot.metadata.scenarioVersion != state.scenarioVersion) {
        throw ArgumentError('Current snapshot belongs to another scenario.');
      }
      if (!const DeepCollectionEquality().equals(
        snapshot.state.toJson(),
        state.toJson(),
      )) {
        throw ArgumentError('Current state must match its current snapshot.');
      }
    }
    if (expectedCurrentSnapshotId != null) {
      await _requireCurrentSnapshot(
        chatId,
        expectedCurrentSnapshotId,
      );
    }

    await _writeCurrentState(
      chatId: chatId,
      scenarioId: scenarioId,
      state: state,
      currentSnapshotId: currentSnapshotId,
      updatedAt: updatedAt,
    );
  }

  @override
  Future<RpgStateSnapshot?> getSnapshot(String snapshotId) async {
    final row = await (_database.select(_database.rpgStateSnapshots)
          ..where((table) => table.id.equals(snapshotId)))
        .getSingleOrNull();
    return row == null ? null : _snapshotFromJson(row.snapshotJson);
  }

  @override
  Future<List<RpgStateSnapshot>> listSnapshots({
    required String scenarioId,
    String? branchId,
  }) async {
    final query = _database.select(_database.rpgStateSnapshots)
      ..where((table) => table.scenarioId.equals(scenarioId));
    if (branchId != null) {
      query.where((table) => table.branchId.equals(branchId));
    }
    query.orderBy([
      (table) => OrderingTerm.asc(table.turn),
      (table) => OrderingTerm.asc(table.createdAt),
      (table) => OrderingTerm.asc(table.id),
    ]);
    final rows = await query.get();
    return rows.map((row) => _snapshotFromJson(row.snapshotJson)).toList();
  }

  @override
  Future<void> saveSnapshot(RpgStateSnapshot snapshot) =>
      _database.transaction(() async {
        await _validateSnapshotForInsert(snapshot);
        await _writeSnapshot(snapshot);
      });

  @override
  Future<void> commitSnapshotAndCurrentState({
    required String chatId,
    required RpgStateSnapshot snapshot,
    required String? expectedCurrentSnapshotId,
    required DateTime updatedAt,
  }) async {
    await _database.transaction(() async {
      final current = await (_database.select(_database.rpgChatStates)
            ..where((table) => table.chatId.equals(chatId)))
          .getSingleOrNull();
      if (expectedCurrentSnapshotId == null) {
        if (current != null) {
          throw StateError('RPG session for chat $chatId already exists.');
        }
      } else if (current?.currentSnapshotId != expectedCurrentSnapshotId) {
        throw StateError(
          'RPG session for chat $chatId changed before commit.',
        );
      }
      await _validateSnapshotForInsert(snapshot);
      await _writeSnapshot(snapshot);
      await _writeCurrentState(
        chatId: chatId,
        scenarioId: snapshot.metadata.scenarioId,
        state: snapshot.state,
        currentSnapshotId: snapshot.metadata.id,
        updatedAt: updatedAt,
      );
    });
  }

  Future<void> _validateSnapshotForInsert(RpgStateSnapshot snapshot) async {
    final metadata = snapshot.metadata;
    final scenario = await _requireScenario(metadata.scenarioId);
    if (metadata.scenarioVersion != scenario.metadata.version ||
        snapshot.state.scenarioVersion != metadata.scenarioVersion ||
        snapshot.state.scenarioId != metadata.scenarioId) {
      throw ArgumentError('Snapshot scenario ownership is inconsistent.');
    }
    const RpgScenarioValidator()
        .validateSnapshot(scenario, snapshot)
        .throwIfInvalid();
    const RpgScenarioValidator()
        .validateRuntimeState(scenario, snapshot.state)
        .throwIfInvalid();

    final existing = await getSnapshot(metadata.id);
    if (existing != null) {
      throw StateError('RPG snapshot ${metadata.id} already exists.');
    }

    if (metadata.parentSnapshotId != null) {
      final parent = await _requireSnapshot(metadata.parentSnapshotId!);
      if (parent.metadata.scenarioId != metadata.scenarioId ||
          parent.metadata.scenarioVersion != metadata.scenarioVersion ||
          parent.metadata.turn > metadata.turn) {
        throw ArgumentError('Snapshot parent lineage is invalid.');
      }
      if (parent.metadata.branchId != metadata.branchId) {
        final existingBranch = await listSnapshots(
          scenarioId: metadata.scenarioId,
          branchId: metadata.branchId,
        );
        if (existingBranch.isNotEmpty ||
            parent.metadata.turn != metadata.turn) {
          throw ArgumentError(
            'A cross-branch parent is only valid for a new branch root.',
          );
        }
      }
    } else {
      final existingBranch = await listSnapshots(
        scenarioId: metadata.scenarioId,
        branchId: metadata.branchId,
      );
      if (existingBranch.isNotEmpty) {
        throw ArgumentError('Snapshot branch already has a root.');
      }
    }
  }

  Future<void> _writeSnapshot(RpgStateSnapshot snapshot) async {
    final metadata = snapshot.metadata;
    await _database.into(_database.rpgStateSnapshots).insert(
          RpgStateSnapshotsCompanion.insert(
            id: metadata.id,
            scenarioId: metadata.scenarioId,
            scenarioVersion: metadata.scenarioVersion,
            branchId: metadata.branchId,
            parentSnapshotId: Value(metadata.parentSnapshotId),
            turn: metadata.turn,
            randomState: metadata.randomState,
            rollsConsumed: metadata.rollsConsumed,
            createdAt: metadata.createdAt,
            stateHash: Value(metadata.stateHash),
            snapshotJson: jsonEncode(snapshot.toJson()),
          ),
        );
  }

  Future<void> _writeCurrentState({
    required String chatId,
    required String scenarioId,
    required RpgRuntimeState state,
    required String? currentSnapshotId,
    required DateTime updatedAt,
  }) async {
    await _database.into(_database.rpgChatStates).insertOnConflictUpdate(
          RpgChatStatesCompanion.insert(
            chatId: chatId,
            scenarioId: scenarioId,
            currentSnapshotId: Value(currentSnapshotId),
            turn: state.turn,
            stateJson: jsonEncode(state.toJson()),
            updatedAt: updatedAt,
          ),
        );
  }

  Future<RpgScenario> _requireScenario(String scenarioId) async {
    final scenario = await getScenario(scenarioId);
    if (scenario == null) {
      throw StateError('RPG scenario $scenarioId does not exist.');
    }
    return scenario;
  }

  Future<RpgStateSnapshot> _requireSnapshot(String snapshotId) async {
    final snapshot = await getSnapshot(snapshotId);
    if (snapshot == null) {
      throw StateError('RPG snapshot $snapshotId does not exist.');
    }
    return snapshot;
  }

  Future<void> _requireCurrentSnapshot(
    String chatId,
    String expectedSnapshotId,
  ) async {
    final current = await (_database.select(_database.rpgChatStates)
          ..where((table) => table.chatId.equals(chatId)))
        .getSingleOrNull();
    if (current?.currentSnapshotId != expectedSnapshotId) {
      throw StateError('RPG session for chat $chatId changed before update.');
    }
  }
}

RpgScenario _scenarioFromJson(String encoded) {
  return RpgScenario.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
}

RpgStateSnapshot _snapshotFromJson(String encoded) {
  return RpgStateSnapshot.fromJson(
    jsonDecode(encoded) as Map<String, dynamic>,
  );
}

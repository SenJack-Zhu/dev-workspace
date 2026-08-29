import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/domain/repositories/rpg_persistence_repository.dart';
import 'package:native_tavern/domain/services/rpg_rule_engine.dart';
import 'package:uuid/uuid.dart';

class RpgGameSession {
  const RpgGameSession({
    required this.chatId,
    required this.scenario,
    required this.snapshot,
  });

  final String chatId;
  final RpgScenario scenario;
  final RpgStateSnapshot snapshot;

  RpgRuntimeState get state => snapshot.state;
  String get branchId => snapshot.metadata.branchId;
}

class RpgCommittedAction {
  const RpgCommittedAction({required this.execution, required this.snapshot});

  final RpgActionExecution execution;
  final RpgStateSnapshot snapshot;
}

class RpgSessionException implements Exception {
  const RpgSessionException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'RpgSessionException($code): $message';
}

/// Coordinates rule execution and snapshot persistence for one chat session.
class RpgGameSessionService {
  RpgGameSessionService({
    required RpgPersistenceRepository repository,
    RpgRuleEngine engine = const RpgRuleEngine(),
    DateTime Function()? now,
    String Function()? idFactory,
  })  : _repository = repository,
        _engine = engine,
        _now = now ?? _utcNow,
        _idFactory = idFactory ?? _newId;

  final RpgPersistenceRepository _repository;
  final RpgRuleEngine _engine;
  final DateTime Function() _now;
  final String Function() _idFactory;

  Future<RpgGameSession> initialize({
    required String chatId,
    required RpgScenario scenario,
    String? branchId,
  }) async {
    if (await _repository.getCurrentState(chatId) != null) {
      throw RpgSessionException(
        'session_already_exists',
        'Chat `$chatId` already has an RPG session.',
      );
    }
    final persistedScenario = await _repository.getScenario(
      scenario.metadata.id,
    );
    if (persistedScenario == null) {
      await _repository.saveScenario(scenario);
    } else if (!const DeepCollectionEquality().equals(
      persistedScenario.toJson(),
      scenario.toJson(),
    )) {
      throw RpgSessionException(
        'scenario_conflict',
        'Scenario `${scenario.metadata.id}` differs from the persisted version.',
      );
    }

    final createdAt = _now().toUtc();
    final snapshot = _createSnapshot(
      state: scenario.initialState,
      branchId: branchId ?? _defaultBranchId(chatId),
      createdAt: createdAt,
    );
    await _repository.commitSnapshotAndCurrentState(
      chatId: chatId,
      snapshot: snapshot,
      expectedCurrentSnapshotId: null,
      updatedAt: createdAt,
    );
    return RpgGameSession(
      chatId: chatId,
      scenario: scenario,
      snapshot: snapshot,
    );
  }

  Future<RpgGameSession?> load(String chatId) async {
    final state = await _repository.getCurrentState(chatId);
    if (state == null) return null;
    final scenario = await _repository.getScenario(state.scenarioId);
    final snapshotId = await _repository.getCurrentSnapshotId(chatId);
    final snapshot =
        snapshotId == null ? null : await _requireSnapshot(snapshotId);
    if (scenario == null || snapshot == null) {
      throw RpgSessionException(
        'incomplete_session',
        'Chat `$chatId` has incomplete RPG persistence records.',
      );
    }
    if (!const DeepCollectionEquality().equals(
      snapshot.state.toJson(),
      state.toJson(),
    )) {
      throw RpgSessionException(
        'state_snapshot_mismatch',
        'Chat `$chatId` state does not match its current snapshot.',
      );
    }
    return RpgGameSession(
      chatId: chatId,
      scenario: scenario,
      snapshot: snapshot,
    );
  }

  Future<RpgCommittedAction> executeAction({
    required String chatId,
    required String actionId,
  }) async {
    final session = await _requireSession(chatId);
    final execution = _engine.execute(
      scenario: session.scenario,
      state: session.state,
      actionId: actionId,
    );
    final createdAt = _now().toUtc();
    final snapshot = _createSnapshot(
      state: execution.state,
      branchId: session.branchId,
      parentSnapshotId: session.snapshot.metadata.id,
      createdAt: createdAt,
    );
    await _repository.commitSnapshotAndCurrentState(
      chatId: chatId,
      snapshot: snapshot,
      expectedCurrentSnapshotId: session.snapshot.metadata.id,
      updatedAt: createdAt,
    );
    return RpgCommittedAction(execution: execution, snapshot: snapshot);
  }

  Future<RpgGameSession> rollback({
    required String chatId,
    required String snapshotId,
  }) async {
    final session = await _requireSession(chatId);
    final snapshot = await _requireSnapshot(snapshotId);
    _requireSameScenario(session.scenario, snapshot);
    await _requireSameSnapshotGraph(session.snapshot, snapshot);
    final updatedAt = _now().toUtc();
    await _repository.saveCurrentState(
      chatId: chatId,
      scenarioId: snapshot.metadata.scenarioId,
      state: snapshot.state,
      currentSnapshotId: snapshot.metadata.id,
      expectedCurrentSnapshotId: session.snapshot.metadata.id,
      updatedAt: updatedAt,
    );
    return RpgGameSession(
      chatId: chatId,
      scenario: session.scenario,
      snapshot: snapshot,
    );
  }

  Future<RpgGameSession> forkBranch({
    required String chatId,
    required String fromSnapshotId,
    required String branchId,
  }) async {
    final session = await _requireSession(chatId);
    final source = await _requireSnapshot(fromSnapshotId);
    _requireSameScenario(session.scenario, source);
    await _requireSameSnapshotGraph(session.snapshot, source);
    if (source.metadata.branchId == branchId) {
      throw RpgSessionException(
        'branch_not_new',
        'Branch `$branchId` is already the source branch.',
      );
    }
    final existing = await _repository.listSnapshots(
      scenarioId: source.metadata.scenarioId,
      branchId: branchId,
    );
    if (existing.isNotEmpty) {
      throw RpgSessionException(
        'branch_already_exists',
        'Branch `$branchId` already exists.',
      );
    }

    final createdAt = _now().toUtc();
    final branchRoot = _createSnapshot(
      state: source.state,
      branchId: branchId,
      parentSnapshotId: source.metadata.id,
      createdAt: createdAt,
    );
    await _repository.commitSnapshotAndCurrentState(
      chatId: chatId,
      snapshot: branchRoot,
      expectedCurrentSnapshotId: session.snapshot.metadata.id,
      updatedAt: createdAt,
    );
    return RpgGameSession(
      chatId: chatId,
      scenario: session.scenario,
      snapshot: branchRoot,
    );
  }

  Future<List<RpgEventRecord>> getTurnLog(String chatId) async {
    final session = await _requireSession(chatId);
    return List.unmodifiable(session.state.eventHistory);
  }

  Future<List<RpgStateSnapshot>> listSessionSnapshots(String chatId) async {
    final session = await _requireSession(chatId);
    final rootId = await _rootSnapshotId(session.snapshot);
    final scenarioSnapshots = await _repository.listSnapshots(
      scenarioId: session.scenario.metadata.id,
    );
    final snapshots = <RpgStateSnapshot>[];
    for (final snapshot in scenarioSnapshots) {
      if (await _rootSnapshotId(snapshot) == rootId) snapshots.add(snapshot);
    }
    snapshots.sort((left, right) {
      final byTime = left.metadata.createdAt.compareTo(
        right.metadata.createdAt,
      );
      return byTime != 0
          ? byTime
          : left.metadata.id.compareTo(right.metadata.id);
    });
    return List.unmodifiable(snapshots);
  }

  Future<RpgGameSession> _requireSession(String chatId) async {
    final session = await load(chatId);
    if (session == null) {
      throw RpgSessionException(
        'session_not_found',
        'Chat `$chatId` does not have an RPG session.',
      );
    }
    return session;
  }

  Future<RpgStateSnapshot> _requireSnapshot(String snapshotId) async {
    final snapshot = await _repository.getSnapshot(snapshotId);
    if (snapshot == null) {
      throw RpgSessionException(
        'snapshot_not_found',
        'RPG snapshot `$snapshotId` does not exist.',
      );
    }
    final expectedHash = snapshot.metadata.stateHash;
    if (expectedHash != null && expectedHash != _stateHash(snapshot.state)) {
      throw RpgSessionException(
        'snapshot_hash_mismatch',
        'RPG snapshot `$snapshotId` failed its state integrity check.',
      );
    }
    return snapshot;
  }

  void _requireSameScenario(RpgScenario scenario, RpgStateSnapshot snapshot) {
    if (snapshot.metadata.scenarioId != scenario.metadata.id ||
        snapshot.metadata.scenarioVersion != scenario.metadata.version) {
      throw RpgSessionException(
        'snapshot_scenario_mismatch',
        'Snapshot `${snapshot.metadata.id}` belongs to another scenario.',
      );
    }
  }

  Future<void> _requireSameSnapshotGraph(
    RpgStateSnapshot current,
    RpgStateSnapshot target,
  ) async {
    final currentRoot = await _rootSnapshotId(current);
    final targetRoot = await _rootSnapshotId(target);
    if (currentRoot != targetRoot) {
      throw RpgSessionException(
        'snapshot_session_mismatch',
        'Snapshot `${target.metadata.id}` belongs to another RPG session.',
      );
    }
  }

  Future<String> _rootSnapshotId(RpgStateSnapshot snapshot) async {
    final visited = <String>{};
    var cursor = snapshot;
    while (true) {
      final parentId = cursor.metadata.parentSnapshotId;
      if (parentId == null) break;
      if (!visited.add(cursor.metadata.id)) {
        throw RpgSessionException(
          'snapshot_lineage_cycle',
          'Snapshot lineage contains a cycle at `${cursor.metadata.id}`.',
        );
      }
      cursor = await _requireSnapshot(parentId);
    }
    return cursor.metadata.id;
  }

  RpgStateSnapshot _createSnapshot({
    required RpgRuntimeState state,
    required String branchId,
    String? parentSnapshotId,
    required DateTime createdAt,
  }) {
    return RpgStateSnapshot(
      metadata: RpgSnapshotMetadata(
        id: 'snapshot_${_idFactory()}',
        scenarioId: state.scenarioId,
        scenarioVersion: state.scenarioVersion,
        branchId: branchId,
        parentSnapshotId: parentSnapshotId,
        turn: state.turn,
        randomState: state.random.state,
        rollsConsumed: state.random.rollsConsumed,
        createdAt: createdAt,
        stateHash: _stateHash(state),
      ),
      state: state,
    );
  }
}

String _defaultBranchId(String chatId) {
  final safeChatId = chatId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return 'chat_${safeChatId}_main';
}

String _stateHash(RpgRuntimeState state) {
  final canonical = _canonicalize(state.toJson());
  return 'sha256:${sha256.convert(utf8.encode(jsonEncode(canonical)))}';
}

Object? _canonicalize(Object? value) {
  if (value is List<Object?>) return value.map(_canonicalize).toList();
  if (value is Map<Object?, Object?>) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  return value;
}

DateTime _utcNow() => DateTime.now().toUtc();

String _newId() => const Uuid().v4();

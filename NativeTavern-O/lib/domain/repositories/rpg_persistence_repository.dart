import 'package:native_tavern/data/models/rpg/rpg.dart';

abstract interface class RpgPersistenceRepository {
  Future<RpgScenario?> getScenario(String scenarioId);

  Future<List<RpgScenario>> listScenarios();

  Future<void> saveScenario(RpgScenario scenario);

  Future<void> deleteScenario(String scenarioId);

  Future<RpgRuntimeState?> getCurrentState(String chatId);

  Future<String?> getCurrentSnapshotId(String chatId);

  Future<void> saveCurrentState({
    required String chatId,
    required String scenarioId,
    required RpgRuntimeState state,
    String? currentSnapshotId,
    String? expectedCurrentSnapshotId,
    required DateTime updatedAt,
  });

  Future<RpgStateSnapshot?> getSnapshot(String snapshotId);

  Future<List<RpgStateSnapshot>> listSnapshots({
    required String scenarioId,
    String? branchId,
  });

  Future<void> saveSnapshot(RpgStateSnapshot snapshot);

  Future<void> commitSnapshotAndCurrentState({
    required String chatId,
    required RpgStateSnapshot snapshot,
    required String? expectedCurrentSnapshotId,
    required DateTime updatedAt,
  });
}

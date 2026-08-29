import 'package:native_tavern/data/models/long_term_memory.dart';

/// One full-text match. Lower [rank] values are more relevant BM25 scores.
final class LongTermMemorySearchResult {
  const LongTermMemorySearchResult({
    required this.memory,
    required this.rank,
  });

  final LongTermMemory memory;
  final double rank;
}

/// Storage-independent operations required by the long-term memory feature.
abstract interface class LongTermMemoryRepository {
  Future<LongTermMemory?> getById(String id);

  Future<LongTermMemory> create(LongTermMemory memory);

  /// Creates a batch atomically. No record is retained when one write fails.
  Future<List<LongTermMemory>> createAll(List<LongTermMemory> memories);

  Future<LongTermMemory> update(LongTermMemory memory);

  Future<void> delete(String id);

  /// Finds memories in an exact owner scope.
  Future<List<LongTermMemory>> findByScope(
    MemoryScope scope, {
    Set<MemoryState> states = const <MemoryState>{},
    bool includeExpired = false,
    DateTime? at,
  });

  /// Finds memories citing a chat, optionally narrowed to one message.
  Future<List<LongTermMemory>> findBySource({
    required String chatId,
    String? messageId,
  });

  /// Lists memories across owner scopes for inbox and lifecycle processing.
  Future<List<LongTermMemory>> findByStates(
    Set<MemoryState> states, {
    bool includeExpired = true,
    DateTime? at,
  });

  /// Finds the most relevant memories in one exact owner scope.
  ///
  /// User input is treated as plain text rather than FTS query syntax. By
  /// default, only active memories that have not expired are returned.
  Future<List<LongTermMemorySearchResult>> search(
    String query, {
    required MemoryScope scope,
    int topK = 20,
    Set<MemoryState> states = const <MemoryState>{MemoryState.active},
    bool includeExpired = false,
    DateTime? at,
  });

  /// Recreates the derived full-text index from canonical memory records.
  Future<void> rebuildSearchIndex();

  /// Makes [resolved] active and atomically supersedes prior records.
  ///
  /// The prior records must share [resolved]'s exact scope. Locked records
  /// cannot be replaced through this automatic governance boundary.
  Future<LongTermMemory> resolve(
    LongTermMemory resolved, {
    Set<String> supersededMemoryIds = const <String>{},
  });

  /// Applies one lifecycle state to a group of records atomically.
  ///
  /// [supersededByMemoryId] is required only when [state] is superseded.
  Future<void> updateStates({
    required Set<String> memoryIds,
    required MemoryState state,
    String? supersededByMemoryId,
  });
}

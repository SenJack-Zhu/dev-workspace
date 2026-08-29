import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/operation_log.dart';
import 'package:uuid/uuid.dart';

/// Durable execution log. Open rows (running / incomplete) are retried;
/// completed rows stay as history.
final class OperationLogRepository {
  OperationLogRepository(this._db, {String Function()? createId})
      : _createId = createId ?? const Uuid().v4;

  final AppDatabase _db;
  final String Function() _createId;

  Future<OperationLog> begin({
    required OperationKind kind,
    required String subjectId,
    Map<String, dynamic> payload = const {},
    DateTime? now,
  }) async {
    final clock = (now ?? DateTime.now()).toUtc();
    final existing = await findOpen(kind: kind, subjectId: subjectId);
    if (existing != null) {
      final next = existing.copyWith(
        status: OperationStatus.running,
        attempts: existing.attempts + 1,
        payload: payload.isEmpty ? existing.payload : payload,
        startedAt: clock,
        dueAt: clock,
        updatedAt: clock,
        clearError: true,
      );
      await _update(next);
      return next;
    }
    final created = OperationLog(
      id: _createId(),
      kind: kind,
      subjectId: subjectId,
      status: OperationStatus.running,
      attempts: 1,
      payload: payload,
      dueAt: clock,
      startedAt: clock,
      createdAt: clock,
      updatedAt: clock,
    );
    await _db.customStatement(
      'INSERT INTO operation_logs ('
      'id, kind, subject_id, status, attempts, payload_json, last_error, '
      'due_at, started_at, completed_at, created_at, updated_at'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        created.id,
        created.kind.wireName,
        created.subjectId,
        created.status.wireName,
        created.attempts,
        jsonEncode(created.payload),
        null,
        _millis(created.dueAt),
        created.startedAt == null ? null : _millis(created.startedAt!),
        null,
        _millis(created.createdAt),
        _millis(created.updatedAt),
      ],
    );
    return created;
  }

  Future<void> markCompleted(OperationLog log, {DateTime? now}) {
    final clock = (now ?? DateTime.now()).toUtc();
    return _update(
      log.copyWith(
        status: OperationStatus.completed,
        completedAt: clock,
        updatedAt: clock,
        clearError: true,
      ),
    );
  }

  /// Closes a retryable operation without pretending that it succeeded.
  ///
  /// The current schema uses `completed` as the terminal state. Keeping the
  /// reason in [lastError] makes expired and exhausted background work
  /// auditable while ensuring it is never selected for another retry.
  Future<void> stopRetrying(
    OperationLog log, {
    required String reason,
    DateTime? now,
  }) {
    final clock = (now ?? DateTime.now()).toUtc();
    return _update(
      log.copyWith(
        status: OperationStatus.completed,
        lastError: reason,
        completedAt: clock,
        updatedAt: clock,
      ),
    );
  }

  Future<void> markIncomplete(
    OperationLog log, {
    String? error,
    DateTime? dueAt,
    DateTime? now,
  }) {
    final clock = (now ?? DateTime.now()).toUtc();
    return _update(
      log.copyWith(
        status: OperationStatus.incomplete,
        lastError: error,
        dueAt: dueAt ?? clock,
        updatedAt: clock,
      ),
    );
  }

  Future<OperationLog?> findOpen({
    required OperationKind kind,
    required String subjectId,
  }) async {
    final row = await _db.customSelect(
      'SELECT * FROM operation_logs '
      'WHERE kind = ? AND subject_id = ? '
      "AND status IN ('running', 'incomplete') "
      'ORDER BY updated_at DESC LIMIT 1',
      variables: [
        Variable<String>(kind.wireName),
        Variable<String>(subjectId),
      ],
    ).getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Future<List<OperationLog>> listRetryable({
    DateTime? now,
    int limit = 4,
    Set<OperationKind>? kinds,
  }) async {
    final clock = (now ?? DateTime.now()).toUtc();
    final filters = <String>[
      "(status = 'running' OR (status = 'incomplete' AND due_at <= ?))",
    ];
    final variables = <Variable>[
      Variable<int>(_millis(clock)),
    ];
    if (kinds != null && kinds.isNotEmpty) {
      final placeholders = List.filled(kinds.length, '?').join(', ');
      filters.add('kind IN ($placeholders)');
      for (final kind in kinds) {
        variables.add(Variable<String>(kind.wireName));
      }
    }
    variables.add(Variable<int>(limit));
    final rows = await _db
        .customSelect(
          'SELECT * FROM operation_logs '
          'WHERE ${filters.join(' AND ')} '
          'ORDER BY due_at ASC, created_at ASC '
          'LIMIT ?',
          variables: variables,
        )
        .get();
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<void> _update(OperationLog log) {
    return _db.customStatement(
      'UPDATE operation_logs SET '
      'status = ?, attempts = ?, payload_json = ?, last_error = ?, '
      'due_at = ?, started_at = ?, completed_at = ?, updated_at = ? '
      'WHERE id = ?',
      [
        log.status.wireName,
        log.attempts,
        jsonEncode(log.payload),
        log.lastError,
        _millis(log.dueAt),
        log.startedAt == null ? null : _millis(log.startedAt!),
        log.completedAt == null ? null : _millis(log.completedAt!),
        _millis(log.updatedAt),
        log.id,
      ],
    );
  }

  OperationLog _fromRow(QueryRow row) {
    final data = row.data;
    final payloadRaw = data['payload_json'];
    Map<String, dynamic> payload = const {};
    if (payloadRaw is String && payloadRaw.trim().isNotEmpty) {
      final decoded = jsonDecode(payloadRaw);
      if (decoded is Map<String, dynamic>) payload = decoded;
    }
    return OperationLog(
      id: data['id'] as String,
      kind: OperationKindSql.parse(data['kind'] as String),
      subjectId: data['subject_id'] as String,
      status: OperationStatusSql.parse(data['status'] as String),
      attempts: data['attempts'] as int,
      payload: payload,
      lastError: data['last_error'] as String?,
      dueAt: _date(data['due_at'] as int),
      startedAt: _optionalDate(data['started_at'] as int?),
      completedAt: _optionalDate(data['completed_at'] as int?),
      createdAt: _date(data['created_at'] as int),
      updatedAt: _date(data['updated_at'] as int),
    );
  }

  static int _millis(DateTime value) => value.toUtc().millisecondsSinceEpoch;

  static DateTime _date(int millis) =>
      DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);

  static DateTime? _optionalDate(int? millis) =>
      millis == null ? null : _date(millis);
}

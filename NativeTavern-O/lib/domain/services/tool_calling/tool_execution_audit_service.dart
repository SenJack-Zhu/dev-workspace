import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:path/path.dart' as p;

final class ToolExecutionAuditRecord {
  final DateTime timestamp;
  final String callIdFingerprint;
  final String toolName;
  final ToolAccessLevel accessLevel;
  final Map<String, dynamic> parameterSummary;
  final String target;
  final ToolAuthorizationSource authorizationSource;
  final ToolExecutionOutcome result;
  final String? errorCode;
  final int durationMilliseconds;

  ToolExecutionAuditRecord({
    required this.timestamp,
    required this.callIdFingerprint,
    required this.toolName,
    required this.accessLevel,
    required Map<String, dynamic> parameterSummary,
    required this.target,
    required this.authorizationSource,
    required this.result,
    this.errorCode,
    required this.durationMilliseconds,
  }) : parameterSummary = copyToolJsonObject(parameterSummary);

  factory ToolExecutionAuditRecord.fromJson(Map<String, dynamic> json) {
    return ToolExecutionAuditRecord(
      timestamp: DateTime.parse(json['timestamp'] as String),
      callIdFingerprint: json['callIdFingerprint'] as String,
      toolName: json['toolName'] as String,
      accessLevel: ToolAccessLevel.values.firstWhere(
        (candidate) => candidate.name == json['accessLevel'],
      ),
      parameterSummary: Map<String, dynamic>.from(
        json['parameterSummary'] as Map<dynamic, dynamic>? ?? const {},
      ),
      target: json['target'] as String,
      authorizationSource: ToolAuthorizationSource.values.firstWhere(
        (candidate) => candidate.name == json['authorizationSource'],
      ),
      result: ToolExecutionOutcome.values.firstWhere(
        (candidate) => candidate.name == json['result'],
      ),
      errorCode: json['errorCode'] as String?,
      durationMilliseconds: json['durationMilliseconds'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toUtc().toIso8601String(),
        'callIdFingerprint': callIdFingerprint,
        'toolName': toolName,
        'accessLevel': accessLevel.name,
        'parameterSummary': parameterSummary,
        'target': target,
        'authorizationSource': authorizationSource.name,
        'result': result.name,
        'errorCode': errorCode,
        'durationMilliseconds': durationMilliseconds,
      };
}

abstract interface class ToolExecutionAuditRepository {
  Future<void> record(ToolExecutionAuditRecord record);

  Future<List<ToolExecutionAuditRecord>> readRecent({int limit = 100});
}

final class NoopToolExecutionAuditRepository
    implements ToolExecutionAuditRepository {
  const NoopToolExecutionAuditRepository();

  @override
  Future<void> record(ToolExecutionAuditRecord record) async {}

  @override
  Future<List<ToolExecutionAuditRecord>> readRecent({int limit = 100}) async {
    return const [];
  }
}

final class MemoryToolExecutionAuditRepository
    implements ToolExecutionAuditRepository {
  final List<ToolExecutionAuditRecord> _records = [];

  @override
  Future<void> record(ToolExecutionAuditRecord record) async {
    _records.add(record);
  }

  @override
  Future<List<ToolExecutionAuditRecord>> readRecent({int limit = 100}) async {
    if (limit <= 0) return const [];
    final start = (_records.length - limit).clamp(0, _records.length);
    return _records.sublist(start).reversed.toList(growable: false);
  }
}

final class FileToolExecutionAuditRepository
    implements ToolExecutionAuditRepository {
  static const _relativePath = 'audit/tool_executions.jsonl';

  final String dataPath;
  Future<void> _writeTail = Future<void>.value();

  FileToolExecutionAuditRepository({required this.dataPath});

  File get _file => File(p.join(dataPath, _relativePath));

  @override
  Future<void> record(ToolExecutionAuditRecord record) {
    final operation = _writeTail.then((_) async {
      final file = _file;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(record.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }

  @override
  Future<List<ToolExecutionAuditRecord>> readRecent({int limit = 100}) async {
    if (limit <= 0) return const [];
    await _writeTail;
    final file = _file;
    if (!file.existsSync()) return const [];

    final records = <ToolExecutionAuditRecord>[];
    for (final line in (await file.readAsLines()).reversed) {
      if (records.length >= limit) break;
      if (line.trim().isEmpty) continue;
      try {
        records.add(
          ToolExecutionAuditRecord.fromJson(
            jsonDecode(line) as Map<String, dynamic>,
          ),
        );
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      } on StateError {
        continue;
      }
    }
    return records;
  }
}

Map<String, dynamic> summarizeToolArguments(
  Map<String, dynamic> arguments, {
  Iterable<String> sensitiveArgumentNames = const [],
}) {
  final sensitive =
      sensitiveArgumentNames.map((name) => name.toLowerCase()).toSet();
  return {
    for (final entry in arguments.entries)
      entry.key: _summarizeValue(
        entry.value,
        sensitive: sensitive.contains(entry.key.toLowerCase()) ||
            _looksSensitive(entry.key),
      ),
  };
}

Object? _summarizeValue(Object? value, {required bool sensitive}) {
  if (value == null) return null;
  if (sensitive) {
    return {
      'type': _valueType(value),
      'redacted': true,
      if (value is String) 'length': value.length,
      if (value is List) 'length': value.length,
      if (value is Map) 'fieldCount': value.length,
    };
  }
  if (value is bool || value is num) return value;
  if (value is String) {
    return {'type': 'string', 'length': value.length, 'redacted': true};
  }
  if (value is List) {
    return {'type': 'list', 'length': value.length, 'redacted': true};
  }
  if (value is Map) {
    return {
      'type': 'object',
      'fieldCount': value.length,
      'redacted': true,
    };
  }
  return {'type': value.runtimeType.toString(), 'redacted': true};
}

String fingerprintToolCallId(String callId) {
  return 'sha256:${sha256.convert(utf8.encode(callId))}';
}

String _valueType(Object? value) {
  if (value == null) return 'null';
  if (value is String) return 'string';
  if (value is bool) return 'boolean';
  if (value is num) return 'number';
  if (value is List) return 'list';
  if (value is Map) return 'object';
  return value.runtimeType.toString();
}

bool _looksSensitive(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return normalized.contains('apikey') ||
      normalized.contains('authorization') ||
      normalized.contains('password') ||
      normalized.contains('secret') ||
      normalized.contains('token') ||
      normalized.contains('credential') ||
      normalized.contains('cookie') ||
      normalized.contains('prompt') ||
      normalized.contains('content') ||
      normalized.contains('query') ||
      normalized.contains('value');
}

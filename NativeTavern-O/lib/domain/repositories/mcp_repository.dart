import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:path/path.dart' as p;

abstract interface class McpSettingsRepository {
  Future<McpStoredSettings> load();

  Future<void> save(McpStoredSettings settings);
}

final class FileMcpSettingsRepository implements McpSettingsRepository {
  FileMcpSettingsRepository({required this.dataPath});

  final String dataPath;
  Future<void> _writeTail = Future.value();

  File get _file => File(p.join(dataPath, 'mcp', 'settings.json'));

  @override
  Future<McpStoredSettings> load() async {
    await _writeTail;
    final file = _file;
    if (!file.existsSync()) return McpStoredSettings();
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('MCP settings root must be an object.');
      }
      return McpStoredSettings.fromJson(decoded);
    } on FormatException catch (error) {
      throw McpException('invalid_settings', error.message);
    } on TypeError {
      throw const McpException(
        'invalid_settings',
        'Stored MCP settings have an invalid shape.',
      );
    } on StateError {
      throw const McpException(
        'invalid_settings',
        'Stored MCP settings contain an unsupported value.',
      );
    }
  }

  @override
  Future<void> save(McpStoredSettings settings) {
    final operation = _writeTail.then((_) async {
      final file = _file;
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(settings.toJson()),
        flush: true,
      );
      await temporary.rename(file.path);
    });
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }
}

final class MemoryMcpSettingsRepository implements McpSettingsRepository {
  MemoryMcpSettingsRepository([McpStoredSettings? initial])
      : value = initial ?? McpStoredSettings();

  McpStoredSettings value;

  @override
  Future<McpStoredSettings> load() async => value;

  @override
  Future<void> save(McpStoredSettings settings) async => value = settings;
}

abstract interface class McpCredentialRepository {
  Future<String?> readToken(String serverId);

  Future<void> writeToken(String serverId, String token);

  Future<void> deleteToken(String serverId);
}

final class SecureMcpCredentialRepository implements McpCredentialRepository {
  const SecureMcpCredentialRepository({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  String _key(String serverId) => 'native_tavern.mcp.$serverId.token';

  @override
  Future<String?> readToken(String serverId) =>
      _storage.read(key: _key(serverId));

  @override
  Future<void> writeToken(String serverId, String token) async {
    final value = token.trim();
    if (value.isEmpty) {
      await deleteToken(serverId);
      return;
    }
    await _storage.write(key: _key(serverId), value: value);
  }

  @override
  Future<void> deleteToken(String serverId) =>
      _storage.delete(key: _key(serverId));
}

final class MemoryMcpCredentialRepository implements McpCredentialRepository {
  final Map<String, String> values = {};

  @override
  Future<String?> readToken(String serverId) async => values[serverId];

  @override
  Future<void> writeToken(String serverId, String token) async {
    if (token.trim().isEmpty) {
      values.remove(serverId);
    } else {
      values[serverId] = token.trim();
    }
  }

  @override
  Future<void> deleteToken(String serverId) async => values.remove(serverId);
}

abstract interface class McpActivityRepository {
  Future<void> record(McpActivityRecord record);

  Future<List<McpActivityRecord>> readRecent({int limit = 100});
}

final class FileMcpActivityRepository implements McpActivityRepository {
  FileMcpActivityRepository({required this.dataPath});

  final String dataPath;
  Future<void> _writeTail = Future.value();

  File get _file => File(p.join(dataPath, 'audit', 'mcp_activity.jsonl'));

  @override
  Future<void> record(McpActivityRecord record) {
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
  Future<List<McpActivityRecord>> readRecent({int limit = 100}) async {
    if (limit <= 0) return const [];
    await _writeTail;
    final file = _file;
    if (!file.existsSync()) return const [];
    final result = <McpActivityRecord>[];
    for (final line in (await file.readAsLines()).reversed) {
      if (result.length >= limit) break;
      if (line.trim().isEmpty) continue;
      try {
        result.add(McpActivityRecord.fromJson(
          Map<String, dynamic>.from(jsonDecode(line) as Map),
        ));
      } catch (_) {
        continue;
      }
    }
    return result;
  }
}

final class MemoryMcpActivityRepository implements McpActivityRepository {
  final List<McpActivityRecord> records = [];

  @override
  Future<void> record(McpActivityRecord record) async => records.add(record);

  @override
  Future<List<McpActivityRecord>> readRecent({int limit = 100}) async {
    if (limit <= 0) return const [];
    final start = (records.length - limit).clamp(0, records.length);
    return records.sublist(start).reversed.toList(growable: false);
  }
}

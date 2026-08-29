// Draft files are intentionally tiny and user-triggered; asynchronous I/O keeps
// editor saves off the UI isolate's synchronous filesystem path.
// ignore_for_file: avoid_slow_async_io

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'rpg_scenario_package_service.dart';

class RpgScenarioDraft {
  final Map<String, dynamic> document;
  final RpgScenarioPackageFormat format;
  final DateTime updatedAt;

  const RpgScenarioDraft({
    required this.document,
    required this.format,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'document': document,
        'format': format.name,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory RpgScenarioDraft.fromJson(Map<String, dynamic> json) =>
      RpgScenarioDraft(
        document: Map<String, dynamic>.from(
          json['document'] as Map<dynamic, dynamic>,
        ),
        format: RpgScenarioPackageFormat.values.firstWhere(
          (value) => value.name == json['format'],
          orElse: () => RpgScenarioPackageFormat.json,
        ),
        updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      );
}

abstract class RpgScenarioDraftStore {
  Future<void> save(RpgScenarioDraft draft);
  Future<RpgScenarioDraft?> load();
  Future<void> clear();
}

/// Stores the active editor draft locally using an atomic replace operation.
class FileRpgScenarioDraftStore implements RpgScenarioDraftStore {
  final Directory rootDirectory;

  const FileRpgScenarioDraftStore(this.rootDirectory);

  static Future<FileRpgScenarioDraftStore> forApplicationSupport() async {
    final support = await getApplicationSupportDirectory();
    return FileRpgScenarioDraftStore(
      Directory(path.join(support.path, 'rpg_scenario_editor')),
    );
  }

  File get _draftFile =>
      File(path.join(rootDirectory.path, 'active_draft.json'));

  @override
  Future<void> save(RpgScenarioDraft draft) async {
    await rootDirectory.create(recursive: true);
    final target = _draftFile;
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    await temporary.writeAsString(jsonEncode(draft.toJson()), flush: true);

    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (await target.exists()) await target.delete();
      if (await backup.exists()) await backup.rename(target.path);
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<RpgScenarioDraft?> load() async {
    final file = _draftFile;
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('RPG scenario draft root must be an object.');
    }
    return RpgScenarioDraft.fromJson(decoded);
  }

  @override
  Future<void> clear() async {
    final file = _draftFile;
    if (await file.exists()) await file.delete();
  }
}

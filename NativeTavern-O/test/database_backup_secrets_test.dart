import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/domain/services/database_backup_service.dart';

void main() {
  test('database backup excludes API keys and restore preserves local key',
      () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final now = DateTime.utc(2026, 1, 1);
    await database.into(database.llmConfigs).insert(
          LlmConfigsCompanion.insert(
            id: 'config',
            name: 'Provider',
            provider: 'openai',
            endpoint: 'https://example.com',
            apiKey: const Value('device-secret'),
            createdAt: now,
            modifiedAt: now,
          ),
        );
    final service = DatabaseBackupService(database);

    final exported = await service.exportAllData();
    final config = (exported['llmConfigs'] as Map)['config'] as Map;
    expect(config['apiKey'], isNull);

    final restoredConfig = Map<String, dynamic>.from(config)
      ..['name'] = 'Restored Provider'
      ..['modifiedAt'] = now.add(const Duration(days: 1)).toIso8601String();
    await service.importData(
      data: {
        'llmConfigs': {'config': restoredConfig},
      },
      mode: ImportMode.replace,
    );
    final stored = await (database.select(database.llmConfigs)
          ..where((table) => table.id.equals('config')))
        .getSingle();
    expect(stored.apiKey, 'device-secret');
    expect(stored.name, 'Restored Provider');
  });
}

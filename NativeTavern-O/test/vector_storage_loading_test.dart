import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/vector_storage_service.dart';
import 'package:native_tavern/presentation/providers/vector_storage_providers.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String path;

  _FakePathProvider(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('collection notifier waits for an in-flight disk load', () async {
    final tempDir = Directory.systemTemp.createTempSync('nt_vector_load');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);

    final storageDir = Directory('${tempDir.path}/NativeTavern')..createSync();
    File('${storageDir.path}/vector_collections.json').writeAsStringSync(
      jsonEncode([
        {
          'id': 'persisted-collection',
          'name': 'Persisted',
          'dimensions': 1536,
          'documents': [],
          'createdAt': DateTime(2026).toIso8601String(),
          'updatedAt': DateTime(2026).toIso8601String(),
        }
      ]),
    );

    final service = VectorStorageService();
    final load = service.load();
    final notifier = VectorCollectionsNotifier(service);
    addTearDown(notifier.dispose);

    await load;
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.map((collection) => collection.id),
        contains('persisted-collection'));
  });
}

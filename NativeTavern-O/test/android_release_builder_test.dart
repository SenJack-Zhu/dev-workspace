import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import '../tool/build_android_release.dart';

void main() {
  test('removes only dev-only entries from an Android registrant', () {
    const source = '''
public final class GeneratedPluginRegistrant {
  public static void registerWith(FlutterEngine flutterEngine) {
    try {
      flutterEngine.getPlugins().add(new example.ProductionPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin production, example.ProductionPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new example.TestPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin integration_test, example.TestPlugin", e);
    }
  }
}
''';

    final result = removeAndroidDevPluginRegistrations(
      source,
      {'integration_test'},
    );

    expect(result.removedPlugins, {'integration_test'});
    expect(result.source, contains('ProductionPlugin'));
    expect(result.source, isNot(contains('TestPlugin')));
  });

  test('reads Android dev dependencies from Flutter plugin metadata', () {
    final temporary = Directory.systemTemp.createTempSync(
      'native_tavern_android_builder_',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final metadata = File(path.join(temporary.path, 'plugins.json'))
      ..writeAsStringSync(
        jsonEncode({
          'plugins': {
            'android': [
              {'name': 'production', 'dev_dependency': false},
              {'name': 'integration_test', 'dev_dependency': true},
            ],
          },
        }),
      );

    expect(readAndroidDevPluginNames(metadata), {'integration_test'});
  });
}

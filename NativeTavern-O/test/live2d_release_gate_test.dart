import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../tool/live2d_release_gate.dart';

void main() {
  final repositoryRoot = Directory.current;

  test('development audit verifies every pinned runtime and model artifact',
      () async {
    final report = await auditLive2DRelease(
      repositoryRoot: repositoryRoot,
      mode: Live2DGateMode.development,
    );

    expect(report.errors, isEmpty);
    expect(report.checkedArtifacts, 61);
  });

  test('release is blocked until physical-device evidence exists', () async {
    final report = await auditLive2DRelease(
      repositoryRoot: repositoryRoot,
      mode: Live2DGateMode.release,
    );

    expect(
      report.errors.where((error) => error.contains('Release License')),
      isEmpty,
    );
    expect(
      report.errors,
      contains('android physical-device validation is not verified.'),
    );
    expect(
      report.errors,
      contains('ios physical-device validation is not verified.'),
    );
  });

  test('development audit rejects a modified tracked artifact', () async {
    final manifest = jsonDecode(
      File('config/live2d_release_manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final core = manifest['core'] as Map<String, dynamic>;
    final artifacts = core['artifacts'] as List<dynamic>;
    final macOSCore = artifacts.last as Map<String, dynamic>;
    macOSCore['sha256'] = List.filled(64, '0').join();

    final tempDirectory = Directory.systemTemp.createTempSync('live2d_gate');
    addTearDown(() => tempDirectory.deleteSync(recursive: true));
    final manifestFile = File(p.join(tempDirectory.path, 'manifest.json'))
      ..writeAsStringSync(jsonEncode(manifest));

    final report = await auditLive2DRelease(
      repositoryRoot: repositoryRoot,
      mode: Live2DGateMode.development,
      manifestFile: manifestFile,
    );

    expect(
      report.errors,
      contains(
        'Live2D artifact SHA-256 mismatch: '
        'packages/native_tavern_live2d_macos/macos/Libs/'
        'libLive2DCubismCore.dylib',
      ),
    );
  });

  test('development audit rejects an unpinned bridge revision', () async {
    final manifest = jsonDecode(
      File('config/live2d_release_manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final bridge = manifest['bridge'] as Map<String, dynamic>;
    bridge['sourceRevision'] = List.filled(40, '0').join();

    final tempDirectory = Directory.systemTemp.createTempSync('live2d_gate');
    addTearDown(() => tempDirectory.deleteSync(recursive: true));
    final manifestFile = File(p.join(tempDirectory.path, 'manifest.json'))
      ..writeAsStringSync(jsonEncode(manifest));

    final report = await auditLive2DRelease(
      repositoryRoot: repositoryRoot,
      mode: Live2DGateMode.development,
      manifestFile: manifestFile,
    );

    expect(
      report.errors,
      contains(
        'Live2D bridge revision mismatch: manifest '
        '${List.filled(40, '0').join()}, lock '
        '378b5b977df47672c78e12723f93854300a87e40.',
      ),
    );
  });
}

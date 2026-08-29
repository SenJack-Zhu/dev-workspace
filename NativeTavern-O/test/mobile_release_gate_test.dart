// Test fixtures intentionally validate filesystem-backed release evidence.
// ignore_for_file: avoid_slow_async_io

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import '../tool/mobile_release_gate.dart';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('mobile_release_gate_');
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  test('repository manifest is complete before device evidence exists',
      () async {
    final report = await auditMobileReleaseGate(
      repositoryRoot: Directory.current,
      mode: MobileReleaseGateMode.development,
      expectedCommit: 'a' * 40,
    );

    expect(report.errors, isEmpty);
    expect(
        report.warnings, contains('No device evidence has been recorded yet.'));
    expect(report.checkedRuns, 0);
  });

  test('release requires complete current-commit physical runs', () async {
    final manifest = _copyManifest(temporary);
    _createRunnerFiles(temporary);
    final requiredScenarios =
        (manifest['requiredScenarios'] as List).cast<Map<String, dynamic>>();
    final commit = 'b' * 40;
    final runs = [
      _passingRun(temporary, 'android', commit, requiredScenarios),
      _passingRun(temporary, 'ios', commit, requiredScenarios),
    ];
    _writeJson(
      path.join(temporary.path, 'release_evidence/mobile_release_runs.json'),
      {'schemaVersion': 1, 'runs': runs, 'failures': <Object>[]},
    );

    final report = await auditMobileReleaseGate(
      repositoryRoot: temporary,
      expectedCommit: commit,
    );

    expect(report.errors, isEmpty);
    expect(report.passed, isTrue);
    expect(report.checkedRuns, 2);
  });

  test('simulator identity and incomplete failure records are rejected',
      () async {
    final manifest = _copyManifest(temporary);
    final requiredScenarios =
        (manifest['requiredScenarios'] as List).cast<Map<String, dynamic>>();
    final run = _passingRun(
      temporary,
      'ios',
      'c' * 40,
      requiredScenarios,
    );
    (run['device'] as Map<String, dynamic>)
      ..['id'] = 'simulator-123'
      ..['model'] = 'iPhone Simulator';
    final scenarios = run['scenarios'] as Map<String, dynamic>;
    scenarios['offline'] = {
      'status': 'failed',
      'failureId': 'MOBILE-1',
    };
    _writeJson(
      path.join(temporary.path, 'release_evidence/mobile_release_runs.json'),
      {
        'schemaVersion': 1,
        'runs': [run],
        'failures': [
          {
            'id': 'MOBILE-1',
            'platform': 'ios',
            'scenario': 'offline',
            'summary': 'Offline draft disappeared',
            'observedAt': '2026-08-08T09:00:00Z',
            'reproductionSteps': <String>[],
            'evidence': <String>[],
          },
        ],
      },
    );

    final report = await auditMobileReleaseGate(
      repositoryRoot: temporary,
      mode: MobileReleaseGateMode.development,
      expectedCommit: 'c' * 40,
    );

    expect(
      report.errors,
      contains('run[0] marks a simulator or emulator as physical.'),
    );
    expect(
      report.errors,
      contains('Failure MOBILE-1 requires reproduction steps and evidence.'),
    );
    expect(report.passed, isFalse);
  });

  test('release accepts an evidence-only commit after the tested build',
      () async {
    final manifest = _copyManifest(temporary);
    _createRunnerFiles(temporary);
    _writeJson(
      path.join(temporary.path, 'release_evidence/mobile_release_runs.json'),
      {'schemaVersion': 1, 'runs': <Object>[], 'failures': <Object>[]},
    );
    _writeJson(
      path.join(temporary.path, 'config/live2d_release_manifest.json'),
      {
        'schemaVersion': 1,
        'artifacts': ['unchanged-runtime'],
        'releaseEvidence': {'status': 'pending'},
      },
    );
    final buildCommit = _commitFixture(temporary, 'tested release build');
    final requiredScenarios =
        (manifest['requiredScenarios'] as List).cast<Map<String, dynamic>>();
    final runs = [
      _passingRun(temporary, 'android', buildCommit, requiredScenarios),
      _passingRun(temporary, 'ios', buildCommit, requiredScenarios),
    ];
    _writeJson(
      path.join(temporary.path, 'release_evidence/mobile_release_runs.json'),
      {'schemaVersion': 1, 'runs': runs, 'failures': <Object>[]},
    );
    _writeJson(
      path.join(temporary.path, 'config/live2d_release_manifest.json'),
      {
        'schemaVersion': 1,
        'artifacts': ['unchanged-runtime'],
        'releaseEvidence': {'status': 'verified'},
      },
    );
    _commitFixture(temporary, 'record release evidence');

    final report = await auditMobileReleaseGate(repositoryRoot: temporary);

    expect(report.errors, isEmpty);
    expect(report.passed, isTrue);
  });

  test('release rejects runtime changes made after the tested build', () async {
    final manifest = _copyManifest(temporary);
    _createRunnerFiles(temporary);
    _writeJson(
      path.join(temporary.path, 'release_evidence/mobile_release_runs.json'),
      {'schemaVersion': 1, 'runs': <Object>[], 'failures': <Object>[]},
    );
    final buildCommit = _commitFixture(temporary, 'tested release build');
    final requiredScenarios =
        (manifest['requiredScenarios'] as List).cast<Map<String, dynamic>>();
    final runs = [
      _passingRun(temporary, 'android', buildCommit, requiredScenarios),
      _passingRun(temporary, 'ios', buildCommit, requiredScenarios),
    ];
    _writeJson(
      path.join(temporary.path, 'release_evidence/mobile_release_runs.json'),
      {'schemaVersion': 1, 'runs': runs, 'failures': <Object>[]},
    );
    File(path.join(temporary.path, 'lib/runtime_change.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('const runtimeChanged = true;\n');
    _commitFixture(temporary, 'change runtime after device test');

    final report = await auditMobileReleaseGate(repositoryRoot: temporary);

    expect(
      report.errors,
      contains(
        startsWith(
          'No complete physical android release run matches the current '
          'release code',
        ),
      ),
    );
    expect(
      report.warnings,
      contains('run[0] buildCommit does not match the current release code.'),
    );
    expect(report.passed, isFalse);
  });
}

Map<String, dynamic> _copyManifest(Directory root) {
  final manifest = jsonDecode(
    File('config/mobile_release_gate.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  _writeJson(path.join(root.path, 'config/mobile_release_gate.json'), manifest);
  return manifest;
}

Map<String, dynamic> _passingRun(
  Directory root,
  String platform,
  String commit,
  List<Map<String, dynamic>> requiredScenarios,
) {
  final scenarios = <String, dynamic>{};
  for (final definition in requiredScenarios) {
    final id = definition['id'] as String;
    final evidence = <Map<String, String>>[];
    for (final type
        in (definition['requiredEvidence'] as List).cast<String>()) {
      final relative = 'release_evidence/$platform/$id-$type.txt';
      final file = File(path.join(root.path, relative));
      file.createSync(recursive: true);
      file.writeAsStringSync('verified');
      evidence.add({'type': type, 'location': relative});
    }
    scenarios[id] = {'status': 'passed', 'evidence': evidence};
  }
  return {
    'id': '$platform-current',
    'platform': platform,
    'device': {
      'id': '$platform-physical-1',
      'model': platform == 'ios' ? 'iPhone 17' : 'Pixel 10',
      'osVersion': platform == 'ios' ? 'iOS 26' : 'Android 16',
      'isPhysical': true,
    },
    'buildMode': 'release',
    'buildCommit': commit,
    'startedAt': '2026-08-08T08:00:00Z',
    'completedAt': '2026-08-08T08:40:00Z',
    'automatedChecks': {
      'fullTestSuite': 'passed',
      'formatCheck': 'passed',
      'live2dDevelopmentAudit': 'passed',
      'manifestAudit': 'passed',
    },
    'scenarios': scenarios,
    'metrics': {
      'sampleMinutes': 30,
      'startupMilliseconds': 1200,
      'typedChatP95Milliseconds': 100,
      'frameBuildP95Milliseconds': 12,
      'frameRasterP95Milliseconds': 11,
      'droppedFramePercent': 0.4,
      'memoryGrowthMiB': 18,
    },
  };
}

void _createRunnerFiles(Directory root) {
  for (final relative in [
    'android/app/src/main/AndroidManifest.xml',
    'ios/Runner/Info.plist',
  ]) {
    File(path.join(root.path, relative))
      ..createSync(recursive: true)
      ..writeAsStringSync('fixture');
  }
}

void _writeJson(String filePath, Object value) {
  final file = File(filePath)..createSync(recursive: true);
  file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(value)}\n');
}

String _commitFixture(Directory root, String message) {
  if (!Directory(path.join(root.path, '.git')).existsSync()) {
    _runGit(root, ['init']);
    _runGit(root, ['config', 'user.name', 'Release Gate Test']);
    _runGit(root, ['config', 'user.email', 'release-gate@example.invalid']);
  }
  _runGit(root, ['add', '.']);
  _runGit(root, ['commit', '-m', message]);
  return _runGit(root, ['rev-parse', 'HEAD']).trim();
}

String _runGit(Directory root, List<String> arguments) {
  final result = Process.runSync('git', arguments, workingDirectory: root.path);
  if (result.exitCode != 0) {
    throw StateError(
      'git ${arguments.join(' ')} failed: ${result.stderr}',
    );
  }
  return result.stdout.toString();
}

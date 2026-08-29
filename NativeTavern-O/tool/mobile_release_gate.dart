// Release evidence intentionally reads local files and invokes Git.
// ignore_for_file: avoid_slow_async_io

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

enum MobileReleaseGateMode { development, release }

final class MobileReleaseGateReport {
  final List<String> errors;
  final List<String> warnings;
  final int checkedRuns;

  const MobileReleaseGateReport({
    required this.errors,
    required this.warnings,
    required this.checkedRuns,
  });

  bool get passed => errors.isEmpty;
}

Future<MobileReleaseGateReport> auditMobileReleaseGate({
  required Directory repositoryRoot,
  MobileReleaseGateMode mode = MobileReleaseGateMode.release,
  File? manifestFile,
  File? evidenceFile,
  String? expectedCommit,
}) async {
  final root = repositoryRoot.absolute;
  final errors = <String>[];
  final warnings = <String>[];
  final manifest = _readJsonMap(
    manifestFile ??
        File(path.join(root.path, 'config/mobile_release_gate.json')),
    'mobile release manifest',
    errors,
  );
  final evidence = _readJsonMap(
    evidenceFile ??
        File(path.join(
          root.path,
          'release_evidence/mobile_release_runs.json',
        )),
    'mobile release evidence',
    errors,
  );
  if (manifest == null || evidence == null) {
    return MobileReleaseGateReport(
      errors: List.unmodifiable(errors),
      warnings: List.unmodifiable(warnings),
      checkedRuns: 0,
    );
  }

  if (manifest['schemaVersion'] != 1 || evidence['schemaVersion'] != 1) {
    errors.add('Unsupported mobile release gate schemaVersion.');
  }
  final platforms = _stringSet(
    manifest['requiredPlatforms'],
    'requiredPlatforms',
    errors,
  );
  const expectedPlatforms = {'android', 'ios'};
  if (!platforms.containsAll(expectedPlatforms)) {
    errors.add('requiredPlatforms must include android and ios.');
  }

  final scenarioDefinitions = _mapList(
    manifest['requiredScenarios'],
    'requiredScenarios',
    errors,
  );
  final scenarios = <String, Map<String, dynamic>>{};
  for (final definition in scenarioDefinitions) {
    final id = _requiredString(definition, 'id', 'scenario', errors);
    if (id == null) continue;
    if (scenarios.containsKey(id)) {
      errors.add('Duplicate required scenario: $id.');
      continue;
    }
    scenarios[id] = definition;
    for (final field in ['title', 'procedure', 'expectedResult']) {
      _requiredString(definition, field, 'scenario $id', errors);
    }
    final requiredEvidence = _stringSet(
      definition['requiredEvidence'],
      'scenario $id requiredEvidence',
      errors,
    );
    if (requiredEvidence.isEmpty) {
      errors.add('Scenario $id must require evidence.');
    }
  }
  const expectedScenarios = {
    'offline',
    'weakNetwork',
    'permissionDenied',
    'lowMemory',
    'foregroundBackgroundRecovery',
    'performance',
    'featuresDisabledTextChatBaseline',
  };
  if (!scenarios.keys.toSet().containsAll(expectedScenarios)) {
    errors.add('The mobile matrix is missing one or more required scenarios.');
  }

  final thresholds = _map(
    manifest['performanceThresholds'],
    'performanceThresholds',
    errors,
  );
  if (thresholds != null) {
    for (final field in [
      'minimumSampleMinutes',
      'maximumStartupMilliseconds',
      'maximumTypedChatP95Milliseconds',
      'maximumFrameBuildP95Milliseconds',
      'maximumFrameRasterP95Milliseconds',
      'maximumDroppedFramePercent',
      'maximumMemoryGrowthMiB',
    ]) {
      final value = thresholds[field];
      if (value is! num || value <= 0) {
        errors.add('performanceThresholds.$field must be positive.');
      }
    }
  }
  final automatedChecks = _mapList(
    manifest['automatedChecks'],
    'automatedChecks',
    errors,
  );
  final automatedCheckIds = <String>{};
  for (final check in automatedChecks) {
    final id = _requiredString(check, 'id', 'automated check', errors);
    final command =
        _requiredString(check, 'command', 'automated check', errors);
    if (id != null) automatedCheckIds.add(id);
    if (command != null && command.contains('--update-goldens')) {
      errors.add('Automated release checks must not update expected results.');
    }
  }
  const expectedAutomatedChecks = {
    'fullTestSuite',
    'formatCheck',
    'live2dDevelopmentAudit',
    'manifestAudit',
  };
  if (!automatedCheckIds.containsAll(expectedAutomatedChecks)) {
    errors.add('The automated release gate is incomplete.');
  }

  final failures = _mapList(evidence['failures'], 'failures', errors);
  final failuresById = <String, Map<String, dynamic>>{};
  for (final failure in failures) {
    final id = _requiredString(failure, 'id', 'failure', errors);
    if (id == null) continue;
    if (failuresById.containsKey(id)) {
      errors.add('Duplicate failure ID: $id.');
      continue;
    }
    failuresById[id] = failure;
    _validateFailure(
      failure,
      id,
      platforms,
      scenarios.keys.toSet(),
      root,
      errors,
    );
  }

  final runs = _mapList(evidence['runs'], 'runs', errors);
  final expectedHead = expectedCommit ?? await _readHeadCommit(root, errors);
  final acceptableBuildCommits = <String>{expectedHead};
  if (mode == MobileReleaseGateMode.release && expectedCommit == null) {
    await _requireCleanGitWorktree(root, errors);
    for (final run in runs) {
      final buildCommit = run['buildCommit'];
      if (buildCommit is String &&
          RegExp(r'^[0-9a-f]{40}$').hasMatch(buildCommit) &&
          buildCommit != expectedHead &&
          await _hasOnlyReleaseEvidenceChanges(
            root,
            buildCommit,
            expectedHead,
          )) {
        acceptableBuildCommits.add(buildCommit);
      }
    }
  }
  final qualifyingPlatforms = <String>{};
  for (var index = 0; index < runs.length; index++) {
    final run = runs[index];
    final result = _validateRun(
      run,
      index,
      platforms,
      scenarios,
      thresholds,
      automatedCheckIds,
      failuresById,
      acceptableBuildCommits,
      root,
      errors,
      warnings,
    );
    if (result != null) qualifyingPlatforms.add(result);
  }

  if (mode == MobileReleaseGateMode.release) {
    _requireRunnerFiles(root, errors);
    for (final platform in expectedPlatforms) {
      if (!qualifyingPlatforms.contains(platform)) {
        errors.add(
          'No complete physical $platform release run matches the current '
          'release code at $expectedHead.',
        );
      }
    }
  } else if (runs.isEmpty) {
    warnings.add('No device evidence has been recorded yet.');
  }

  return MobileReleaseGateReport(
    errors: List.unmodifiable(errors),
    warnings: List.unmodifiable(warnings),
    checkedRuns: runs.length,
  );
}

String? _validateRun(
  Map<String, dynamic> run,
  int index,
  Set<String> platforms,
  Map<String, Map<String, dynamic>> scenarios,
  Map<String, dynamic>? thresholds,
  Set<String> automatedCheckIds,
  Map<String, Map<String, dynamic>> failuresById,
  Set<String> acceptableBuildCommits,
  Directory root,
  List<String> errors,
  List<String> warnings,
) {
  final label = 'run[$index]';
  _requiredString(run, 'id', label, errors);
  final platform = _requiredString(run, 'platform', label, errors);
  final buildCommit = _requiredString(run, 'buildCommit', label, errors);
  final buildMode = _requiredString(run, 'buildMode', label, errors);
  final startedAt = _dateTime(run, 'startedAt', label, errors);
  final completedAt = _dateTime(run, 'completedAt', label, errors);
  if (platform != null && !platforms.contains(platform)) {
    errors.add('$label has unsupported platform $platform.');
  }
  if (buildCommit != null && !RegExp(r'^[0-9a-f]{40}$').hasMatch(buildCommit)) {
    errors.add('$label buildCommit must be a full lowercase Git SHA.');
  } else if (buildCommit != null &&
      !acceptableBuildCommits.contains(buildCommit)) {
    warnings.add(
      '$label buildCommit does not match the current release code.',
    );
  }
  if (buildMode != 'release') {
    warnings.add('$label is not a release-mode run and cannot qualify.');
  }
  if (startedAt != null &&
      completedAt != null &&
      completedAt.isBefore(startedAt)) {
    errors.add('$label completedAt precedes startedAt.');
  }

  final device = _map(run['device'], '$label device', errors);
  var physical = false;
  if (device != null) {
    final id = _requiredString(device, 'id', '$label device', errors);
    final model = _requiredString(device, 'model', '$label device', errors);
    _requiredString(device, 'osVersion', '$label device', errors);
    physical = device['isPhysical'] == true;
    final identity = '${id ?? ''} ${model ?? ''}'.toLowerCase();
    if (identity.contains('simulator') ||
        identity.contains('emulator') ||
        identity.startsWith('emulator-')) {
      if (physical) {
        errors.add('$label marks a simulator or emulator as physical.');
      }
      physical = false;
    }
  }

  final checkResults = _map(
    run['automatedChecks'],
    '$label automatedChecks',
    errors,
  );
  var allChecksPassed = checkResults != null;
  for (final checkId in automatedCheckIds) {
    if (checkResults?[checkId] != 'passed') {
      allChecksPassed = false;
      warnings.add('$label has not passed automated check $checkId.');
    }
  }

  final scenarioResults = _map(run['scenarios'], '$label scenarios', errors);
  var allScenariosPassed = scenarioResults != null;
  if (scenarioResults != null) {
    for (final entry in scenarios.entries) {
      final result = _map(
        scenarioResults[entry.key],
        '$label scenario ${entry.key}',
        errors,
      );
      if (result == null) {
        allScenariosPassed = false;
        continue;
      }
      final status = result['status'];
      if (!const {'pending', 'passed', 'failed', 'blocked'}.contains(status)) {
        errors.add('$label scenario ${entry.key} has an invalid status.');
        allScenariosPassed = false;
      }
      if (status != 'passed') allScenariosPassed = false;
      if (status == 'failed' || status == 'blocked') {
        final failureId = result['failureId'];
        if (failureId is! String || !failuresById.containsKey(failureId)) {
          errors.add(
            '$label scenario ${entry.key} must reference a failure record.',
          );
        }
      }
      if (status == 'passed') {
        final actualEvidence = _evidenceTypes(
          result['evidence'],
          '$label scenario ${entry.key}',
          root,
          errors,
        );
        final requiredEvidence = _stringSet(
          entry.value['requiredEvidence'],
          'scenario ${entry.key} requiredEvidence',
          errors,
        );
        if (!actualEvidence.containsAll(requiredEvidence)) {
          errors.add(
            '$label scenario ${entry.key} is missing required evidence.',
          );
          allScenariosPassed = false;
        }
      }
    }
  }

  final metricsPassed =
      _validateMetrics(run['metrics'], thresholds, label, errors);
  final qualifies = platform != null &&
      physical &&
      buildMode == 'release' &&
      acceptableBuildCommits.contains(buildCommit) &&
      allChecksPassed &&
      allScenariosPassed &&
      metricsPassed;
  return qualifies ? platform : null;
}

bool _validateMetrics(
  Object? value,
  Map<String, dynamic>? thresholds,
  String label,
  List<String> errors,
) {
  final metrics = _map(value, '$label metrics', errors);
  if (metrics == null || thresholds == null) return false;
  final comparisons = <({String metric, String threshold, bool minimum})>[
    (
      metric: 'sampleMinutes',
      threshold: 'minimumSampleMinutes',
      minimum: true,
    ),
    (
      metric: 'startupMilliseconds',
      threshold: 'maximumStartupMilliseconds',
      minimum: false,
    ),
    (
      metric: 'typedChatP95Milliseconds',
      threshold: 'maximumTypedChatP95Milliseconds',
      minimum: false,
    ),
    (
      metric: 'frameBuildP95Milliseconds',
      threshold: 'maximumFrameBuildP95Milliseconds',
      minimum: false,
    ),
    (
      metric: 'frameRasterP95Milliseconds',
      threshold: 'maximumFrameRasterP95Milliseconds',
      minimum: false,
    ),
    (
      metric: 'droppedFramePercent',
      threshold: 'maximumDroppedFramePercent',
      minimum: false,
    ),
    (
      metric: 'memoryGrowthMiB',
      threshold: 'maximumMemoryGrowthMiB',
      minimum: false,
    ),
  ];
  var passed = true;
  for (final comparison in comparisons) {
    final actual = metrics[comparison.metric];
    final expected = thresholds[comparison.threshold];
    if (actual is! num || expected is! num) {
      errors.add('$label is missing numeric ${comparison.metric}.');
      passed = false;
      continue;
    }
    final outside = comparison.minimum ? actual < expected : actual > expected;
    if (outside) {
      errors.add(
        '$label ${comparison.metric} is outside the release threshold.',
      );
      passed = false;
    }
  }
  return passed;
}

void _validateFailure(
  Map<String, dynamic> failure,
  String id,
  Set<String> platforms,
  Set<String> scenarios,
  Directory root,
  List<String> errors,
) {
  final platform = _requiredString(failure, 'platform', 'failure $id', errors);
  final scenario = _requiredString(failure, 'scenario', 'failure $id', errors);
  _requiredString(failure, 'summary', 'failure $id', errors);
  _dateTime(failure, 'observedAt', 'failure $id', errors);
  if (platform != null && !platforms.contains(platform)) {
    errors.add('Failure $id has unsupported platform $platform.');
  }
  if (scenario != null && !scenarios.contains(scenario)) {
    errors.add('Failure $id has unknown scenario $scenario.');
  }
  final steps = _stringSet(
    failure['reproductionSteps'],
    'failure $id reproductionSteps',
    errors,
  );
  final evidence = _stringSet(
    failure['evidence'],
    'failure $id evidence',
    errors,
  );
  if (steps.isEmpty || evidence.isEmpty) {
    errors.add('Failure $id requires reproduction steps and evidence.');
  }
  for (final location in evidence) {
    final uri = Uri.tryParse(location);
    final isRemote = uri != null && uri.hasScheme && uri.scheme == 'https';
    if (!isRemote && !File(path.join(root.path, location)).existsSync()) {
      errors.add('Failure $id evidence does not exist: $location.');
    }
  }
}

Set<String> _evidenceTypes(
  Object? value,
  String label,
  Directory root,
  List<String> errors,
) {
  final entries = _mapList(value, '$label evidence', errors);
  final types = <String>{};
  for (final entry in entries) {
    final type = _requiredString(entry, 'type', '$label evidence', errors);
    final location =
        _requiredString(entry, 'location', '$label evidence', errors);
    if (type != null) types.add(type);
    if (location == null) continue;
    final uri = Uri.tryParse(location);
    final isRemote = uri != null && uri.hasScheme && uri.scheme == 'https';
    if (!isRemote && !File(path.join(root.path, location)).existsSync()) {
      errors.add('$label evidence does not exist: $location.');
    }
  }
  return types;
}

void _requireRunnerFiles(Directory root, List<String> errors) {
  const required = [
    'android/app/src/main/AndroidManifest.xml',
    'ios/Runner/Info.plist',
  ];
  for (final relativePath in required) {
    if (!File(path.join(root.path, relativePath)).existsSync()) {
      errors.add('Release runner is missing: $relativePath.');
    }
  }
}

Future<String> _readHeadCommit(Directory root, List<String> errors) async {
  final result = await Process.run(
    'git',
    ['rev-parse', 'HEAD'],
    workingDirectory: root.path,
  );
  final value = result.stdout.toString().trim();
  if (result.exitCode != 0 || !RegExp(r'^[0-9a-f]{40}$').hasMatch(value)) {
    errors.add('Could not determine the current Git commit.');
    return '';
  }
  return value;
}

Future<void> _requireCleanGitWorktree(
  Directory root,
  List<String> errors,
) async {
  final result = await Process.run(
    'git',
    ['status', '--porcelain', '--untracked-files=all'],
    workingDirectory: root.path,
  );
  if (result.exitCode != 0) {
    errors.add('Could not inspect the Git worktree for release validation.');
  } else if (result.stdout.toString().trim().isNotEmpty) {
    errors.add('Release validation requires a clean Git worktree.');
  }
}

Future<bool> _hasOnlyReleaseEvidenceChanges(
  Directory root,
  String buildCommit,
  String headCommit,
) async {
  final ancestor = await Process.run(
    'git',
    ['merge-base', '--is-ancestor', buildCommit, headCommit],
    workingDirectory: root.path,
  );
  if (ancestor.exitCode != 0) return false;

  final diff = await Process.run(
    'git',
    ['diff', '--name-only', '--no-renames', '$buildCommit..$headCommit', '--'],
    workingDirectory: root.path,
  );
  if (diff.exitCode != 0) return false;
  final changedPaths = diff.stdout
      .toString()
      .split('\n')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty);
  for (final changedPath in changedPaths) {
    if (changedPath.startsWith('release_evidence/')) continue;
    if (changedPath == 'config/live2d_release_manifest.json' &&
        await _live2dManifestChangeIsEvidenceOnly(
          root,
          buildCommit,
          headCommit,
        )) {
      continue;
    }
    return false;
  }
  return true;
}

Future<bool> _live2dManifestChangeIsEvidenceOnly(
  Directory root,
  String buildCommit,
  String headCommit,
) async {
  final manifests = <Map<String, dynamic>>[];
  for (final commit in [buildCommit, headCommit]) {
    final result = await Process.run(
      'git',
      ['show', '$commit:config/live2d_release_manifest.json'],
      workingDirectory: root.path,
    );
    if (result.exitCode != 0) return false;
    try {
      final decoded = jsonDecode(result.stdout.toString());
      if (decoded is! Map<String, dynamic>) return false;
      manifests
          .add(Map<String, dynamic>.from(decoded)..remove('releaseEvidence'));
    } on FormatException {
      return false;
    }
  }
  return jsonEncode(_canonicalJson(manifests[0])) ==
      jsonEncode(_canonicalJson(manifests[1]));
}

Object? _canonicalJson(Object? value) {
  if (value is List) return value.map(_canonicalJson).toList();
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  return value;
}

Map<String, dynamic>? _readJsonMap(
  File file,
  String label,
  List<String> errors,
) {
  if (!file.existsSync()) {
    errors.add('Missing $label: ${file.path}.');
    return null;
  }
  try {
    final value = jsonDecode(file.readAsStringSync());
    if (value is Map<String, dynamic>) return value;
  } on FormatException catch (error) {
    errors.add('Invalid $label JSON: $error.');
    return null;
  }
  errors.add('$label must be a JSON object.');
  return null;
}

Map<String, dynamic>? _map(
  Object? value,
  String label,
  List<String> errors,
) {
  if (value is Map<String, dynamic>) return value;
  errors.add('$label must be an object.');
  return null;
}

List<Map<String, dynamic>> _mapList(
  Object? value,
  String label,
  List<String> errors,
) {
  if (value is! List) {
    errors.add('$label must be a list.');
    return const [];
  }
  final result = <Map<String, dynamic>>[];
  for (var index = 0; index < value.length; index++) {
    final entry = value[index];
    if (entry is Map<String, dynamic>) {
      result.add(entry);
    } else {
      errors.add('$label[$index] must be an object.');
    }
  }
  return result;
}

Set<String> _stringSet(
  Object? value,
  String label,
  List<String> errors,
) {
  if (value is! List || value.any((item) => item is! String || item.isEmpty)) {
    errors.add('$label must be a list of non-empty strings.');
    return const {};
  }
  return value.cast<String>().toSet();
}

String? _requiredString(
  Map<String, dynamic> value,
  String field,
  String label,
  List<String> errors,
) {
  final result = value[field];
  if (result is String && result.trim().isNotEmpty) return result;
  errors.add('$label requires a non-empty $field.');
  return null;
}

DateTime? _dateTime(
  Map<String, dynamic> value,
  String field,
  String label,
  List<String> errors,
) {
  final raw = _requiredString(value, field, label, errors);
  final result = raw == null ? null : DateTime.tryParse(raw);
  if (raw != null && result == null) errors.add('$label has invalid $field.');
  return result;
}

Future<void> main(List<String> arguments) async {
  final development = arguments.contains('--development');
  final unknown = arguments.where((argument) => argument != '--development');
  if (unknown.isNotEmpty) {
    stderr.writeln('Usage: dart run tool/mobile_release_gate.dart '
        '[--development]');
    exitCode = 64;
    return;
  }
  final report = await auditMobileReleaseGate(
    repositoryRoot: Directory.current,
    mode: development
        ? MobileReleaseGateMode.development
        : MobileReleaseGateMode.release,
  );
  for (final warning in report.warnings) {
    stdout.writeln('WARNING: $warning');
  }
  for (final error in report.errors) {
    stderr.writeln('ERROR: $error');
  }
  if (report.passed) {
    stdout.writeln(
      'Mobile release gate passed (${report.checkedRuns} run(s) checked).',
    );
  } else {
    stderr.writeln(
      'Mobile release gate failed with ${report.errors.length} error(s).',
    );
    exitCode = 1;
  }
}

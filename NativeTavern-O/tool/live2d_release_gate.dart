import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

enum Live2DGateMode { development, release }

class Live2DGateReport {
  final List<String> errors;
  final int checkedArtifacts;

  const Live2DGateReport({
    required this.errors,
    required this.checkedArtifacts,
  });

  bool get passed => errors.isEmpty;
}

Future<Live2DGateReport> auditLive2DRelease({
  required Directory repositoryRoot,
  Live2DGateMode mode = Live2DGateMode.release,
  File? manifestFile,
}) async {
  final errors = <String>[];
  var checkedArtifacts = 0;
  final root = repositoryRoot.absolute;
  final manifest = await _readJsonMap(
    manifestFile ??
        File(p.join(root.path, 'config/live2d_release_manifest.json')),
    errors,
  );
  if (manifest == null) {
    return Live2DGateReport(errors: errors, checkedArtifacts: 0);
  }
  if (manifest['schemaVersion'] != 1) {
    errors.add('Unsupported Live2D manifest schemaVersion.');
  }

  final packageRoot = await _resolvePackageRoot(root, 'flutter_live2d', errors);
  final bridge = _map(manifest['bridge'], 'bridge', errors);
  if (bridge != null) {
    await _verifyBridge(root, packageRoot, bridge, errors);
    checkedArtifacts++;
    for (final value
        in _list(bridge['artifactSets'], 'bridge.artifactSets', errors)) {
      final artifactSet = _map(value, 'bridge artifact set', errors);
      if (artifactSet == null) continue;
      checkedArtifacts += await _verifyArtifactSet(
        root,
        packageRoot,
        artifactSet,
        errors,
      );
    }
  }

  for (final sectionName in ['framework', 'core']) {
    final section = _map(manifest[sectionName], sectionName, errors);
    if (section == null) continue;
    _requireExistingFile(
        root, section['licenseFile'], '$sectionName license', errors);
    if (sectionName == 'core') {
      _requireExistingFile(
        root,
        section['redistributableFilesList'],
        'Cubism Core redistributable files list',
        errors,
      );
    }
    final artifacts =
        _list(section['artifacts'], '$sectionName.artifacts', errors);
    for (final value in artifacts) {
      final artifact = _map(value, '$sectionName artifact', errors);
      if (artifact == null) continue;
      await _verifyArtifact(root, packageRoot, artifact, errors);
      checkedArtifacts++;
    }
  }

  final reviewedAssetRoots = <String>{};
  final models = _list(manifest['models'], 'models', errors);
  for (final value in models) {
    final model = _map(value, 'model', errors);
    if (model == null) continue;
    final assetRoot = model['assetRoot'];
    if (assetRoot is! String || assetRoot.isEmpty) {
      errors.add('A Live2D model is missing assetRoot.');
      continue;
    }
    reviewedAssetRoots.add(_withTrailingSlash(assetRoot));
    _requireExistingFile(root, model['licenseFile'], 'model license', errors);
    final declaredFiles = <String>{};
    final files = _list(model['files'], 'model.files', errors);
    for (final value in files) {
      final artifact = _map(value, 'model artifact', errors);
      if (artifact == null) continue;
      final relativePath = artifact['path'];
      if (relativePath is String) {
        declaredFiles.add(p.posix.normalize(relativePath));
      }
      await _verifyArtifact(
        root,
        packageRoot,
        {
          ...artifact,
          'path': p.posix.join(assetRoot, relativePath?.toString() ?? ''),
        },
        errors,
      );
      checkedArtifacts++;
    }
    _verifyModelInventory(root, assetRoot, declaredFiles, errors);
    if (mode == Live2DGateMode.release && model['releaseApproved'] != true) {
      errors.add('Live2D model ${model['id']} is not approved for release.');
    }
  }

  await _verifyPubspecAssets(root, reviewedAssetRoots, errors);
  for (final notice in _list(
    manifest['requiredNotices'],
    'requiredNotices',
    errors,
  )) {
    _requireExistingFile(root, notice, 'required notice', errors);
  }

  if (mode == Live2DGateMode.release) {
    _verifyReleaseEvidence(manifest['releaseEvidence'], errors);
  }
  return Live2DGateReport(
    errors: List.unmodifiable(errors),
    checkedArtifacts: checkedArtifacts,
  );
}

Future<void> _verifyBridge(
  Directory root,
  Directory? packageRoot,
  Map<String, dynamic> bridge,
  List<String> errors,
) async {
  final lockFile = File(p.join(root.path, 'pubspec.lock'));
  if (!lockFile.existsSync()) {
    errors.add('pubspec.lock is missing.');
    return;
  }
  final lock = loadYaml(lockFile.readAsStringSync());
  final packageName = bridge['package'];
  final locked = lock is YamlMap && lock['packages'] is YamlMap
      ? (lock['packages'] as YamlMap)[packageName]
      : null;
  if (locked is! YamlMap) {
    errors.add('Live2D bridge $packageName is not present in pubspec.lock.');
    return;
  }
  if (locked['version'] != bridge['version']) {
    errors.add(
      'Live2D bridge version mismatch: manifest ${bridge['version']}, '
      'lock ${locked['version']}.',
    );
  }
  final description = locked['description'];
  if (locked['source'] != 'git' || description is! YamlMap) {
    errors.add('Live2D bridge must resolve from the pinned Git source.');
  } else {
    final lockedRevision = description['resolved-ref'];
    if (lockedRevision != bridge['sourceRevision']) {
      errors.add(
        'Live2D bridge revision mismatch: manifest '
        '${bridge['sourceRevision']}, lock $lockedRevision.',
      );
    }
    final lockedUrl = description['url'];
    if (lockedUrl is! String ||
        _normalizeGitUrl(lockedUrl) != _normalizeGitUrl(bridge['source'])) {
      errors.add('Live2D bridge Git source does not match the manifest.');
    }
  }
  _requireExistingFile(root, bridge['licenseFile'], 'bridge license', errors);

  if (packageRoot != null) {
    final packagePubspec = File(p.join(packageRoot.path, 'pubspec.yaml'));
    if (!packagePubspec.existsSync()) {
      errors.add('Resolved flutter_live2d package has no pubspec.yaml.');
    } else {
      final yaml = loadYaml(packagePubspec.readAsStringSync());
      if (yaml is! YamlMap || yaml['version'] != bridge['version']) {
        errors.add('Resolved flutter_live2d package version is not pinned.');
      }
    }
  }
}

Future<int> _verifyArtifactSet(
  Directory root,
  Directory? packageRoot,
  Map<String, dynamic> artifactSet,
  List<String> errors,
) async {
  final pathValue = artifactSet['path'];
  final expectedCount = artifactSet['fileCount'];
  final expectedSha = artifactSet['sha256'];
  if (pathValue is! String ||
      expectedCount is! int ||
      expectedCount < 1 ||
      expectedSha is! String) {
    errors.add('A Live2D artifact set is missing path, fileCount, or sha256.');
    return 0;
  }

  final resolved = _resolveArtifact(root, packageRoot, pathValue, errors);
  if (resolved == null) return 0;
  final directory = Directory(resolved.path);
  if (!directory.existsSync()) {
    errors.add('Live2D artifact set is missing: $pathValue');
    return 0;
  }

  final files = directory
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList()
    ..sort((a, b) {
      final aPath = p.posix.normalize(p.relative(a.path, from: directory.path));
      final bPath = p.posix.normalize(p.relative(b.path, from: directory.path));
      return aPath.compareTo(bPath);
    });
  if (files.length != expectedCount) {
    errors.add(
      'Live2D artifact set file count mismatch: $pathValue '
      '(manifest $expectedCount, actual ${files.length})',
    );
  }

  final inventory = StringBuffer();
  for (final file in files) {
    final relativePath =
        p.posix.normalize(p.relative(file.path, from: directory.path));
    final fileSha = sha256.convert(file.readAsBytesSync());
    inventory.writeln('$relativePath:$fileSha');
  }
  final actualSha =
      sha256.convert(utf8.encode(inventory.toString())).toString();
  if (actualSha != expectedSha) {
    errors.add('Live2D artifact set SHA-256 mismatch: $pathValue');
  }
  return files.length;
}

Future<void> _verifyArtifact(
  Directory root,
  Directory? packageRoot,
  Map<String, dynamic> artifact,
  List<String> errors,
) async {
  final pathValue = artifact['path'];
  final expectedSha = artifact['sha256'];
  if (pathValue is! String || expectedSha is! String) {
    errors.add('A Live2D artifact is missing path or sha256.');
    return;
  }
  final file = _resolveArtifact(root, packageRoot, pathValue, errors);
  if (file == null || !file.existsSync()) {
    errors.add('Live2D artifact is missing: $pathValue');
    return;
  }
  final actualSha = sha256.convert(file.readAsBytesSync()).toString();
  if (actualSha != expectedSha) {
    errors.add('Live2D artifact SHA-256 mismatch: $pathValue');
  }
}

File? _resolveArtifact(
  Directory root,
  Directory? packageRoot,
  String pathValue,
  List<String> errors,
) {
  const prefix = 'package:flutter_live2d/';
  if (pathValue.startsWith(prefix)) {
    if (packageRoot == null) return null;
    return File(p.join(packageRoot.path, pathValue.substring(prefix.length)));
  }
  final normalized = p.normalize(p.join(root.path, pathValue));
  if (!p.isWithin(root.path, normalized)) {
    errors.add('Live2D artifact escapes the repository: $pathValue');
    return null;
  }
  return File(normalized);
}

void _verifyModelInventory(
  Directory root,
  String assetRoot,
  Set<String> declaredFiles,
  List<String> errors,
) {
  final directory = Directory(p.join(root.path, assetRoot));
  if (!directory.existsSync()) {
    errors.add('Live2D model directory is missing: $assetRoot');
    return;
  }
  final actualFiles = directory
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .map((file) =>
          p.posix.normalize(p.relative(file.path, from: directory.path)))
      .toSet();
  for (final pathValue in actualFiles.difference(declaredFiles)) {
    errors.add('Unreviewed Live2D model file: $assetRoot$pathValue');
  }
  for (final pathValue in declaredFiles.difference(actualFiles)) {
    errors.add('Declared Live2D model file is missing: $assetRoot$pathValue');
  }
}

Future<void> _verifyPubspecAssets(
  Directory root,
  Set<String> reviewedRoots,
  List<String> errors,
) async {
  final pubspec = loadYaml(
    File(p.join(root.path, 'pubspec.yaml')).readAsStringSync(),
  );
  final flutter = pubspec is YamlMap ? pubspec['flutter'] : null;
  final assets = flutter is YamlMap ? flutter['assets'] : null;
  if (assets is! YamlList) {
    errors.add('pubspec.yaml has no Flutter asset list.');
    return;
  }
  for (final value in assets.whereType<String>()) {
    if (!value.startsWith('assets/live2d/')) continue;
    final covered = reviewedRoots.any((root) => value.startsWith(root));
    if (!covered) {
      errors.add('Unreviewed Live2D asset root in pubspec.yaml: $value');
    }
  }
}

void _verifyReleaseEvidence(Object? value, List<String> errors) {
  final evidence = _map(value, 'releaseEvidence', errors);
  if (evidence == null) return;
  final validation = _map(
    evidence['mobileValidation'],
    'releaseEvidence.mobileValidation',
    errors,
  );
  if (validation == null) return;
  if (validation['minimumCharacterSwitches'] is! int ||
      (validation['minimumCharacterSwitches'] as int) < 20) {
    errors.add('Mobile validation must cover at least 20 character switches.');
  }
  for (final platform in ['android', 'ios']) {
    final result = _map(validation[platform], '$platform validation', errors);
    if (result == null) continue;
    if (result['status'] != 'verified' || result['evidence'] is! String) {
      errors.add('$platform physical-device validation is not verified.');
    }
  }
}

Future<Directory?> _resolvePackageRoot(
  Directory root,
  String packageName,
  List<String> errors,
) async {
  final configFile = File(p.join(root.path, '.dart_tool/package_config.json'));
  if (!configFile.existsSync()) {
    errors.add('Run flutter pub get before the Live2D release gate.');
    return null;
  }
  final config = jsonDecode(configFile.readAsStringSync());
  final packages = config is Map<String, dynamic> ? config['packages'] : null;
  if (packages is! List) {
    errors.add('Invalid .dart_tool/package_config.json.');
    return null;
  }
  for (final value in packages) {
    if (value is Map && value['name'] == packageName) {
      final rootUri = value['rootUri'];
      if (rootUri is! String) break;
      return Directory.fromUri(configFile.uri.resolve(rootUri));
    }
  }
  errors.add('Unable to resolve package:$packageName.');
  return null;
}

Future<Map<String, dynamic>?> _readJsonMap(
  File file,
  List<String> errors,
) async {
  try {
    final value = jsonDecode(file.readAsStringSync());
    if (value is Map<String, dynamic>) return value;
    errors.add('Live2D release manifest must be a JSON object.');
  } catch (error) {
    errors.add('Unable to read Live2D release manifest: $error');
  }
  return null;
}

Map<String, dynamic>? _map(
  Object? value,
  String name,
  List<String> errors,
) {
  if (value is Map<String, dynamic>) return value;
  errors.add('$name must be an object.');
  return null;
}

List<dynamic> _list(Object? value, String name, List<String> errors) {
  if (value is List<dynamic>) return value;
  errors.add('$name must be a list.');
  return const [];
}

void _requireExistingFile(
  Directory root,
  Object? pathValue,
  String description,
  List<String> errors,
) {
  if (pathValue is! String ||
      !File(p.join(root.path, pathValue)).existsSync()) {
    errors.add('Missing $description: $pathValue');
  }
}

String _withTrailingSlash(String value) =>
    value.endsWith('/') ? value : '$value/';

String _normalizeGitUrl(Object? value) {
  if (value is! String) return '';
  return value.endsWith('.git') ? value.substring(0, value.length - 4) : value;
}

Future<void> main(List<String> arguments) async {
  final mode = arguments.contains('--development')
      ? Live2DGateMode.development
      : Live2DGateMode.release;
  final report = await auditLive2DRelease(
    repositoryRoot: Directory.current,
    mode: mode,
  );
  if (report.passed) {
    stdout.writeln(
      'Live2D ${mode.name} gate passed '
      '(${report.checkedArtifacts} artifacts checked).',
    );
    return;
  }
  stderr.writeln('Live2D ${mode.name} gate failed:');
  for (final error in report.errors) {
    stderr.writeln('- $error');
  }
  exitCode = 1;
}

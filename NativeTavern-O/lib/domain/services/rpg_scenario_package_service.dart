import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:yaml/yaml.dart';

enum RpgScenarioPackageFormat { json, yaml }

class RpgScenarioPackageLimits {
  final int maxBytes;
  final int maxDepth;
  final int maxNodes;
  final int maxStringLength;
  final int maxCollectionLength;

  const RpgScenarioPackageLimits({
    this.maxBytes = 2 * 1024 * 1024,
    this.maxDepth = 48,
    this.maxNodes = 50000,
    this.maxStringLength = 256 * 1024,
    this.maxCollectionLength = 5000,
  });
}

class RpgScenarioPackageIssue {
  final String path;
  final String code;
  final String message;
  final int? line;
  final int? column;

  const RpgScenarioPackageIssue({
    required this.path,
    required this.code,
    required this.message,
    this.line,
    this.column,
  });

  factory RpgScenarioPackageIssue.fromValidation(RpgValidationIssue issue) =>
      RpgScenarioPackageIssue(
        path: issue.path,
        code: issue.code,
        message: issue.message,
      );

  @override
  String toString() {
    final location = line == null ? '' : ' ($line:${column ?? 1})';
    return '$path$location [$code]: $message';
  }
}

class RpgScenarioPackageResult {
  final RpgScenario? scenario;
  final Map<String, dynamic>? document;
  final RpgScenarioPackageFormat format;
  final List<RpgScenarioPackageIssue> issues;

  const RpgScenarioPackageResult({
    required this.format,
    required this.issues,
    this.scenario,
    this.document,
  });

  bool get isValid => scenario != null && issues.isEmpty;
}

/// Parses untrusted, declarative RPG packages into the C01 domain contract.
///
/// The importer accepts JSON and a deliberately constrained YAML subset. YAML
/// anchors, aliases, merge keys, and custom tags are rejected before parsing so
/// a package cannot expand a small document into an unbounded object graph.
class RpgScenarioPackageService {
  static const supportedExtensions = <String>['json', 'yaml', 'yml'];

  final RpgScenarioPackageLimits limits;
  final String engineVersion;
  final Set<String> availableCapabilities;
  final RpgScenarioValidator _validator;

  const RpgScenarioPackageService({
    this.limits = const RpgScenarioPackageLimits(),
    this.engineVersion = RpgCompatibility.defaultEngineVersion,
    this.availableCapabilities = const {'core_rules'},
    RpgScenarioValidator validator = const RpgScenarioValidator(),
  }) : _validator = validator;

  RpgScenarioPackageResult importBytes(
    Uint8List bytes, {
    String? fileName,
  }) {
    final format = formatForFileName(fileName);
    if (bytes.length > limits.maxBytes) {
      return _failure(
        format,
        const RpgScenarioPackageIssue(
          path: r'$package',
          code: 'package_too_large',
          message: 'Scenario package exceeds the configured byte limit.',
        ),
      );
    }
    try {
      return importText(
        utf8.decode(bytes, allowMalformed: false),
        fileName: fileName,
        format: format,
      );
    } on FormatException catch (error) {
      return _failure(
        format,
        RpgScenarioPackageIssue(
          path: r'$package',
          code: 'invalid_encoding',
          message: error.message,
        ),
      );
    }
  }

  /// Runs parsing and validation outside the UI isolate for imported files.
  Future<RpgScenarioPackageResult> importBytesAsync(
    Uint8List bytes, {
    String? fileName,
  }) =>
      Isolate.run(() => importBytes(bytes, fileName: fileName));

  RpgScenarioPackageResult importText(
    String source, {
    String? fileName,
    RpgScenarioPackageFormat? format,
  }) {
    final resolvedFormat = format ?? detectFormat(source, fileName: fileName);
    if (utf8.encode(source).length > limits.maxBytes) {
      return _failure(
        resolvedFormat,
        const RpgScenarioPackageIssue(
          path: r'$package',
          code: 'package_too_large',
          message: 'Scenario package exceeds the configured byte limit.',
        ),
      );
    }

    Object? decoded;
    try {
      if (resolvedFormat == RpgScenarioPackageFormat.json) {
        decoded = jsonDecode(source);
      } else {
        final unsafe = _findUnsafeYamlFeature(source);
        if (unsafe != null) {
          return _failure(resolvedFormat, unsafe);
        }
        decoded = _yamlToJson(loadYaml(source));
      }
    } on YamlException catch (error) {
      return _failure(
        resolvedFormat,
        RpgScenarioPackageIssue(
          path: r'$package',
          code: 'invalid_yaml',
          message: error.message,
          line: error.span?.start.line == null
              ? null
              : error.span!.start.line + 1,
          column: error.span?.start.column == null
              ? null
              : error.span!.start.column + 1,
        ),
      );
    } on FormatException catch (error) {
      return _failure(
        resolvedFormat,
        _syntaxIssue(error, resolvedFormat),
      );
    } catch (error) {
      return _failure(
        resolvedFormat,
        RpgScenarioPackageIssue(
          path: r'$package',
          code: 'invalid_package',
          message: 'Could not parse scenario package: $error',
        ),
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return _failure(
        resolvedFormat,
        const RpgScenarioPackageIssue(
          path: r'$package',
          code: 'invalid_root',
          message: 'Scenario package root must be an object.',
        ),
      );
    }

    final resourceIssues = _inspectResources(decoded);
    final schemaIssues = _schema.validateDocument(decoded);
    final issues = <RpgScenarioPackageIssue>[
      ...resourceIssues,
      ...schemaIssues,
    ];
    if (issues.isNotEmpty) {
      return RpgScenarioPackageResult(
        format: resolvedFormat,
        document: decoded,
        issues: List.unmodifiable(issues),
      );
    }

    RpgScenario scenario;
    try {
      scenario = RpgScenario.fromJson(decoded);
    } catch (error) {
      return RpgScenarioPackageResult(
        format: resolvedFormat,
        document: decoded,
        issues: [
          RpgScenarioPackageIssue(
            path: r'$package',
            code: 'invalid_contract_value',
            message: 'Package contains an unsupported contract value: $error',
          ),
        ],
      );
    }

    issues.addAll(
      _validator
          .validate(scenario)
          .issues
          .map(RpgScenarioPackageIssue.fromValidation),
    );
    issues.addAll(_validateCompatibility(scenario));

    return RpgScenarioPackageResult(
      format: resolvedFormat,
      scenario: issues.isEmpty ? scenario : null,
      document: decoded,
      issues: List.unmodifiable(issues),
    );
  }

  String exportScenario(
    RpgScenario scenario, {
    RpgScenarioPackageFormat format = RpgScenarioPackageFormat.json,
  }) {
    final validationIssues = <RpgScenarioPackageIssue>[
      ..._validator
          .validate(scenario)
          .issues
          .map(RpgScenarioPackageIssue.fromValidation),
      ..._validateCompatibility(scenario),
    ];
    if (validationIssues.isNotEmpty) {
      throw RpgScenarioPackageException(validationIssues);
    }
    final document = scenario.toJson();
    return switch (format) {
      RpgScenarioPackageFormat.json =>
        const JsonEncoder.withIndent('  ').convert(document),
      RpgScenarioPackageFormat.yaml => _YamlWriter().write(document),
    };
  }

  RpgScenarioPackageFormat detectFormat(
    String source, {
    String? fileName,
  }) {
    final fromFileName = formatForFileName(fileName);
    if (fileName != null && fileName.contains('.')) return fromFileName;
    final trimmed = source.trimLeft();
    return trimmed.startsWith('{') || trimmed.startsWith('[')
        ? RpgScenarioPackageFormat.json
        : RpgScenarioPackageFormat.yaml;
  }

  RpgScenarioPackageFormat formatForFileName(String? fileName) {
    final normalized = fileName?.toLowerCase() ?? '';
    return normalized.endsWith('.yaml') || normalized.endsWith('.yml')
        ? RpgScenarioPackageFormat.yaml
        : RpgScenarioPackageFormat.json;
  }

  RpgScenarioPackageResult _failure(
    RpgScenarioPackageFormat format,
    RpgScenarioPackageIssue issue,
  ) =>
      RpgScenarioPackageResult(format: format, issues: [issue]);

  RpgScenarioPackageIssue _syntaxIssue(
    FormatException error,
    RpgScenarioPackageFormat format,
  ) {
    int? line;
    int? column;
    if (error.offset case final offset? when error.source is String) {
      final prefix = (error.source! as String).substring(0, offset);
      line = '\n'.allMatches(prefix).length + 1;
      final lastBreak = prefix.lastIndexOf('\n');
      column = offset - lastBreak;
    }
    return RpgScenarioPackageIssue(
      path: r'$package',
      code: format == RpgScenarioPackageFormat.json
          ? 'invalid_json'
          : 'invalid_yaml',
      message: error.message,
      line: line,
      column: column,
    );
  }

  List<RpgScenarioPackageIssue> _inspectResources(Object? root) {
    final issues = <RpgScenarioPackageIssue>[];
    var nodes = 0;

    void visit(Object? value, String path, int depth) {
      if (issues.isNotEmpty) return;
      nodes++;
      if (nodes > limits.maxNodes) {
        issues.add(RpgScenarioPackageIssue(
          path: path,
          code: 'too_many_nodes',
          message: 'Scenario package exceeds the configured node limit.',
        ));
        return;
      }
      if (depth > limits.maxDepth) {
        issues.add(RpgScenarioPackageIssue(
          path: path,
          code: 'nesting_too_deep',
          message: 'Scenario package exceeds the configured nesting limit.',
        ));
        return;
      }
      if (value is String && value.length > limits.maxStringLength) {
        issues.add(RpgScenarioPackageIssue(
          path: path,
          code: 'string_too_long',
          message: 'Text value exceeds the configured character limit.',
        ));
      } else if (value is List<dynamic>) {
        if (value.length > limits.maxCollectionLength) {
          issues.add(RpgScenarioPackageIssue(
            path: path,
            code: 'collection_too_large',
            message: 'List exceeds the configured item limit.',
          ));
          return;
        }
        for (var index = 0; index < value.length; index++) {
          visit(value[index], '$path[$index]', depth + 1);
        }
      } else if (value is Map<String, dynamic>) {
        if (value.length > limits.maxCollectionLength) {
          issues.add(RpgScenarioPackageIssue(
            path: path,
            code: 'collection_too_large',
            message: 'Object exceeds the configured property limit.',
          ));
          return;
        }
        for (final entry in value.entries) {
          if (_isUnsafeKey(entry.key)) {
            issues.add(RpgScenarioPackageIssue(
              path: '$path.${entry.key}',
              code: 'unsafe_property',
              message: 'Executable or file-path properties are not allowed.',
            ));
            return;
          }
          visit(entry.value, '$path.${entry.key}', depth + 1);
        }
      } else if (value is num && !value.isFinite) {
        issues.add(RpgScenarioPackageIssue(
          path: path,
          code: 'non_finite_number',
          message: 'Numbers must be finite.',
        ));
      }
    }

    visit(root, r'$package', 0);
    return issues;
  }

  bool _isUnsafeKey(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    return const {
      'script',
      'sourcecode',
      'executable',
      'command',
      'shell',
      'filepath',
      'absoluteuri',
    }.contains(normalized);
  }

  List<RpgScenarioPackageIssue> _validateCompatibility(RpgScenario scenario) {
    final issues = <RpgScenarioPackageIssue>[];
    final current = _SemanticVersion.tryParse(engineVersion);
    final minimum = _SemanticVersion.tryParse(
      scenario.compatibility.minimumEngineVersion,
    );
    final maximum = _SemanticVersion.tryParse(
      scenario.compatibility.maximumEngineVersion,
    );
    if (current != null && minimum != null && current < minimum) {
      issues.add(RpgScenarioPackageIssue(
        path: 'compatibility.minimumEngineVersion',
        code: 'incompatible_engine_version',
        message:
            'Package requires engine ${scenario.compatibility.minimumEngineVersion} '
            'or newer; this app provides $engineVersion.',
      ));
    }
    if (current != null && maximum != null && current > maximum) {
      issues.add(RpgScenarioPackageIssue(
        path: 'compatibility.maximumEngineVersion',
        code: 'incompatible_engine_version',
        message:
            'Package supports engine ${scenario.compatibility.maximumEngineVersion} '
            'or older; this app provides $engineVersion.',
      ));
    }
    for (var index = 0;
        index < scenario.compatibility.requiredCapabilities.length;
        index++) {
      final capability = scenario.compatibility.requiredCapabilities[index];
      if (!availableCapabilities.contains(capability)) {
        issues.add(RpgScenarioPackageIssue(
          path: 'compatibility.requiredCapabilities[$index]',
          code: 'missing_capability',
          message: 'Required capability `$capability` is not available.',
        ));
      }
    }
    return issues;
  }

  RpgScenarioPackageIssue? _findUnsafeYamlFeature(String source) {
    final lines = const LineSplitter().convert(source);
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      final line = _stripYamlComment(lines[lineIndex]);
      final token = RegExp(
        r'(^|[\s\[\]{},:?-])(?:&[A-Za-z0-9_-]+|\*[A-Za-z0-9_-]+|![^\s]+|<<\s*:)',
      ).firstMatch(line);
      if (token != null) {
        return RpgScenarioPackageIssue(
          path: r'$package',
          code: 'unsafe_yaml_feature',
          message:
              'YAML anchors, aliases, merge keys, and custom tags are not supported.',
          line: lineIndex + 1,
          column: token.start + 1,
        );
      }
    }
    return null;
  }

  String _stripYamlComment(String line) {
    var singleQuoted = false;
    var doubleQuoted = false;
    for (var index = 0; index < line.length; index++) {
      final char = line[index];
      if (char == "'" && !doubleQuoted) singleQuoted = !singleQuoted;
      if (char == '"' &&
          !singleQuoted &&
          (index == 0 || line[index - 1] != r'\')) {
        doubleQuoted = !doubleQuoted;
      }
      if (char == '#' && !singleQuoted && !doubleQuoted) {
        return line.substring(0, index);
      }
    }
    return line;
  }

  Object? _yamlToJson(Object? value) {
    if (value is YamlMap) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const FormatException('YAML object keys must be strings.');
        }
        result[entry.key as String] = _yamlToJson(entry.value);
      }
      return result;
    }
    if (value is YamlList) {
      return value.map(_yamlToJson).toList(growable: false);
    }
    if (value == null || value is String || value is bool || value is num) {
      return value;
    }
    throw FormatException('Unsupported YAML value `${value.runtimeType}`.');
  }
}

class RpgScenarioPackageException implements Exception {
  final List<RpgScenarioPackageIssue> issues;

  const RpgScenarioPackageException(this.issues);

  @override
  String toString() => 'Invalid RPG scenario package:\n${issues.join('\n')}';
}

class _SemanticVersion implements Comparable<_SemanticVersion> {
  final int major;
  final int minor;
  final int patch;

  const _SemanticVersion(this.major, this.minor, this.patch);

  static _SemanticVersion? tryParse(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(value);
    if (match == null) return null;
    return _SemanticVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  @override
  int compareTo(_SemanticVersion other) {
    final majorComparison = major.compareTo(other.major);
    if (majorComparison != 0) return majorComparison;
    final minorComparison = minor.compareTo(other.minor);
    if (minorComparison != 0) return minorComparison;
    return patch.compareTo(other.patch);
  }

  bool operator <(_SemanticVersion other) => compareTo(other) < 0;
  bool operator >(_SemanticVersion other) => compareTo(other) > 0;
}

class _YamlWriter {
  String write(Map<String, dynamic> value) {
    final buffer = StringBuffer();
    _writeMap(buffer, value, 0);
    return buffer.toString();
  }

  void _writeMap(StringBuffer buffer, Map<String, dynamic> map, int indent) {
    for (final entry in map.entries) {
      buffer.write('${' ' * indent}${jsonEncode(entry.key)}:');
      if (_isScalar(entry.value)) {
        buffer.writeln(' ${_scalar(entry.value)}');
      } else if (entry.value is List && (entry.value as List).isEmpty) {
        buffer.writeln(' []');
      } else if (entry.value is Map && (entry.value as Map).isEmpty) {
        buffer.writeln(' {}');
      } else {
        buffer.writeln();
        _writeValue(buffer, entry.value, indent + 2);
      }
    }
  }

  void _writeValue(StringBuffer buffer, Object? value, int indent) {
    if (value is Map<String, dynamic>) {
      _writeMap(buffer, value, indent);
    } else if (value is List<dynamic>) {
      for (final item in value) {
        if (_isScalar(item)) {
          buffer.writeln('${' ' * indent}- ${_scalar(item)}');
        } else {
          buffer.writeln('${' ' * indent}-');
          _writeValue(buffer, item, indent + 2);
        }
      }
    }
  }

  bool _isScalar(Object? value) =>
      value == null || value is String || value is bool || value is num;

  String _scalar(Object? value) {
    if (value == null) return 'null';
    if (value is String) return jsonEncode(value);
    return value.toString();
  }
}

final _schema = _ObjectSchema(
  fields: {
    'schemaVersion': _required(_integer),
    'metadata': _required(_ObjectSchema(fields: {
      'id': _required(_string),
      'name': _required(_string),
      'version': _required(_string),
      'description': _optional(_string),
      'author': _optional(_string),
      'tags': _optional(_list(_string)),
    })),
    'initialSeed': _required(_integer),
    'compatibility': _optional(_ObjectSchema(fields: {
      'minimumEngineVersion': _optional(_string),
      'maximumEngineVersion': _optional(_string),
      'requiredCapabilities': _optional(_list(_string)),
    })),
    'protectedFields': _optional(_list(_string)),
    'attributes': _optional(_list(_ObjectSchema(fields: {
      'id': _required(_string),
      'label': _required(_string),
      'initialValue': _optional(_number),
      'minimum': _optional(_number),
      'maximum': _optional(_number),
    }))),
    'items': _optional(_list(_ObjectSchema(fields: {
      'id': _required(_string),
      'label': _required(_string),
      'description': _optional(_string),
      'stackable': _optional(_boolean),
    }))),
    'actors': _optional(_list(_ObjectSchema(fields: {
      'id': _required(_string),
      'label': _required(_string),
    }))),
    'locations': _optional(_list(_ObjectSchema(fields: {
      'id': _required(_string),
      'label': _required(_string),
      'description': _optional(_string),
    }))),
    'quests': _optional(_list(_quest)),
    'actions': _optional(_list(_action)),
    'initialState': _required(_runtimeState),
  },
);

final _quest = _ObjectSchema(fields: {
  'id': _required(_string),
  'label': _required(_string),
  'stages': _optional(_list(_ObjectSchema(fields: {
    'id': _required(_string),
    'label': _required(_string),
    'objectiveIds': _optional(_list(_string)),
  }))),
});

_ObjectSchema _conditionSchema() => _ObjectSchema(fields: {
      'operator':
          _required(_enum(RpgConditionOperator.values.map((e) => e.name))),
      'path': _optional(_string),
      'value': _optional(_jsonValue),
      'conditions': _optional(const _ListSchema.lazy(_conditionSchema)),
    });

final _effect = _ObjectSchema(fields: {
  'type': _required(_enum(RpgEffectType.values.map((e) => e.name))),
  'target': _required(_string),
  'value': _optional(_jsonValue),
  'amount': _optional(_number),
});

final _action = _ObjectSchema(fields: {
  'id': _required(_string),
  'label': _required(_string),
  'description': _optional(_string),
  'availability': _optional(_list(_conditionSchema())),
  'costs': _optional(_list(_ObjectSchema(fields: {
    'path': _required(_string),
    'amount': _required(_number),
  }))),
  'check': _optional(_ObjectSchema(fields: {
    'attributeId': _required(_string),
    'dice': _required(_ObjectSchema(fields: {
      'expression': _required(_string),
    })),
    'difficulty': _required(_number),
    'successEffects': _optional(_list(_effect)),
    'failureEffects': _optional(_list(_effect)),
  })),
  'effects': _optional(_list(_effect)),
});

final _runtimeState = _ObjectSchema(fields: {
  'scenarioId': _required(_string),
  'scenarioVersion': _required(_string),
  'turn': _optional(_integer),
  'random': _required(_ObjectSchema(fields: {
    'initialSeed': _required(_integer),
    'state': _required(_integer),
    'rollsConsumed': _optional(_integer),
  })),
  'attributes': _optional(const _MapSchema(_number)),
  'variables': _optional(const _MapSchema(_jsonValue)),
  'inventory': _optional(_list(_ObjectSchema(fields: {
    'itemId': _required(_string),
    'quantity': _required(_integer),
    'metadata': _optional(const _MapSchema(_jsonValue)),
  }))),
  'relationships': _optional(_list(_ObjectSchema(fields: {
    'actorId': _required(_string),
    'score': _optional(_number),
    'tags': _optional(_list(_string)),
  }))),
  'clock': _optional(_ObjectSchema(fields: {
    'elapsedMinutes': _optional(_integer),
    'day': _optional(_integer),
    'minuteOfDay': _optional(_integer),
  })),
  'locationId': _optional(_string),
  'quests': _optional(_list(_ObjectSchema(fields: {
    'questId': _required(_string),
    'status': _optional(_enum(RpgQuestStatus.values.map((e) => e.name))),
    'stageId': _optional(_string),
    'objectiveProgress': _optional(const _MapSchema(_integer)),
  }))),
  'cooldowns': _optional(const _MapSchema(_integer)),
  'eventHistory': _optional(_list(_ObjectSchema(fields: {
    'id': _required(_string),
    'turn': _required(_integer),
    'type': _required(_string),
    'actionId': _optional(_string),
    'summary': _optional(_string),
    'data': _optional(const _MapSchema(_jsonValue)),
  }))),
});

_SchemaField _required(_ValueSchema schema) => _SchemaField(schema, true);
_SchemaField _optional(_ValueSchema schema) => _SchemaField(schema, false);
_ListSchema _list(_ValueSchema schema) => _ListSchema(schema);
_ScalarSchema _enum(Iterable<String> values) =>
    _ScalarSchema(_ScalarType.string, values.toSet());

const _string = _ScalarSchema(_ScalarType.string);
const _number = _ScalarSchema(_ScalarType.number);
const _integer = _ScalarSchema(_ScalarType.integer);
const _boolean = _ScalarSchema(_ScalarType.boolean);
const _jsonValue = _JsonValueSchema();

enum _ScalarType { string, number, integer, boolean }

abstract class _ValueSchema {
  const _ValueSchema();
  void validate(
    Object? value,
    String path,
    List<RpgScenarioPackageIssue> issues,
  );
}

class _SchemaField {
  final _ValueSchema schema;
  final bool required;
  const _SchemaField(this.schema, this.required);
}

class _ObjectSchema extends _ValueSchema {
  final Map<String, _SchemaField> fields;
  const _ObjectSchema({required this.fields});

  List<RpgScenarioPackageIssue> validateDocument(Map<String, dynamic> value) {
    final issues = <RpgScenarioPackageIssue>[];
    validateAt(value, r'$package', issues);
    return issues;
  }

  @override
  void validate(
          Object? value, String path, List<RpgScenarioPackageIssue> issues) =>
      validateAt(value, path, issues);

  void validateAt(
    Object? value,
    String path,
    List<RpgScenarioPackageIssue> issues,
  ) {
    if (value is! Map<String, dynamic>) {
      _typeIssue(path, 'object', issues);
      return;
    }
    for (final field in fields.entries) {
      if (!value.containsKey(field.key)) {
        if (field.value.required) {
          issues.add(RpgScenarioPackageIssue(
            path: '$path.${field.key}',
            code: 'missing_required_field',
            message: 'Required field `${field.key}` is missing.',
          ));
        }
        continue;
      }
      final child = value[field.key];
      if (child == null && !field.value.required) continue;
      field.value.schema.validate(child, '$path.${field.key}', issues);
    }
    for (final key in value.keys) {
      if (!fields.containsKey(key)) {
        issues.add(RpgScenarioPackageIssue(
          path: '$path.$key',
          code: 'unknown_field',
          message: 'Field `$key` is not part of the RPG scenario schema.',
        ));
      }
    }
  }
}

class _ListSchema extends _ValueSchema {
  final _ValueSchema? item;
  final _ValueSchema Function()? _itemBuilder;
  const _ListSchema(this.item) : _itemBuilder = null;
  const _ListSchema.lazy(this._itemBuilder) : item = null;

  @override
  void validate(
      Object? value, String path, List<RpgScenarioPackageIssue> issues) {
    if (value is! List<dynamic>) {
      _typeIssue(path, 'list', issues);
      return;
    }
    final itemSchema = item ?? _itemBuilder!();
    for (var index = 0; index < value.length; index++) {
      itemSchema.validate(value[index], '$path[$index]', issues);
    }
  }
}

class _MapSchema extends _ValueSchema {
  final _ValueSchema valueSchema;
  const _MapSchema(this.valueSchema);

  @override
  void validate(
      Object? value, String path, List<RpgScenarioPackageIssue> issues) {
    if (value is! Map<String, dynamic>) {
      _typeIssue(path, 'object', issues);
      return;
    }
    for (final entry in value.entries) {
      valueSchema.validate(entry.value, '$path.${entry.key}', issues);
    }
  }
}

class _ScalarSchema extends _ValueSchema {
  final _ScalarType type;
  final Set<String>? values;
  const _ScalarSchema(this.type, [this.values]);

  @override
  void validate(
      Object? value, String path, List<RpgScenarioPackageIssue> issues) {
    final valid = switch (type) {
      _ScalarType.string => value is String,
      _ScalarType.number => value is num,
      _ScalarType.integer =>
        value is int || value is num && value == value.toInt(),
      _ScalarType.boolean => value is bool,
    };
    if (!valid) {
      _typeIssue(path, type.name, issues);
      return;
    }
    if (values != null && !values!.contains(value)) {
      issues.add(RpgScenarioPackageIssue(
        path: path,
        code: 'invalid_enum_value',
        message: 'Value must be one of: ${values!.join(', ')}.',
      ));
    }
  }
}

class _JsonValueSchema extends _ValueSchema {
  const _JsonValueSchema();

  @override
  void validate(
      Object? value, String path, List<RpgScenarioPackageIssue> issues) {
    if (value == null || value is String || value is bool || value is num) {
      return;
    }
    if (value is List<dynamic>) {
      for (var index = 0; index < value.length; index++) {
        validate(value[index], '$path[$index]', issues);
      }
      return;
    }
    if (value is Map<String, dynamic>) {
      for (final entry in value.entries) {
        validate(entry.value, '$path.${entry.key}', issues);
      }
      return;
    }
    _typeIssue(path, 'JSON value', issues);
  }
}

void _typeIssue(
  String path,
  String expected,
  List<RpgScenarioPackageIssue> issues,
) {
  issues.add(RpgScenarioPackageIssue(
    path: path,
    code: 'invalid_field_type',
    message: 'Expected $expected.',
  ));
}

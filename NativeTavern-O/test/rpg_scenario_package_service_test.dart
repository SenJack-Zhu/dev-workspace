import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/rpg_scenario_draft_store.dart';
import 'package:native_tavern/domain/services/rpg_scenario_package_service.dart';
import 'package:native_tavern/presentation/controllers/rpg_scenario_editor_controller.dart';

void main() {
  group('RpgScenarioPackageService', () {
    const service = RpgScenarioPackageService();

    test('imports JSON and YAML through the same production contract', () {
      final jsonResult = service.importText(
        jsonEncode(_minimalDocument()),
        fileName: 'scenario.json',
      );
      final yamlResult = service.importText(
        _minimalYaml,
        fileName: 'scenario.yaml',
      );

      expect(jsonResult.issues, isEmpty);
      expect(yamlResult.issues, isEmpty);
      expect(yamlResult.scenario!.toJson(), jsonResult.scenario!.toJson());
      expect(yamlResult.format, RpgScenarioPackageFormat.yaml);
    });

    test('exports lossless canonical JSON and YAML', () {
      final scenario = service
          .importText(jsonEncode(_fullDocument()), fileName: 'full.json')
          .scenario!;

      for (final format in RpgScenarioPackageFormat.values) {
        final encoded = service.exportScenario(scenario, format: format);
        final decoded = service.importText(
          encoded,
          fileName: format == RpgScenarioPackageFormat.json
              ? 'round_trip.json'
              : 'round_trip.yaml',
        );

        expect(decoded.issues, isEmpty, reason: decoded.issues.join('\n'));
        expect(decoded.scenario!.toJson(), scenario.toJson());
      }
    });

    test('reports structural errors at the exact field', () {
      final document = _minimalDocument();
      (document['metadata'] as Map<String, dynamic>)['name'] = 42;

      final result = service.importText(jsonEncode(document));

      expect(result.isValid, isFalse);
      expect(
        result.issues,
        contains(isA<RpgScenarioPackageIssue>()
            .having((issue) => issue.path, 'path', r'$package.metadata.name')
            .having(
              (issue) => issue.code,
              'code',
              'invalid_field_type',
            )),
      );
    });

    test('rejects unsupported versions and missing capabilities', () {
      final document = _minimalDocument();
      document['schemaVersion'] = 2;
      document['compatibility'] = {
        'minimumEngineVersion': '2.0.0',
        'requiredCapabilities': ['network_scripts'],
      };

      final result = service.importText(jsonEncode(document));
      final codes = result.issues.map((issue) => issue.code).toSet();

      expect(codes, contains('unsupported_schema_version'));
      expect(codes, contains('incompatible_engine_version'));
      expect(codes, contains('missing_capability'));
    });

    test('rejects executable fields and risky YAML features', () {
      final document = _minimalDocument();
      document['actions'] = <dynamic>[];
      (document['actions'] as List<dynamic>).add({
        'id': 'unsafe',
        'label': 'Unsafe',
        'script': 'rm -rf /',
      });

      final executable = service.importText(jsonEncode(document));
      final alias = service.importText(
        '${_minimalYaml}extra: &payload [1, 2]\ncopy: *payload\n',
        fileName: 'unsafe.yaml',
      );

      expect(executable.issues.map((issue) => issue.code),
          contains('unsafe_property'));
      expect(alias.issues.single.code, 'unsafe_yaml_feature');
      expect(alias.issues.single.line, isNotNull);
    });

    test('enforces byte, depth, and collection limits before conversion', () {
      const limited = RpgScenarioPackageService(
        limits: RpgScenarioPackageLimits(
          maxBytes: 200,
          maxDepth: 3,
          maxNodes: 20,
          maxCollectionLength: 2,
        ),
      );

      final bytes = limited.importBytes(
        Uint8List.fromList(List<int>.filled(201, 0x20)),
      );
      final depth = const RpgScenarioPackageService(
        limits: RpgScenarioPackageLimits(maxDepth: 2),
      ).importText(jsonEncode(_minimalDocument()));
      final collection = const RpgScenarioPackageService(
        limits: RpgScenarioPackageLimits(maxCollectionLength: 1),
      ).importText(jsonEncode(_minimalDocument()));

      expect(bytes.issues.single.code, 'package_too_large');
      expect(depth.issues.single.code, 'nesting_too_deep');
      expect(collection.issues.single.code, 'collection_too_large');
    });

    test('malformed JSON includes a source location', () {
      final result = service.importText('{"schemaVersion": 1,}');

      expect(result.issues.single.code, 'invalid_json');
      expect(result.issues.single.line, 1);
      expect(result.issues.single.column, isNotNull);
    });

    test('reports invalid references from the production validator', () {
      final document = _minimalDocument();
      document['actions'] = [
        {
          'id': 'leave',
          'label': 'Leave',
          'effects': [
            {'type': 'moveTo', 'target': 'missing_location'},
          ],
        },
      ];

      final result = service.importText(jsonEncode(document));

      expect(
        result.issues,
        contains(isA<RpgScenarioPackageIssue>()
            .having(
              (issue) => issue.path,
              'path',
              'actions[0].effects[0]',
            )
            .having((issue) => issue.code, 'code', 'invalid_reference')),
      );
    });

    test('async file import returns the same validated package', () async {
      final source = '${jsonEncode(_minimalDocument())}${' ' * 512000}';

      final result = await service.importBytesAsync(
        Uint8List.fromList(utf8.encode(source)),
        fileName: 'large.json',
      );

      expect(result.issues, isEmpty);
      expect(result.scenario!.metadata.id, 'test_scenario');
    });
  });

  group('RpgScenarioEditorController', () {
    test(
        'edits every document through validation and exports a reimportable pack',
        () {
      final controller = RpgScenarioEditorController();

      controller.update(
        const RpgEditorPath(['metadata', 'id']),
        'edited_scenario',
      );
      controller.addListItem(const RpgEditorPath(['attributes']));
      controller.update(
        const RpgEditorPath(['attributes', 0, 'id']),
        'courage',
      );
      controller.update(
        const RpgEditorPath(['attributes', 0, 'label']),
        'Courage',
      );
      controller.setMapEntry(
        const RpgEditorPath(['initialState', 'attributes']),
        'courage',
        5,
      );
      controller.addListItem(const RpgEditorPath(['actions']));
      controller.update(
        const RpgEditorPath(['actions', 0, 'id']),
        'press_on',
      );
      controller.update(
        const RpgEditorPath(['actions', 0, 'label']),
        'Press On',
      );
      controller.initializeOptional(
        const RpgEditorPath(['actions', 0, 'check']),
      );
      controller.update(
        const RpgEditorPath(['actions', 0, 'check', 'attributeId']),
        'courage',
      );

      expect(
        controller.valueAt(
          const RpgEditorPath(['initialState', 'scenarioId']),
        ),
        'edited_scenario',
      );
      expect(controller.issues, isEmpty, reason: controller.issues.join('\n'));

      final exported = controller.export(format: RpgScenarioPackageFormat.yaml);
      final reimported = const RpgScenarioPackageService().importText(
        exported,
        fileName: 'edited.yaml',
      );
      expect(reimported.issues, isEmpty, reason: reimported.issues.join('\n'));
      expect(reimported.scenario!.attributes.single.id, 'courage');
      expect(reimported.scenario!.actions.single.check!.attributeId, 'courage');
    });

    test('saves and restores an invalid in-progress draft atomically',
        () async {
      final root = await Directory.systemTemp.createTemp('rpg-draft-test-');
      addTearDown(() => root.delete(recursive: true));
      final store = FileRpgScenarioDraftStore(root);
      final original = RpgScenarioEditorController(draftStore: store);
      original.update(const RpgEditorPath(['metadata', 'name']), 'Draft Name');
      original.update(const RpgEditorPath(['metadata', 'id']), 'not valid');

      await original.saveDraft();
      final restored = RpgScenarioEditorController(draftStore: store);

      expect(await restored.loadDraft(), isTrue);
      expect(
        restored.valueAt(const RpgEditorPath(['metadata', 'name'])),
        'Draft Name',
      );
      expect(restored.isValid, isFalse);
      expect(restored.draftUpdatedAt, isNotNull);
    });
  });
}

Map<String, dynamic> _minimalDocument() => {
      'schemaVersion': 1,
      'metadata': <String, dynamic>{
        'id': 'test_scenario',
        'name': 'Test Scenario',
        'version': '1.0.0',
      },
      'initialSeed': 7,
      'initialState': <String, dynamic>{
        'scenarioId': 'test_scenario',
        'scenarioVersion': '1.0.0',
        'random': <String, dynamic>{'initialSeed': 7, 'state': 7},
      },
    };

Map<String, dynamic> _fullDocument() {
  final document = _minimalDocument();
  document['compatibility'] = {
    'minimumEngineVersion': '1.0.0',
    'requiredCapabilities': ['core_rules'],
  };
  document['attributes'] = [
    {
      'id': 'courage',
      'label': 'Courage',
      'initialValue': 4,
      'minimum': 0,
      'maximum': 10,
    },
  ];
  document['items'] = [
    {'id': 'torch', 'label': 'Torch'},
  ];
  document['locations'] = [
    {'id': 'gate', 'label': 'Gate'},
  ];
  document['actions'] = [
    {
      'id': 'advance',
      'label': 'Advance',
      'availability': [
        {'operator': 'greaterThan', 'path': 'attributes.courage', 'value': 0},
      ],
      'effects': [
        {'type': 'moveTo', 'target': 'gate'},
      ],
    },
  ];
  final state = document['initialState'] as Map<String, dynamic>;
  state['attributes'] = {'courage': 4};
  state['inventory'] = [
    {'itemId': 'torch', 'quantity': 1},
  ];
  state['locationId'] = 'gate';
  return document;
}

const _minimalYaml = '''
schemaVersion: 1
metadata:
  id: test_scenario
  name: Test Scenario
  version: 1.0.0
initialSeed: 7
initialState:
  scenarioId: test_scenario
  scenarioVersion: 1.0.0
  random:
    initialSeed: 7
    state: 7
''';

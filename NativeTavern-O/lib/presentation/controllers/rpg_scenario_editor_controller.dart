import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/domain/services/rpg_scenario_draft_store.dart';
import 'package:native_tavern/domain/services/rpg_scenario_package_service.dart';

class RpgEditorPath {
  final List<Object> segments;

  const RpgEditorPath([this.segments = const []]);

  RpgEditorPath child(Object segment) => RpgEditorPath([...segments, segment]);

  String get key => segments.map((segment) => '/$segment').join();

  String get normalized =>
      segments.map((segment) => segment is int ? '/*' : '/$segment').join();

  String get display => segments.isEmpty
      ? r'$package'
      : segments.fold<String>(r'$package', (path, segment) {
          return segment is int ? '$path[$segment]' : '$path.$segment';
        });
}

class RpgScenarioEditorController extends ChangeNotifier {
  final RpgScenarioPackageService packageService;
  RpgScenarioDraftStore? draftStore;

  late Map<String, dynamic> _document;
  late RpgScenarioPackageResult _validation;
  RpgScenarioPackageFormat _format;
  List<RpgScenarioPackageIssue> _importIssues = const [];
  DateTime? _draftUpdatedAt;
  bool _dirty = false;

  RpgScenarioEditorController({
    RpgScenario? initialScenario,
    this.packageService = const RpgScenarioPackageService(),
    this.draftStore,
    RpgScenarioPackageFormat format = RpgScenarioPackageFormat.json,
  }) : _format = format {
    _document = _materialize(
      _deepMap((initialScenario ?? emptyScenario()).toJson()),
    );
    _validation = _validateDocument();
  }

  Map<String, dynamic> get document => _document;
  RpgScenarioPackageFormat get format => _format;
  List<RpgScenarioPackageIssue> get issues =>
      _importIssues.isEmpty ? _validation.issues : _importIssues;
  RpgScenario? get scenario => _validation.scenario;
  DateTime? get draftUpdatedAt => _draftUpdatedAt;
  bool get isValid => _validation.isValid;
  bool get isDirty => _dirty;

  static RpgScenario emptyScenario() => const RpgScenario(
        metadata: RpgScenarioMetadata(
          id: 'new_scenario',
          name: 'New Scenario',
          version: '1.0.0',
        ),
        initialSeed: 1,
        initialState: RpgRuntimeState(
          scenarioId: 'new_scenario',
          scenarioVersion: '1.0.0',
          random: RpgRandomState(initialSeed: 1, state: 1),
        ),
      );

  RpgScenarioPackageResult importText(
    String source, {
    String? fileName,
  }) {
    final result = packageService.importText(source, fileName: fileName);
    _handleImportResult(result);
    return result;
  }

  RpgScenarioPackageResult importBytes(
    Uint8List bytes, {
    String? fileName,
  }) {
    final result = packageService.importBytes(bytes, fileName: fileName);
    _handleImportResult(result);
    return result;
  }

  Future<RpgScenarioPackageResult> importBytesAsync(
    Uint8List bytes, {
    String? fileName,
  }) async {
    final result = await packageService.importBytesAsync(
      bytes,
      fileName: fileName,
    );
    _handleImportResult(result);
    return result;
  }

  void update(RpgEditorPath path, Object? value) {
    final previous = valueAt(path);
    _write(path, _deepValue(value));
    if (path.key == '/metadata/id' &&
        valueAt(const RpgEditorPath(['initialState', 'scenarioId'])) ==
            previous) {
      _write(const RpgEditorPath(['initialState', 'scenarioId']), value);
    } else if (path.key == '/metadata/version' &&
        valueAt(const RpgEditorPath(['initialState', 'scenarioVersion'])) ==
            previous) {
      _write(const RpgEditorPath(['initialState', 'scenarioVersion']), value);
    } else if (path.key == '/initialSeed') {
      final random = valueAt(
        const RpgEditorPath(['initialState', 'random']),
      ) as Map<String, dynamic>;
      if (random['initialSeed'] == previous) random['initialSeed'] = value;
      if (random['state'] == previous) random['state'] = value;
    }
    _changed();
  }

  void configureDraftStore(RpgScenarioDraftStore store) {
    draftStore = store;
  }

  void initializeOptional(RpgEditorPath path) {
    update(path, _optionalDefault(path.normalized));
  }

  void addListItem(RpgEditorPath path) {
    final list = valueAt(path);
    if (list is! List<dynamic>) {
      throw ArgumentError('Path ${path.display} is not a list.');
    }
    list.add(_deepValue(_templateFor(path.normalized)));
    _changed();
  }

  void removeListItem(RpgEditorPath path, int index) {
    final list = valueAt(path);
    if (list is! List<dynamic>) {
      throw ArgumentError('Path ${path.display} is not a list.');
    }
    list.removeAt(index);
    _changed();
  }

  void moveListItem(RpgEditorPath path, int oldIndex, int newIndex) {
    final list = valueAt(path);
    if (list is! List<dynamic>) {
      throw ArgumentError('Path ${path.display} is not a list.');
    }
    if (newIndex < 0 || newIndex >= list.length || oldIndex == newIndex) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    _changed();
  }

  void setMapEntry(RpgEditorPath path, String key, Object? value) {
    final map = valueAt(path);
    if (map is! Map<String, dynamic>) {
      throw ArgumentError('Path ${path.display} is not an object.');
    }
    map[key] = _deepValue(value);
    _changed();
  }

  void removeMapEntry(RpgEditorPath path, String key) {
    final map = valueAt(path);
    if (map is! Map<String, dynamic>) {
      throw ArgumentError('Path ${path.display} is not an object.');
    }
    map.remove(key);
    _changed();
  }

  Object? valueAt(RpgEditorPath path) {
    Object? current = _document;
    for (final segment in path.segments) {
      current = segment is int
          ? (current as List<dynamic>)[segment]
          : (current as Map<String, dynamic>)[segment];
    }
    return current;
  }

  String preview() => const JsonEncoder.withIndent('  ').convert(_document);

  String export({RpgScenarioPackageFormat? format}) {
    final currentScenario = scenario;
    if (currentScenario == null) {
      throw RpgScenarioPackageException(issues);
    }
    return packageService.exportScenario(
      currentScenario,
      format: format ?? _format,
    );
  }

  Future<void> saveDraft() async {
    final store = draftStore;
    if (store == null) {
      throw StateError('No RPG scenario draft store is configured.');
    }
    final updatedAt = DateTime.now().toUtc();
    await store.save(RpgScenarioDraft(
      document: _deepMap(_document),
      format: _format,
      updatedAt: updatedAt,
    ));
    _draftUpdatedAt = updatedAt;
    _dirty = false;
    notifyListeners();
  }

  Future<bool> loadDraft() async {
    final draft = await draftStore?.load();
    if (draft == null) return false;
    _document = _materialize(_deepMap(draft.document));
    _format = draft.format;
    _draftUpdatedAt = draft.updatedAt;
    _dirty = false;
    _validation = _validateDocument();
    notifyListeners();
    return true;
  }

  void _replaceFromResult(RpgScenarioPackageResult result) {
    _importIssues = const [];
    _document = _materialize(
      _deepMap(result.scenario!.toJson()),
    );
    _format = result.format;
    _validation = _validateDocument();
    _dirty = true;
    notifyListeners();
  }

  void _handleImportResult(RpgScenarioPackageResult result) {
    if (result.isValid) {
      _replaceFromResult(result);
      return;
    }
    _importIssues = result.issues;
    notifyListeners();
  }

  void _write(RpgEditorPath path, Object? value) {
    if (path.segments.isEmpty) {
      if (value is! Map<String, dynamic>) {
        throw ArgumentError('Document root must be an object.');
      }
      _document = value;
      return;
    }
    final parentPath = RpgEditorPath(
      path.segments.sublist(0, path.segments.length - 1),
    );
    final parent = valueAt(parentPath);
    final segment = path.segments.last;
    if (segment is int) {
      (parent as List<dynamic>)[segment] = value;
    } else {
      (parent as Map<String, dynamic>)[segment as String] = value;
    }
  }

  void _changed() {
    _importIssues = const [];
    _dirty = true;
    _validation = _validateDocument();
    notifyListeners();
  }

  RpgScenarioPackageResult _validateDocument() => packageService.importText(
        jsonEncode(_document),
        format: RpgScenarioPackageFormat.json,
      );
}

Object? _deepValue(Object? value) {
  if (value is Map<String, dynamic>) return _deepMap(value);
  if (value is List<dynamic>) return value.map(_deepValue).toList();
  return value;
}

Map<String, dynamic> _deepMap(Map<String, dynamic> value) => value.map(
      (key, item) => MapEntry(key, _deepValue(item)),
    );

Map<String, dynamic> _materialize(Map<String, dynamic> document) {
  void defaults(Map<String, dynamic> map, Map<String, dynamic> values) {
    for (final entry in values.entries) {
      map.putIfAbsent(entry.key, () => _deepValue(entry.value));
    }
  }

  final metadata = document['metadata'] as Map<String, dynamic>;
  defaults(metadata, {'description': '', 'author': '', 'tags': <dynamic>[]});
  final compatibility = document['compatibility'] as Map<String, dynamic>;
  defaults(compatibility, {
    'minimumEngineVersion': '1.0.0',
    'maximumEngineVersion': null,
    'requiredCapabilities': <dynamic>[],
  });
  for (final item in document['attributes'] as List<dynamic>) {
    defaults(item as Map<String, dynamic>, {
      'initialValue': 0,
      'minimum': null,
      'maximum': null,
    });
  }
  for (final item in document['items'] as List<dynamic>) {
    defaults(item as Map<String, dynamic>, {
      'description': '',
      'stackable': true,
    });
  }
  for (final item in document['locations'] as List<dynamic>) {
    defaults(item as Map<String, dynamic>, {'description': ''});
  }
  for (final item in document['quests'] as List<dynamic>) {
    final quest = item as Map<String, dynamic>;
    defaults(quest, {'stages': <dynamic>[]});
    for (final stageItem in quest['stages'] as List<dynamic>) {
      defaults(stageItem as Map<String, dynamic>, {
        'objectiveIds': <dynamic>[],
      });
    }
  }
  for (final item in document['actions'] as List<dynamic>) {
    _materializeAction(item as Map<String, dynamic>);
  }
  final state = document['initialState'] as Map<String, dynamic>;
  defaults(state, {
    'turn': 0,
    'attributes': <String, dynamic>{},
    'variables': <String, dynamic>{},
    'inventory': <dynamic>[],
    'relationships': <dynamic>[],
    'clock': {'elapsedMinutes': 0, 'day': 1, 'minuteOfDay': 0},
    'locationId': '',
    'quests': <dynamic>[],
    'cooldowns': <String, dynamic>{},
    'eventHistory': <dynamic>[],
  });
  defaults(state['random'] as Map<String, dynamic>, {'rollsConsumed': 0});
  for (final item in state['inventory'] as List<dynamic>) {
    defaults(item as Map<String, dynamic>, {'metadata': <String, dynamic>{}});
  }
  for (final item in state['relationships'] as List<dynamic>) {
    defaults(item as Map<String, dynamic>, {
      'score': 0,
      'tags': <dynamic>[],
    });
  }
  for (final item in state['quests'] as List<dynamic>) {
    defaults(item as Map<String, dynamic>, {
      'status': RpgQuestStatus.inactive.name,
      'stageId': null,
      'objectiveProgress': <String, dynamic>{},
    });
  }
  for (final item in state['eventHistory'] as List<dynamic>) {
    defaults(item as Map<String, dynamic>, {
      'actionId': null,
      'summary': '',
      'data': <String, dynamic>{},
    });
  }
  return document;
}

void _materializeAction(Map<String, dynamic> action) {
  action.putIfAbsent('description', () => '');
  action.putIfAbsent('availability', () => <dynamic>[]);
  action.putIfAbsent('costs', () => <dynamic>[]);
  action.putIfAbsent('check', () => null);
  action.putIfAbsent('effects', () => <dynamic>[]);
  for (final item in action['availability'] as List<dynamic>) {
    _materializeCondition(item as Map<String, dynamic>);
  }
  for (final item in action['effects'] as List<dynamic>) {
    _materializeEffect(item as Map<String, dynamic>);
  }
  final check = action['check'];
  if (check is Map<String, dynamic>) {
    check.putIfAbsent('successEffects', () => <dynamic>[]);
    check.putIfAbsent('failureEffects', () => <dynamic>[]);
    for (final key in ['successEffects', 'failureEffects']) {
      for (final item in check[key] as List<dynamic>) {
        _materializeEffect(item as Map<String, dynamic>);
      }
    }
  }
}

void _materializeCondition(Map<String, dynamic> condition) {
  condition.putIfAbsent('path', () => '');
  condition.putIfAbsent('value', () => null);
  condition.putIfAbsent('conditions', () => <dynamic>[]);
  for (final item in condition['conditions'] as List<dynamic>) {
    _materializeCondition(item as Map<String, dynamic>);
  }
}

void _materializeEffect(Map<String, dynamic> effect) {
  effect.putIfAbsent('value', () => null);
  effect.putIfAbsent('amount', () => null);
}

Object? _templateFor(String path) {
  if (path == '/metadata/tags' ||
      path == '/protectedFields' ||
      path.endsWith('/objectiveIds') ||
      path.endsWith('/tags')) {
    return '';
  }
  if (path == '/attributes') {
    return {
      'id': 'attribute',
      'label': 'Attribute',
      'initialValue': 0,
      'minimum': null,
      'maximum': null
    };
  }
  if (path == '/items') {
    return {
      'id': 'item',
      'label': 'Item',
      'description': '',
      'stackable': true
    };
  }
  if (path == '/actors') return {'id': 'actor', 'label': 'Actor'};
  if (path == '/locations') {
    return {'id': 'location', 'label': 'Location', 'description': ''};
  }
  if (path == '/quests') {
    return {'id': 'quest', 'label': 'Quest', 'stages': <dynamic>[]};
  }
  if (path.endsWith('/stages')) {
    return {'id': 'stage', 'label': 'Stage', 'objectiveIds': <dynamic>[]};
  }
  if (path == '/actions') {
    return {
      'id': 'action',
      'label': 'Action',
      'description': '',
      'availability': <dynamic>[],
      'costs': <dynamic>[],
      'check': null,
      'effects': <dynamic>[],
    };
  }
  if (path.endsWith('/availability') || path.endsWith('/conditions')) {
    return {
      'operator': RpgConditionOperator.equals.name,
      'path': '',
      'value': null,
      'conditions': <dynamic>[],
    };
  }
  if (path.endsWith('/costs')) return {'path': '', 'amount': 1};
  if (path.endsWith('/effects') ||
      path.endsWith('/successEffects') ||
      path.endsWith('/failureEffects')) {
    return {
      'type': RpgEffectType.setValue.name,
      'target': '',
      'value': null,
      'amount': null
    };
  }
  if (path == '/initialState/inventory') {
    return {'itemId': '', 'quantity': 1, 'metadata': <String, dynamic>{}};
  }
  if (path == '/initialState/relationships') {
    return {'actorId': '', 'score': 0, 'tags': <dynamic>[]};
  }
  if (path == '/initialState/quests') {
    return {
      'questId': '',
      'status': RpgQuestStatus.inactive.name,
      'stageId': null,
      'objectiveProgress': <String, dynamic>{}
    };
  }
  if (path == '/initialState/eventHistory') {
    return {
      'id': 'event',
      'turn': 0,
      'type': 'event',
      'actionId': null,
      'summary': '',
      'data': <String, dynamic>{}
    };
  }
  throw UnsupportedError('No editor template for $path.');
}

Object? _optionalDefault(String path) {
  if (path.endsWith('/check')) {
    return {
      'attributeId': '',
      'dice': {'expression': '1d20'},
      'difficulty': 10,
      'successEffects': <dynamic>[],
      'failureEffects': <dynamic>[],
    };
  }
  if (path.endsWith('/amount') ||
      path.endsWith('/minimum') ||
      path.endsWith('/maximum')) {
    return 0;
  }
  if (path.endsWith('/value') ||
      path.endsWith('/stageId') ||
      path.endsWith('/actionId')) {
    return '';
  }
  if (path.endsWith('/maximumEngineVersion')) return '1.0.0';
  return '';
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/rpg_scenario_draft_store.dart';
import 'package:native_tavern/domain/services/rpg_scenario_package_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/controllers/rpg_scenario_editor_controller.dart';
import 'package:native_tavern/presentation/screens/rpg/rpg_scenario_editor_screen.dart';

void main() {
  testWidgets('uses localized labels for the selected app locale',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RpgScenarioEditorScreen(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('RPG 剧本'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('元数据'), findsOneWidget);
    expect(find.byTooltip('导入剧本'), findsOneWidget);
  });

  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets('editor lays out without overflow at ${size.width.toInt()}px',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RpgScenarioEditorScreen(),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('rpg-import')), findsOneWidget);
      expect(find.byKey(const Key('rpg-tab-issues')), findsOneWidget);
    });
  }

  testWidgets('top-level scalar sections expand without PageStorage errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RpgScenarioEditorScreen(),
      ),
    );
    await tester.pumpAndSettle();

    const sections = {
      'Compatibility': 'rpg-field-/compatibility/minimumEngineVersion',
      'Initial State': 'rpg-field-/initialState/scenarioId',
    };
    final editorScroll = find
        .descendant(
          of: find.byKey(const PageStorageKey('rpg-document-editor')),
          matching: find.byType(Scrollable),
        )
        .first;
    for (final entry in sections.entries) {
      final header = find.text(entry.key);
      await tester.scrollUntilVisible(
        header,
        300,
        scrollable: editorScroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(Key(entry.value)), findsOneWidget);
    }
  });

  testWidgets('imports, edits, drafts, previews, exports, and reimports',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final draftStore = _MemoryDraftStore();
    final fileGateway = _FakeFileGateway(_yamlScenario);
    final controller = RpgScenarioEditorController(
      draftStore: draftStore,
      packageService: const _SynchronousPackageService(),
    );
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RpgScenarioEditorScreen(
        controller: controller,
        draftStore: draftStore,
        fileGateway: fileGateway,
      ),
    ));

    await tester.tap(find.byKey(const Key('rpg-import')));
    await tester.pumpAndSettle();
    expect(controller.scenario!.metadata.name, 'Imported Scenario');

    final nameField = find.byKey(const Key('rpg-field-/metadata/name'));
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, 'Edited Scenario');
    await tester.pumpAndSettle();

    final addAttribute = find.byKey(const Key('rpg-add-/attributes'));
    await Scrollable.ensureVisible(
      tester.element(addAttribute),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(addAttribute);
    await tester.pumpAndSettle();
    expect(controller.scenario!.attributes, hasLength(1));

    await tester.tap(find.byKey(const Key('rpg-save-draft')));
    await tester.pumpAndSettle();
    expect(draftStore.saved, isNotNull);
    expect(draftStore.saved!.document['metadata'],
        containsPair('name', 'Edited Scenario'));

    await tester.tap(find.byTooltip('Export scenario'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rpg-export-json')));
    await tester.pumpAndSettle();
    expect(fileGateway.savedContent, isNotNull);

    final reimported = const RpgScenarioPackageService().importText(
      fileGateway.savedContent!,
      fileName: 'round-trip.json',
    );
    expect(reimported.issues, isEmpty, reason: reimported.issues.join('\n'));
    expect(reimported.scenario!.metadata.name, 'Edited Scenario');

    await tester.tap(find.byKey(const Key('rpg-tab-preview')));
    await tester.pumpAndSettle();
    final preview = tester.widget<Text>(
      find.byKey(const Key('rpg-preview-source')),
    );
    expect(preview.data, contains('Edited Scenario'));
  });

  testWidgets('invalid import opens field-level issues without replacing draft',
      (tester) async {
    final controller = RpgScenarioEditorController(
      packageService: const _SynchronousPackageService(),
    );
    final original = controller.preview();
    final gateway = _FakeFileGateway('''
schemaVersion: 1
metadata:
  id: broken
  name: 42
  version: 1.0.0
initialSeed: 1
initialState:
  scenarioId: broken
  scenarioVersion: 1.0.0
  random: {initialSeed: 1, state: 1}
''');
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RpgScenarioEditorScreen(
        controller: controller,
        fileGateway: gateway,
      ),
    ));

    await tester.tap(find.byKey(const Key('rpg-import')));
    await tester.pumpAndSettle();

    expect(controller.preview(), original);
    expect(find.textContaining(r'$package.metadata.name'), findsOneWidget);
    expect(find.textContaining('Expected string'), findsOneWidget);
  });
}

class _FakeFileGateway implements RpgScenarioFileGateway {
  final String source;
  String? savedContent;

  _FakeFileGateway(this.source);

  @override
  Future<RpgScenarioFileData?> pickScenario() async => RpgScenarioFileData(
        name: 'scenario.yaml',
        bytes: utf8.encode(source),
      );

  @override
  Future<String?> saveScenario({
    required String suggestedName,
    required String content,
    required RpgScenarioPackageFormat format,
  }) async {
    savedContent = content;
    return '$suggestedName.${format.name}';
  }
}

class _SynchronousPackageService extends RpgScenarioPackageService {
  const _SynchronousPackageService();

  @override
  Future<RpgScenarioPackageResult> importBytesAsync(
    Uint8List bytes, {
    String? fileName,
  }) async =>
      importBytes(bytes, fileName: fileName);
}

class _MemoryDraftStore implements RpgScenarioDraftStore {
  RpgScenarioDraft? saved;

  @override
  Future<void> clear() async => saved = null;

  @override
  Future<RpgScenarioDraft?> load() async => saved;

  @override
  Future<void> save(RpgScenarioDraft draft) async => saved = draft;
}

const _yamlScenario = '''
schemaVersion: 1
metadata:
  id: imported_scenario
  name: Imported Scenario
  version: 1.0.0
initialSeed: 11
initialState:
  scenarioId: imported_scenario
  scenarioVersion: 1.0.0
  random:
    initialSeed: 11
    state: 11
''';

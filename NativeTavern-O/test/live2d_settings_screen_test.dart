import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_import_service.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/character_providers.dart';
import 'package:native_tavern/presentation/screens/settings/live2d_settings_screen.dart';

void main() {
  late Directory temporaryDirectory;
  late _FakeLive2DService modelService;
  late Live2DImportService importService;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'nt_live2d_settings',
    );
    modelService = _FakeLive2DService(temporaryDirectory.path);
    importService = Live2DImportService(
      dataPath: temporaryDirectory.path,
      modelService: modelService,
    );
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  testWidgets('missing legacy model stays selectable without loading a preview',
      (tester) async {
    final character = _legacyCharacter();

    await _pumpScreen(tester, character, modelService, importService);

    expect(tester.takeException(), isNull);
    expect(find.text('Zhaohe 3 (Unavailable)'), findsOneWidget);
    expect(
      find.text(
        'The assigned Live2D model is unavailable. Choose another model or '
        'import it again.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('live2d-model-error')), findsOneWidget);
    expect(modelService.loadedDefinitions, isEmpty);
  });

  testWidgets(
      'expired dropdown event does not throw and a valid load clears it',
      (tester) async {
    final character = _legacyCharacter();
    await _pumpScreen(tester, character, modelService, importService);

    var selector = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('live2d-model-selector')),
    );
    selector.onChanged!.call('removed-after-refresh');
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.text(
        'That Live2D model is no longer available. Choose another model or '
        'import it again.',
      ),
      findsOneWidget,
    );

    selector = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('live2d-model-selector')),
    );
    selector.onChanged!.call('hiyori_free');
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('live2d-model-error')), findsNothing);
    expect(modelService.loadedDefinitions.single.id, 'hiyori_free');
  });

  testWidgets(
      'preview ready callback does not setState while a child is building',
      (tester) async {
    var updates = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return GestureDetector(
              onTap: () {},
              child: Builder(
                builder: (context) {
                  scheduleLive2DEditorSetState(
                    mounted: true,
                    setState: setState,
                    fn: () => updates++,
                  );
                  return const Text('preview-child');
                },
              ),
            );
          },
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(updates, 1);
  });

  testWidgets('imported model management is collapsed by default',
      (tester) async {
    final character = _legacyCharacter();
    final imported = _FakeLive2DImportService(
      temporaryDirectory.path,
      modelService,
      const [
        Live2DModelDefinition(
          id: 'imported:z46:0',
          displayName: 'z46 4',
          modelDirectory: 'live2d_models/z46',
          modelFileName: 'z46_4.model3.json',
          source: Live2DModelSource.appData,
        ),
      ],
    );

    await _pumpScreen(tester, character, modelService, imported);

    expect(find.text('Imported models'), findsOneWidget);
    expect(find.text('1 model'), findsOneWidget);
    expect(find.text('z46_4.model3.json'), findsNothing);

    await tester.tap(find.text('Imported models'));
    await tester.pumpAndSettle();

    expect(find.text('z46_4.model3.json'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  Character character,
  Live2DService modelService,
  Live2DImportService importService,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        characterDetailProvider(character.id).overrideWith(
          (ref) async => character,
        ),
        live2DServiceProvider.overrideWithValue(modelService),
        live2DImportServiceProvider.overrideWithValue(importService),
      ],
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Live2DSettingsScreen(characterId: character.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Character _legacyCharacter() {
  final now = DateTime(2026, 8, 8);
  return Character(
    id: 'legacy-character',
    name: 'Legacy character',
    assets: const CharacterAssets(
      live2d: Live2DConfig(
        modelId: 'zhaohe_3',
        displayName: 'Zhaohe 3',
        modelDirectory: 'assets/live2d/zhaohe_3.zip/',
        modelFileName: 'zhaohe_3.model3.json',
      ),
    ),
    createdAt: now,
    modifiedAt: now,
  );
}

class _FakeLive2DService extends Live2DService {
  final List<Live2DModelDefinition> loadedDefinitions = [];

  _FakeLive2DService(String dataPath) : super(dataPath: dataPath);

  @override
  Future<Live2DModelManifest> loadManifest(
    Live2DModelDefinition definition,
  ) async {
    loadedDefinitions.add(definition);
    if (definition.format == Live2DModelFormat.spine) {
      return Live2DModelManifest(
        format: Live2DModelFormat.spine,
        version: 4,
        mocFile: '',
        textures: const ['preview.png'],
        atlasFileName: definition.atlasFileName,
      );
    }
    return const Live2DModelManifest(
      version: 3,
      mocFile: 'model.moc3',
      textures: ['texture.png'],
    );
  }

  @override
  Future<List<String>> findMissingFiles(
    Live2DModelDefinition definition,
    Live2DModelManifest manifest,
  ) async =>
      const [];
}

class _FakeLive2DImportService extends Live2DImportService {
  final List<Live2DModelDefinition> models;

  _FakeLive2DImportService(
    String dataPath,
    Live2DService modelService,
    this.models,
  ) : super(dataPath: dataPath, modelService: modelService);

  @override
  Future<List<Live2DModelDefinition>> listImportedModels() async => models;
}

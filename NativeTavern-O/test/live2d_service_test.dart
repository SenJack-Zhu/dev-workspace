import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_character_view.dart';
import 'package:path/path.dart' as p;

void main() {
  const service = Live2DService();

  group('bundled Live2D models', () {
    for (final definition in Live2DService.bundledModels) {
      test('${definition.id} manifest and references are valid', () {
        final modelFile = File(
          p.join(definition.modelDirectory, definition.modelFileName),
        );
        final manifest = service.parseManifest(modelFile.readAsStringSync());

        expect(manifest.version, 3);
        expect(manifest.mocFile, endsWith('.moc3'));
        expect(manifest.textures, isNotEmpty);
        expect(manifest.motions, isNotEmpty);
        expect(manifest.findMotion(const ['idle']), isNotNull);
        expect(manifest.hitAreas, isNotEmpty);
        expect(
          manifest.hitAreas.map((area) => area.kind),
          contains(Live2DHitAreaKind.body),
        );

        for (final reference in manifest.referencedFiles) {
          expect(
            File(p.join(definition.modelDirectory, reference)).existsSync(),
            isTrue,
            reason: '${definition.id} references missing file $reference',
          );
        }
      });
    }

    test('bundled model identifiers and paths are unique', () {
      const models = Live2DService.bundledModels;
      expect(models.map((model) => model.id).toSet(), hasLength(models.length));
      expect(
        models.map((model) => model.modelDirectory).toSet(),
        hasLength(models.length),
      );
      expect(models.map((model) => model.id), contains('hiyori_free'));
    });
  });

  test('Live2D character configuration round-trips through JSON', () {
    const motion = Live2DMotionRef(
      group: '',
      index: 3,
      file: 'motions/idle.motion3.json',
      name: 'idle',
      durationSeconds: 5,
      loop: true,
    );
    const config = Live2DConfig(
      modelId: 'hiyori_free',
      displayName: 'Hiyori Momose (Official Sample)',
      modelDirectory: 'assets/live2d/hiyori_free/',
      modelFileName: 'hiyori_free_t08.model3.json',
      scale: 1.2,
      offsetX: 0.1,
      idleMotion: motion,
      headTapMotion: motion,
      emotionMotions: {'happy': motion},
      hitAreas: [Live2DHitArea(id: 'Head', name: 'Head')],
    );

    final restored = Live2DConfig.fromJson(config.toJson());
    expect(restored.modelId, config.modelId);
    expect(restored.scale, config.scale);
    expect(restored.offsetX, config.offsetX);
    expect(restored.idleMotion?.group, '');
    expect(restored.idleMotion?.index, 3);
    expect(restored.idleMotion?.file, motion.file);
    expect(restored.idleMotion?.durationSeconds, 5);
    expect(restored.idleMotion?.loop, isTrue);
    expect(restored.headTapMotion?.index, 3);
    expect(restored.emotionMotions['happy']?.file, motion.file);
    expect(restored.hitAreas.single.kind, Live2DHitAreaKind.head);
  });

  test('loads Cubism motion duration and loop metadata', () async {
    final root = Directory.systemTemp.createTempSync('nt_live2d_metadata');
    try {
      final modelDirectory = Directory(
        p.join(root.path, 'live2d_models', 'metadata'),
      )..createSync(recursive: true);
      final motionsDirectory = Directory(p.join(modelDirectory.path, 'motions'))
        ..createSync();
      File(p.join(modelDirectory.path, 'model.model3.json')).writeAsStringSync(
        r'''{
          "Version": 3,
          "FileReferences": {
            "Moc": "model.moc3",
            "Textures": [],
            "Motions": {
              "": [{"File": "motions/idle.motion3.json"}]
            }
          }
        }''',
      );
      File(p.join(motionsDirectory.path, 'idle.motion3.json'))
          .writeAsStringSync(
        r'''{
          "Version": 3,
          "Meta": {"Duration": 5.25, "Loop": true, "CurveCount": 0},
          "Curves": []
        }''',
      );

      final manifest = await Live2DService(dataPath: root.path).loadManifest(
        const Live2DModelDefinition(
          id: 'metadata',
          displayName: 'Metadata',
          modelDirectory: 'live2d_models/metadata',
          modelFileName: 'model.model3.json',
          source: Live2DModelSource.appData,
        ),
      );

      expect(manifest.motions.single.durationSeconds, 5.25);
      expect(
          manifest.motions.single.duration, const Duration(milliseconds: 5250));
      expect(manifest.motions.single.loop, isTrue);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('fills metadata for an explicitly selected default-group motion', () {
    const selected = Live2DMotionRef(
      group: '',
      index: 13,
      file: 'motions/idle.motion3.json',
      name: 'idle',
    );
    const discovered = Live2DMotionRef(
      group: '',
      index: 13,
      file: 'motions/idle.motion3.json',
      name: 'idle',
      durationSeconds: 5,
      loop: true,
    );
    const config = Live2DConfig(
      modelId: 'legacy',
      displayName: 'Legacy',
      modelDirectory: 'models/legacy',
      modelFileName: 'legacy.model3.json',
      idleMotion: selected,
    );
    const defaults = Live2DConfig(
      modelId: 'legacy',
      displayName: 'Legacy',
      modelDirectory: 'models/legacy',
      modelFileName: 'legacy.model3.json',
    );

    final restored = config.withActionDefaults(
      defaults,
      discoveredMotions: const [discovered],
    );

    expect(restored.idleMotion?.durationSeconds, 5);
    expect(restored.idleMotion?.loop, isTrue);
  });

  test('Spine character configuration round-trips through JSON', () {
    const config = Live2DConfig(
      modelId: 'spine-character',
      displayName: 'Spine character',
      modelDirectory: 'live2d_models/spine-character',
      modelFileName: 'character.skel',
      source: Live2DModelSource.appData,
      format: Live2DModelFormat.spine,
      atlasFileName: 'character.atlas',
    );

    final restored = Live2DConfig.fromJson(config.toJson());

    expect(restored.format, Live2DModelFormat.spine);
    expect(restored.atlasFileName, 'character.atlas');
    expect(restored.modelFileName, 'character.skel');
  });

  test('legacy configuration without a format remains Cubism', () {
    final restored = Live2DConfig.fromJson(const {
      'modelId': 'legacy',
      'displayName': 'Legacy',
      'modelDirectory': 'assets/live2d/legacy/',
      'modelFileName': 'legacy.model3.json',
    });

    expect(restored.format, Live2DModelFormat.cubism);
  });

  test('reads a Spine 4.1 version string from a .skel header', () {
    expect(
      Live2DService.parseSpineBinaryVersion(const [
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        7,
        52,
        46,
        49,
        46,
        49,
        49,
      ]),
      '4.1.11',
    );
    expect(Live2DService.isSupportedSpineRuntimeVersion('4.1.11'), isTrue);
    expect(Live2DService.isSupportedSpineRuntimeVersion('4.2.0'), isFalse);
    expect(Live2DService.isSupportedSpineRuntimeVersion('3.8.99'), isFalse);
  });

  test('parses texture page paths from a Spine atlas', () {
    const atlas = '''
character.png
size:2048,1024
filter:Linear,Linear
body
bounds:0,0,100,100

effects/glow.png
size:512,512
filter:Linear,Linear
glow
bounds:0,0,10,10
''';

    expect(
      Live2DService.parseSpineAtlasTexturePaths(atlas),
      ['character.png', 'effects/glow.png'],
    );
  });

  test('legacy asset assignment resolves to a uniquely reimported model', () {
    const config = Live2DConfig(
      modelId: 'zhaohe_3',
      displayName: 'Zhaohe 3',
      modelDirectory: 'assets/live2d/zhaohe_3.zip/',
      modelFileName: 'zhaohe_3.model3.json',
    );
    const imported = Live2DModelDefinition(
      id: 'imported:new-id:0',
      displayName: 'Zhaohe 3',
      modelDirectory: 'live2d_models/zhaohe-new',
      modelFileName: 'zhaohe_3.model3.json',
      source: Live2DModelSource.appData,
    );

    final resolved = Live2DService.resolveDefinitionForConfig(
      config,
      const [imported],
    );

    expect(resolved, same(imported));
  });

  test('unknown asset assignment is not treated as a loadable asset', () {
    const config = Live2DConfig(
      modelId: 'removed',
      displayName: 'Removed model',
      modelDirectory: 'assets/live2d/removed/',
      modelFileName: 'removed.model3.json',
    );

    final resolved = Live2DService.resolveDefinitionForConfig(
      config,
      Live2DService.bundledModels,
    );

    expect(resolved, isNull);
  });

  test('legacy assignment does not bind a different model with the same file',
      () {
    const config = Live2DConfig(
      modelId: 'legacy-model',
      displayName: 'Expected model',
      modelDirectory: 'assets/live2d/legacy/',
      modelFileName: 'model.model3.json',
    );
    const unrelated = Live2DModelDefinition(
      id: 'imported:other:0',
      displayName: 'Different model',
      modelDirectory: 'live2d_models/other',
      modelFileName: 'model.model3.json',
      source: Live2DModelSource.appData,
    );

    final resolved = Live2DService.resolveDefinitionForConfig(
      config,
      const [unrelated],
    );

    expect(resolved, isNull);
  });

  test('rebinding corrects source identity and preserves stage choices', () {
    const idle = Live2DMotionRef(
      group: 'Idle',
      index: 0,
      file: 'idle.motion3.json',
      name: 'idle',
    );
    const config = Live2DConfig(
      modelId: 'legacy-id',
      displayName: 'Legacy',
      modelDirectory: 'assets/live2d/legacy.zip/',
      modelFileName: 'model.model3.json',
      scale: 1.8,
      offsetY: -0.4,
      idleMotion: idle,
    );
    const imported = Live2DModelDefinition(
      id: 'imported:new-id:0',
      displayName: 'Recovered',
      modelDirectory: 'live2d_models/recovered',
      modelFileName: 'model.model3.json',
      source: Live2DModelSource.appData,
    );
    const manifest = Live2DModelManifest(
      version: 3,
      mocFile: 'model.moc3',
      textures: ['texture.png'],
    );

    final rebound = Live2DService.rebindConfigToDefinition(
      config,
      imported,
      manifest,
    );

    expect(rebound.modelId, imported.id);
    expect(rebound.modelDirectory, imported.modelDirectory);
    expect(rebound.source, Live2DModelSource.appData);
    expect(rebound.scale, 1.8);
    expect(rebound.offsetY, -0.4);
    expect(rebound.idleMotion, same(idle));
  });

  testWidgets('unsupported platforms use the supplied fallback',
      (tester) async {
    if (Live2DCharacterView.isPlatformSupported) return;
    const config = Live2DConfig(
      modelId: 'test',
      displayName: 'Test',
      modelDirectory: 'assets/live2d/test/',
      modelFileName: 'test.model3.json',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Live2DCharacterView(
          config: config,
          fallback: Text('Static fallback'),
        ),
      ),
    );

    expect(find.text('Static fallback'), findsOneWidget);
  });
}

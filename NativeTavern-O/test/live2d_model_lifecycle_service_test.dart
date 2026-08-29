import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart' hide Character;
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/domain/services/live2d_import_service.dart';
import 'package:native_tavern/domain/services/live2d_model_lifecycle_service.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDirectory;
  late AppDatabase database;
  late CharacterRepository characterRepository;
  late Live2DImportService importService;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('nt_live2d_lifecycle');
    database = AppDatabase.forTesting(NativeDatabase.memory());
    characterRepository = CharacterRepository(database, tempDirectory.path);
    importService = Live2DImportService(
      dataPath: tempDirectory.path,
      modelService: Live2DService(dataPath: tempDirectory.path),
    );
  });

  tearDown(() async {
    await database.close();
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('deletion clears affected assignments and preserves unrelated assets',
      () async {
    final definition = await _importModel(tempDirectory, importService);
    final now = DateTime.now();
    await characterRepository.createCharacter(
      Character(
        id: 'affected',
        name: 'Affected',
        assets: CharacterAssets(
          avatarPath: '/avatars/affected.png',
          expressionPack: const {'happy': '/sprites/happy.png'},
          live2d: _configFor(definition),
        ),
        createdAt: now,
        modifiedAt: now,
      ),
    );
    await characterRepository.createCharacter(
      Character(
        id: 'bundled',
        name: 'Bundled',
        assets: CharacterAssets(
          live2d: _configFor(Live2DService.bundledModels.single),
        ),
        createdAt: now,
        modifiedAt: now,
      ),
    );
    final lifecycle = Live2DModelLifecycleService(
      characterRepository: characterRepository,
      importService: importService,
    );

    final plan = await lifecycle.planDeletion(definition);
    expect(
        plan.affectedCharacters.map((character) => character.id), ['affected']);

    final confirmation = lifecycle.confirmDeletion(plan);
    final result = await lifecycle.deleteImportedModel(
      confirmation,
    );

    expect(result.plan.affectedCharacters, hasLength(1));
    expect(await importService.listImportedModels(), isEmpty);
    final affected = await characterRepository.getCharacter('affected');
    expect(affected?.assets?.live2d, isNull);
    expect(affected?.assets?.avatarPath, '/avatars/affected.png');
    expect(affected?.assets?.expressionPack?['happy'], '/sprites/happy.png');
    final bundled = await characterRepository.getCharacter('bundled');
    expect(bundled?.assets?.live2d?.modelId, 'hiyori_free');
  });

  test('a partial reference update failure restores changed characters',
      () async {
    final definition = await _importModel(tempDirectory, importService);
    final failingRepository = _FailSecondClearCharacterRepository(
      database,
      tempDirectory.path,
    );
    final now = DateTime.now();
    for (final id in ['first', 'second']) {
      await failingRepository.createCharacter(
        Character(
          id: id,
          name: id,
          assets: CharacterAssets(live2d: _configFor(definition)),
          createdAt: now,
          modifiedAt: now,
        ),
      );
    }
    final lifecycle = Live2DModelLifecycleService(
      characterRepository: failingRepository,
      importService: importService,
    );
    final plan = await lifecycle.planDeletion(definition);
    final confirmation = lifecycle.confirmDeletion(plan);

    await expectLater(
      lifecycle.deleteImportedModel(confirmation),
      throwsA(isA<Live2DDeletionException>()),
    );

    expect(
      (await failingRepository.getCharacter('first'))?.assets?.live2d,
      isNotNull,
    );
    expect(
      (await failingRepository.getCharacter('second'))?.assets?.live2d,
      isNotNull,
    );
    expect(await importService.listImportedModels(), hasLength(1));
  });

  test('deleting one model removes its package and clears sibling references',
      () async {
    final definitions = await _importModels(
      tempDirectory,
      importService,
      includeSecondModel: true,
    );
    final now = DateTime.now();
    await characterRepository.createCharacter(
      Character(
        id: 'sibling-reference',
        name: 'Sibling reference',
        assets: CharacterAssets(live2d: _configFor(definitions.last)),
        createdAt: now,
        modifiedAt: now,
      ),
    );
    final lifecycle = Live2DModelLifecycleService(
      characterRepository: characterRepository,
      importService: importService,
    );

    final plan = await lifecycle.planDeletion(definitions.first);
    expect(plan.packageModels, hasLength(2));
    expect(plan.affectedCharacters.single.id, 'sibling-reference');

    final confirmation = lifecycle.confirmDeletion(plan);
    await lifecycle.deleteImportedModel(
      confirmation,
    );

    expect(await importService.listImportedModels(), isEmpty);
    expect(
      (await characterRepository.getCharacter('sibling-reference'))
          ?.assets
          ?.live2d,
      isNull,
    );
  });

  test('changed references require a fresh confirmation', () async {
    final definition = await _importModel(tempDirectory, importService);
    final lifecycle = Live2DModelLifecycleService(
      characterRepository: characterRepository,
      importService: importService,
    );
    final plan = await lifecycle.planDeletion(definition);
    final confirmation = lifecycle.confirmDeletion(plan);
    final now = DateTime.now();
    await characterRepository.createCharacter(
      Character(
        id: 'new-reference',
        name: 'New reference',
        assets: CharacterAssets(live2d: _configFor(definition)),
        createdAt: now,
        modifiedAt: now,
      ),
    );

    await expectLater(
      lifecycle.deleteImportedModel(confirmation),
      throwsA(isA<Live2DDeletionException>()),
    );

    expect(await importService.listImportedModels(), hasLength(1));
    expect(
      (await characterRepository.getCharacter('new-reference'))?.assets?.live2d,
      isNotNull,
    );
  });

  test('confirmation token is bound to the service that issued it', () async {
    final definition = await _importModel(tempDirectory, importService);
    final issuer = Live2DModelLifecycleService(
      characterRepository: characterRepository,
      importService: importService,
    );
    final otherService = Live2DModelLifecycleService(
      characterRepository: characterRepository,
      importService: importService,
    );
    final plan = await issuer.planDeletion(definition);
    final confirmation = issuer.confirmDeletion(plan);

    await expectLater(
      otherService.deleteImportedModel(confirmation),
      throwsA(isA<Live2DDeletionException>()),
    );

    expect(await importService.listImportedModels(), hasLength(1));
  });

  test('confirmation token can only be used once', () async {
    final definition = await _importModel(tempDirectory, importService);
    final lifecycle = Live2DModelLifecycleService(
      characterRepository: characterRepository,
      importService: importService,
    );
    final plan = await lifecycle.planDeletion(definition);
    final confirmation = lifecycle.confirmDeletion(plan);

    await lifecycle.deleteImportedModel(confirmation);
    await expectLater(
      lifecycle.deleteImportedModel(confirmation),
      throwsA(isA<Live2DDeletionException>()),
    );
  });
}

class _FailSecondClearCharacterRepository extends CharacterRepository {
  var _clearAttempts = 0;
  var _hasFailed = false;

  _FailSecondClearCharacterRepository(super.database, super.dataPath);

  @override
  Future<Character> updateCharacter(Character character) {
    if (!_hasFailed && character.assets?.live2d == null) {
      _clearAttempts++;
      if (_clearAttempts == 2) {
        _hasFailed = true;
        throw StateError('simulated update failure');
      }
    }
    return super.updateCharacter(character);
  }
}

Live2DConfig _configFor(Live2DModelDefinition definition) {
  return Live2DConfig(
    modelId: definition.id,
    displayName: definition.displayName,
    modelDirectory: definition.modelDirectory,
    modelFileName: definition.modelFileName,
    source: definition.source,
  );
}

Future<Live2DModelDefinition> _importModel(
  Directory directory,
  Live2DImportService importService,
) async {
  return (await _importModels(directory, importService)).single;
}

Future<List<Live2DModelDefinition>> _importModels(
  Directory directory,
  Live2DImportService importService, {
  bool includeSecondModel = false,
}) async {
  final entries = _validModelEntries();
  if (includeSecondModel) {
    entries['package/second_model.model3.json'] =
        entries['package/test_model.model3.json']!;
  }
  final zip = _writeZip(directory, 'model.zip', entries);
  return importService.importZip(zip);
}

Map<String, List<int>> _validModelEntries() {
  final model = {
    'Version': 3,
    'FileReferences': {
      'Moc': 'test_model.moc3',
      'Textures': ['textures/texture.png'],
    },
  };
  return {
    'package/test_model.model3.json': utf8.encode(jsonEncode(model)),
    'package/test_model.moc3': [0x4d, 0x4f, 0x43, 0x33],
    'package/textures/texture.png': [0x89, 0x50, 0x4e, 0x47],
  };
}

File _writeZip(
  Directory directory,
  String name,
  Map<String, List<int>> entries,
) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  final encoded = ZipEncoder().encode(archive);
  return File(p.join(directory.path, name))..writeAsBytesSync(encoded!);
}

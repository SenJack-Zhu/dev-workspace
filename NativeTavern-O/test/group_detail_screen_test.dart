import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/group_repository.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/screens/groups/group_detail_screen.dart';
import 'package:native_tavern/presentation/widgets/common/character_avatar_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('group editor shows file avatars and refreshes new characters',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final dataDirectory = Directory.systemTemp.createTempSync(
      'group-detail-screen-',
    );
    final characters = CharacterRepository(database, dataDirectory.path);
    final groups = GroupRepository(database);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characters),
        groupRepositoryProvider.overrideWithValue(groups),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
      dataDirectory.deleteSync(recursive: true);
    });

    final now = DateTime.utc(2026, 8, 25);
    Future<void> createCharacter(String id, String name) {
      return characters.createCharacter(
        models.Character(
          id: id,
          name: name,
          assets: models.CharacterAssets(avatarPath: '$id.png'),
          createdAt: now,
          modifiedAt: now,
        ),
      );
    }

    await createCharacter('alice', 'Alice');
    await createCharacter('bob', 'Bob');
    final group = await groups.createGroup(
      name: 'Writers Room',
      characterIds: const ['alice', 'bob'],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: GroupDetailScreen(groupId: group.id),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(CharacterAvatarCircle), findsNWidgets(2));

    // Simulate creating a character while the group editor remains open.
    await createCharacter('charlie', 'Charlie');
    await tester.tap(find.byIcon(Icons.add));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Charlie'), findsOneWidget);
    expect(find.byType(CharacterAvatarCircle), findsNWidgets(3));

    await tester.tap(find.text('Charlie'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Charlie'), findsOneWidget);
    expect(find.byType(CharacterAvatarCircle), findsNWidgets(3));
  });
}

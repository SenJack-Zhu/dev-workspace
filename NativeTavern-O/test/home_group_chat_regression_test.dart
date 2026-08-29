import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart' hide Character, Chat;
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/group_repository.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home uses the group name and a composite member avatar',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final dataDirectory = Directory.systemTemp.createTempSync(
      'home-group-chat-regression-',
    );
    final characters = CharacterRepository(database, dataDirectory.path);
    final chats = ChatRepository(database);
    final groups = GroupRepository(database);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characters),
        chatRepositoryProvider.overrideWithValue(chats),
        groupRepositoryProvider.overrideWithValue(groups),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
      dataDirectory.deleteSync(recursive: true);
    });

    final now = DateTime.utc(2026, 8, 23);
    for (final entry in const [
      ('character-a', 'Alice'),
      ('character-b', 'Bob')
    ]) {
      await characters.createCharacter(
        Character(
          id: entry.$1,
          name: entry.$2,
          createdAt: now,
          modifiedAt: now,
        ),
      );
    }
    final group = await groups.createGroup(
      name: 'Writers Room',
      characterIds: const ['character-a', 'character-b'],
    );
    await chats.createChat(
      Chat(
        id: 'group-chat',
        characterId: 'character-a',
        groupId: group.id,
        title: 'Legacy title',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeScreen(),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Writers Room'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

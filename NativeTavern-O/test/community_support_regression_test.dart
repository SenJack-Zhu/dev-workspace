import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart' hide Character, Chat;
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/group_repository.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dataDirectory;
  late _DelayedChatRepository chats;
  late CharacterRepository characters;
  late GroupRepository groups;
  late ProviderContainer container;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dataDirectory = await Directory.systemTemp.createTemp(
      'community-support-regression-',
    );
    chats = _DelayedChatRepository(database);
    characters = CharacterRepository(database, dataDirectory.path);
    groups = GroupRepository(database);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characters),
        chatRepositoryProvider.overrideWithValue(chats),
        groupRepositoryProvider.overrideWithValue(groups),
        sharedPreferencesProvider.overrideWithValue(preferences),
        llmServiceProvider.overrideWithValue(LLMService()),
      ],
    );
    now = DateTime.utc(2026, 8, 19);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await dataDirectory.delete(recursive: true);
  });

  Future<Character> addCharacter(String id, String name) {
    return characters.createCharacter(
      Character(
        id: id,
        name: name,
        createdAt: now,
        modifiedAt: now,
      ),
    );
  }

  Future<Chat> addChat(
    String id,
    String characterId, {
    String? groupId,
  }) {
    return chats.createChat(
      Chat(
        id: id,
        characterId: characterId,
        groupId: groupId,
        title: id,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  test('the latest chat navigation wins when an older load finishes later',
      () async {
    await addCharacter('character-a', 'A');
    await addCharacter('character-b', 'B');
    await addChat('chat-a', 'character-a');
    await addChat('chat-b', 'character-b');

    chats.delayGet('chat-a');
    final notifier = container.read(activeChatProvider.notifier);
    final firstLoad = notifier.loadChat('chat-a');
    await chats.getStarted.future;

    await notifier.loadChat('chat-b');
    chats.releaseGet();
    await firstLoad;

    final state = container.read(activeChatProvider);
    expect(state.chat?.id, 'chat-b');
    expect(state.character?.id, 'character-b');
  });

  test('group chat loads directly and resolves each message sender', () async {
    await addCharacter('character-a', 'A');
    await addCharacter('character-b', 'B');
    final group = await groups.createGroup(
      name: 'Test Group',
      characterIds: const ['character-a', 'character-b'],
    );
    final chat = await addChat(
      'group-chat',
      'character-a',
      groupId: group.id,
    );
    await chats.addMessage(
      ChatMessage(
        id: 'from-b',
        chatId: chat.id,
        role: MessageRole.assistant,
        content: 'Hello from B',
        characterId: 'character-b',
        timestamp: now,
      ),
    );

    await container.read(activeChatProvider.notifier).loadChat(chat.id);

    final state = container.read(activeChatProvider);
    expect(state.group?.name, 'Test Group');
    expect(state.groupCharacters.keys,
        containsAll(['character-a', 'character-b']));
    expect(state.characterForMessage(state.messages.single)?.name, 'B');
  });

  test('author note settings support zero and false and cannot replace chat',
      () async {
    await addCharacter('character-a', 'A');
    await addCharacter('character-b', 'B');
    await addChat('chat-a', 'character-a');
    await addChat('chat-b', 'character-b');
    final notifier = container.read(activeChatProvider.notifier);
    await notifier.loadChat('chat-a');

    expect(
      await notifier.updateAuthorNoteSettings(
        chatId: 'chat-a',
        content: 'Initial note',
        depth: 3,
        enabled: true,
      ),
      isTrue,
    );

    chats.delayUpdate('chat-a');
    final save = notifier.updateAuthorNoteSettings(
      chatId: 'chat-a',
      content: 'Final note',
      depth: 0,
      enabled: false,
    );
    await chats.updateStarted.future;
    await notifier.loadChat('chat-b');
    chats.releaseUpdate();
    expect(await save, isTrue);

    final savedA = await chats.getChat('chat-a');
    final savedB = await chats.getChat('chat-b');
    expect(savedA?.authorNote, 'Final note');
    expect(savedA?.authorNoteDepth, 0);
    expect(savedA?.authorNoteEnabled, isFalse);
    expect(savedB?.authorNote, isEmpty);
    expect(container.read(activeChatProvider).chat?.id, 'chat-b');
  });

  test('personal history excludes group chats for the same character',
      () async {
    await addCharacter('character-a', 'A');
    final group = await groups.createGroup(
      name: 'Test Group',
      characterIds: const ['character-a'],
    );
    await addChat('personal-chat', 'character-a');
    await addChat('group-chat', 'character-a', groupId: group.id);

    final history = await chats.getChatsForCharacter('character-a');
    expect(history.map((chat) => chat.id), ['personal-chat']);
  });

  test('deleting a group preserves personal chats, messages and bookmarks',
      () async {
    await addCharacter('character-a', 'A');
    final group = await groups.createGroup(
      name: 'Test Group',
      characterIds: const ['character-a'],
    );
    final personal = await addChat('personal-chat', 'character-a');
    final groupChat = await addChat(
      'group-chat',
      'character-a',
      groupId: group.id,
    );
    for (final entry in [
      (personal, 'personal-message'),
      (groupChat, 'group-message')
    ]) {
      await chats.addMessage(
        ChatMessage(
          id: entry.$2,
          chatId: entry.$1.id,
          role: MessageRole.user,
          content: entry.$2,
          timestamp: now,
        ),
      );
      await database.into(database.bookmarks).insert(
            BookmarksCompanion.insert(
              id: '${entry.$2}-bookmark',
              chatId: entry.$1.id,
              name: entry.$2,
              messageId: entry.$2,
              messageIndex: 0,
              createdAt: now,
            ),
          );
    }

    await groups.deleteGroup(group.id);

    expect(await chats.getChat(groupChat.id), isNull);
    expect(await chats.getChat(personal.id), isNotNull);
    expect(await chats.getMessages(personal.id), hasLength(1));
    final bookmarks = await database.select(database.bookmarks).get();
    expect(bookmarks.map((bookmark) => bookmark.chatId), [personal.id]);
  });
}

class _DelayedChatRepository extends ChatRepository {
  _DelayedChatRepository(super.database);

  String? _delayedGetId;
  Completer<void> getStarted = Completer<void>();
  final Completer<void> _getRelease = Completer<void>();
  String? _delayedUpdateId;
  Completer<void> updateStarted = Completer<void>();
  final Completer<void> _updateRelease = Completer<void>();

  void delayGet(String chatId) => _delayedGetId = chatId;

  void releaseGet() => _getRelease.complete();

  void delayUpdate(String chatId) => _delayedUpdateId = chatId;

  void releaseUpdate() => _updateRelease.complete();

  @override
  Future<Chat?> getChat(String id) async {
    if (id == _delayedGetId) {
      if (!getStarted.isCompleted) getStarted.complete();
      await _getRelease.future;
    }
    return super.getChat(id);
  }

  @override
  Future<Chat> updateChat(Chat chat) async {
    if (chat.id == _delayedUpdateId) {
      if (!updateStarted.isCompleted) updateStarted.complete();
      await _updateRelease.future;
    }
    return super.updateChat(chat);
  }
}

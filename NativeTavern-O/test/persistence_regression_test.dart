import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as character_models;
import 'package:native_tavern/data/models/chat.dart' as chat_models;
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/data/models/persona.dart' as persona_models;
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/persona_repository.dart';

void main() {
  late AppDatabase database;
  late Directory tempDirectory;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    tempDirectory = Directory.systemTemp.createTempSync('nt_persistence_test');
  });

  tearDown(() async {
    await database.close();
    tempDirectory.deleteSync(recursive: true);
  });

  test('persona advanced fields round-trip through the repository', () async {
    final repository = PersonaRepository(database);
    final now = DateTime.now();
    final persona = persona_models.Persona(
      id: 'persona-1',
      name: 'Navigator',
      description: 'A test persona',
      connections: const [
        persona_models.PersonaConnection(
          characterId: 'character-1',
          lockType: persona_models.PersonaLockType.character,
        ),
        persona_models.PersonaConnection(
          chatId: 'chat-1',
          lockType: persona_models.PersonaLockType.chat,
        ),
      ],
      descriptionSettings: const persona_models.PersonaDescriptionSettings(
        position: persona_models.PersonaDescriptionPosition.atDepth,
        depth: 3,
        role: persona_models.PersonaDescriptionRole.user,
      ),
      lorebookId: 'lorebook-1',
      systemPromptOverride: 'Persona system prompt',
      postHistoryInstructions: 'Persona post-history instructions',
      tags: const ['mobile', 'test'],
      creatorNotes: 'Private note',
      isFavorite: true,
      createdAt: now,
      updatedAt: now,
    );

    await repository.createPersona(persona);
    final loaded = await repository.getPersona(persona.id);

    expect(loaded, isNotNull);
    expect(loaded!.connections, persona.connections);
    expect(loaded.descriptionSettings, persona.descriptionSettings);
    expect(loaded.lorebookId, persona.lorebookId);
    expect(loaded.systemPromptOverride, persona.systemPromptOverride);
    expect(loaded.postHistoryInstructions, persona.postHistoryInstructions);
    expect(loaded.tags, persona.tags);
    expect(loaded.creatorNotes, persona.creatorNotes);
    expect(loaded.isFavorite, isTrue);
  });

  test('character Live2D assets round-trip through the repository', () async {
    final repository = CharacterRepository(database, tempDirectory.path);
    final now = DateTime.now();
    final character = character_models.Character(
      id: 'live2d-character',
      name: 'Live2D Tester',
      assets: const character_models.CharacterAssets(
        avatarPath: '/tmp/avatar.png',
        live2d: Live2DConfig(
          modelId: 'hiyori_free',
          displayName: 'Hiyori Momose (Official Sample)',
          modelDirectory: 'assets/live2d/hiyori_free/',
          modelFileName: 'hiyori_free_t08.model3.json',
          idleMotion: Live2DMotionRef(
            group: 'Idle',
            index: 0,
            file: 'motion/hiyori_m01.motion3.json',
            name: 'hiyori m01',
          ),
        ),
      ),
      createdAt: now,
      modifiedAt: now,
    );

    await repository.createCharacter(character);
    final loaded = await repository.getCharacter(character.id);

    expect(loaded?.assets?.avatarPath, character.assets?.avatarPath);
    expect(loaded?.assets?.live2d?.modelId, 'hiyori_free');
    expect(loaded?.assets?.live2d?.idleMotion?.group, 'Idle');
    expect(loaded?.assets?.live2d?.idleMotion?.index, 0);
  });

  test('chat summaries persist and clearing removes messages but not chat',
      () async {
    final characterRepository =
        CharacterRepository(database, tempDirectory.path);
    final chatRepository = ChatRepository(database);
    final now = DateTime.now();
    final character = await characterRepository.createCharacter(
      character_models.Character(
        id: 'character-1',
        name: 'Tester',
        createdAt: now,
        modifiedAt: now,
      ),
    );
    final chat = await chatRepository.createChat(
      chat_models.Chat(
        id: 'chat-1',
        characterId: character.id,
        title: 'Persistence test',
        summaries: [
          chat_models.ChatSummary(
            id: 'summary-1',
            content: 'Earlier context',
            endMessageIndex: 0,
            createdAt: now,
          ),
        ],
        settings: const {'startReplyWith': 'Prefix'},
        createdAt: now,
        updatedAt: now,
      ),
    );
    await chatRepository.addMessage(
      chat_models.ChatMessage(
        id: 'message-1',
        chatId: chat.id,
        role: chat_models.MessageRole.user,
        content: 'Hello',
        timestamp: now,
        swipes: const ['Hello'],
      ),
    );
    await database.into(database.bookmarks).insert(
          BookmarksCompanion.insert(
            id: 'bookmark-1',
            chatId: chat.id,
            name: 'Before clearing',
            messageId: 'message-1',
            messageIndex: 0,
            createdAt: now,
          ),
        );

    final reloaded = await chatRepository.getChat(chat.id);
    expect(reloaded!.summaries.single.content, 'Earlier context');
    expect(reloaded.startReplyWith, 'Prefix');

    await chatRepository.clearMessages(chat.id);
    expect(await chatRepository.getMessages(chat.id), isEmpty);
    expect(await database.select(database.bookmarks).get(), isEmpty);
    expect(await chatRepository.getChat(chat.id), isNotNull);
  });
}

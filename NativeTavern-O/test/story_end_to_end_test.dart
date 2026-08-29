import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart' hide Chat, Message;
import 'package:native_tavern/data/models/bookmark.dart' as models_bookmark;
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/models/operation_log.dart';
import 'package:native_tavern/data/models/story/story_chapter.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/long_term_memory_context_service.dart';
import 'package:native_tavern/presentation/providers/chat_extension_providers.dart';
import 'package:native_tavern/domain/services/moment_service.dart';
import 'package:native_tavern/domain/services/world_runtime.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/providers/memory_providers.dart';
import 'package:native_tavern/presentation/providers/moment_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/story_providers.dart';
import 'package:native_tavern/presentation/providers/story_timeline_providers.dart';
import 'package:native_tavern/presentation/providers/vector_storage_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dataDirectory;
  late ChatRepository chatRepository;
  late CharacterRepository characterRepository;
  late _StoryLlmService llmService;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    dataDirectory = Directory.systemTemp.createTempSync('nt_story');
    chatRepository = ChatRepository(database);
    characterRepository = CharacterRepository(database, dataDirectory.path);
    llmService = _StoryLlmService();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characterRepository),
        chatRepositoryProvider.overrideWithValue(chatRepository),
        llmServiceProvider.overrideWithValue(llmService),
        sharedPreferencesProvider.overrideWithValue(preferences),
        ragContextProvider.overrideWithValue((_) async => null),
      ],
    );

    final now = DateTime.now();
    await characterRepository.createCharacter(
      models.Character(
        id: 'character-1',
        name: 'Story Tester',
        description: 'Tests story chapters and silent notes.',
        createdAt: now,
        modifiedAt: now,
      ),
    );
    container.read(appSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    container.read(appSettingsProvider.notifier).updateStoryEnabled(true);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    dataDirectory.deleteSync(recursive: true);
  });

  test('thirty turns create a chapter and expose a jump target', () async {
    container.read(appSettingsProvider.notifier).updateStoryTurnsPerChapter(20);
    final chat = container.read(activeChatProvider.notifier);
    final chatId = (await chat.createChat('character-1'))!;

    for (var turn = 0; turn < 30; turn++) {
      await chat.sendMessage('Turn $turn about the hidden garden.', _config);
    }

    List<StoryChapter> chapters = const [];
    for (var attempt = 0; attempt < 80 && chapters.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      chapters = await container.read(storyQueryServiceProvider).listChapters(
            chatId,
          );
    }

    expect(llmService.chatRequests, 30);
    expect(chapters, isNotEmpty);
    expect(chapters.first.title, 'The Hidden Garden');
    expect(chapters.first.summary, contains('garden'));
    expect(chapters.first.narrative.keyEvents, ['They found the hidden gate.']);
    expect(chapters.first.narrative.stateChanges, ['The garden is now open.']);
    expect(chapters.first.narrative.openThreads, ['Who left the key?']);
    expect(chapters.first.narrative.nextSteps, ['Follow the garden path.']);
    expect(
      await container
          .read(storyQueryServiceProvider)
          .jumpTargetForChapter(chapters.first.id),
      chapters.first.startMessageId,
    );
    expect(
      await container.read(storyQueryServiceProvider).searchChapters(
            'garden',
            chatId: chatId,
          ),
      isNotEmpty,
    );
  });

  test('high-confidence facts write silently and low-confidence stay inbox',
      () async {
    llmService.highConfidence = true;
    final chat = container.read(activeChatProvider.notifier);
    final chatId = (await chat.createChat('character-1'))!;
    await chat.sendMessage('I always prefer jasmine tea.', _config);

    List<LongTermMemory> active = const [];
    for (var attempt = 0; attempt < 40 && active.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      active = await container
          .read(longTermMemoryRepositoryProvider)
          .findByStates({MemoryState.active});
    }
    expect(active.single.content, 'Prefers jasmine tea.');
    expect(active.single.source.sourceChatId, chatId);
    expect(
      await container
          .read(longTermMemoryRepositoryProvider)
          .findByStates({MemoryState.candidate}),
      isEmpty,
    );

    llmService.highConfidence = false;
    await chat.sendMessage('Maybe I like rain more than sun.', _config);
    List<LongTermMemory> candidates = const [];
    for (var attempt = 0; attempt < 40 && candidates.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      candidates = await container
          .read(longTermMemoryRepositoryProvider)
          .findByStates({MemoryState.candidate});
    }
    expect(candidates.single.content, 'Might prefer rain.');
    expect(candidates.single.confidence, lessThan(0.8));
  });

  test('disabled story leaves the same prompt without memory blocks', () async {
    await container.read(longTermMemoryRepositoryProvider).create(
          LongTermMemory(
            id: 'story-memory',
            kind: MemoryKind.preference,
            scope: MemoryScope.character('character-1'),
            state: MemoryState.active,
            content: 'Orchid memory marker',
            createdAt: DateTime.utc(2026, 8, 23),
            normalizedIdentityKey: 'preference:orchid',
          ),
        );
    final settings = container.read(appSettingsProvider.notifier);
    settings.updateStoryEnabled(false);
    final chat = container.read(activeChatProvider.notifier);
    await chat.createChat('character-1');
    await chat.sendMessage('orchid', _config);

    expect(
      llmService.requests.last.any(
        (message) =>
            message['content'].toString().contains('Orchid memory marker'),
      ),
      isFalse,
    );
    final disabledTrace =
        container.read(lastContextAssemblyProvider)!.traces.singleWhere(
              (trace) =>
                  trace.contributorId ==
                  LongTermMemoryContextContributor.contributorId,
            );
    expect(disabledTrace.status, ContextContributionStatus.disabled);
    expect(llmService.extractionRequests, 0);
  });

  test('bookmark fork hides old-branch chapters from the new line', () async {
    container.read(appSettingsProvider.notifier).updateStoryTurnsPerChapter(5);
    final chat = container.read(activeChatProvider.notifier);
    final chatId = (await chat.createChat('character-1'))!;
    for (var turn = 0; turn < 6; turn++) {
      await chat.sendMessage('Old branch turn $turn.', _config);
    }

    List<StoryChapter> chapters = const [];
    for (var attempt = 0; attempt < 80 && chapters.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      chapters =
          await container.read(storyQueryServiceProvider).listChapters(chatId);
    }
    expect(chapters, isNotEmpty);
    final oldChapterId = chapters.first.id;
    final forkAt = container.read(activeChatProvider).messages[2];

    await chat.branchFromBookmark(
      models_bookmark.Bookmark(
        id: 'bookmark-1',
        chatId: chatId,
        name: 'Fork',
        messageId: forkAt.id,
        messageIndex: 2,
        createdAt: DateTime.now(),
      ),
    );

    final surviving =
        await container.read(storyQueryServiceProvider).listChapters(chatId);
    expect(
        surviving.map((chapter) => chapter.id), isNot(contains(oldChapterId)));
    expect(
      await container
          .read(storyQueryServiceProvider)
          .jumpTargetForChapter(oldChapterId),
      isNull,
    );

    await container.read(storyServiceProvider).createManualChapter(
          chatId: chatId,
          title: 'New branch note',
          summary: 'We turned away before the old ending.',
          startMessageId: container.read(activeChatProvider).messages.first.id,
          endMessageId: container.read(activeChatProvider).messages.last.id,
        );
    final afterFork =
        await container.read(storyQueryServiceProvider).listChapters(chatId);
    expect(
      (await container.read(storyTimelineProvider.future))
          .map((item) => item.title),
      contains('New branch note'),
    );
    expect(afterFork.single.title, 'New branch note');
    expect(
      await container.read(storyQueryServiceProvider).searchChapters(
            'turned',
            chatId: chatId,
          ),
      isNotEmpty,
    );
  });

  test('manual chapter and memory work without a model', () async {
    final chat = container.read(activeChatProvider.notifier);
    final chatId = (await chat.createChat('character-1'))!;
    await chatRepository.addMessage(
      ChatMessage(
        id: 'manual-start',
        chatId: chatId,
        role: MessageRole.user,
        content: 'We met at the station.',
        timestamp: DateTime.now(),
      ),
    );
    await chatRepository.addMessage(
      ChatMessage(
        id: 'manual-end',
        chatId: chatId,
        role: MessageRole.assistant,
        content: 'I will wait by the clock.',
        timestamp: DateTime.now(),
      ),
    );

    final story = container.read(storyServiceProvider);
    final chapter = await story.createManualChapter(
      chatId: chatId,
      title: 'Station meeting',
      summary: 'They agreed to wait by the clock.',
      startMessageId: 'manual-start',
      endMessageId: 'manual-end',
    );
    final memory = await story.createManualMemory(
      scope: MemoryScope.character('character-1'),
      kind: MemoryKind.commitment,
      content: 'Promised to wait by the clock.',
    );

    expect(chapter.origin, StoryChapterOrigin.manual);
    expect(
      await container.read(storyQueryServiceProvider).listChapters(chatId),
      [chapter],
    );
    expect(
      (await container.read(storyQueryServiceProvider).searchMemories(
                'clock',
                scope: MemoryScope.character('character-1'),
              ))
          .single
          .memory
          .id,
      memory.id,
    );
    expect(
      (await container.read(storyTimelineProvider.future)).single.title,
      'Station meeting',
    );
  });

  test('failed chapter generation is queued and retried by the world clock',
      () async {
    container.read(appSettingsProvider.notifier).updateStoryTurnsPerChapter(5);
    llmService.failNextChapter = true;
    final chat = container.read(activeChatProvider.notifier);
    final chatId = (await chat.createChat('character-1'))!;
    for (var turn = 0; turn < 5; turn++) {
      await chat.sendMessage('Turn $turn in the garden.', _config);
    }

    OperationLog? pending;
    for (var attempt = 0; attempt < 40 && pending == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      pending = await container.read(operationLogRepositoryProvider).findOpen(
            kind: OperationKind.storyChapter,
            subjectId: chatId,
          );
    }
    expect(pending?.status, OperationStatus.incomplete);
    expect(
      await container.read(storyQueryServiceProvider).listChapters(chatId),
      isEmpty,
    );

    final runtime = WorldRuntime(
      momentService: MomentService(
        momentRepository: container.read(momentRepositoryProvider),
        dataPath: dataDirectory.path,
        minInterval: Duration.zero,
        transport: (messages, config) async => '{"skip":true}',
      ),
      characterRepository: characterRepository,
      story: container.read(storyServiceProvider),
      operations: container.read(operationLogRepositoryProvider),
      store: MemoryWorldWakeStore(),
      enabled: () => true,
      config: () => _config,
      now: () => DateTime.now().toUtc(),
      firstWake: (character, clock) => clock.add(const Duration(days: 1)),
    );
    await runtime.tick();

    final chapters =
        await container.read(storyQueryServiceProvider).listChapters(chatId);
    expect(chapters, isNotEmpty);
    expect(
      await container.read(operationLogRepositoryProvider).findOpen(
            kind: OperationKind.storyChapter,
            subjectId: chatId,
          ),
      isNull,
    );
  });

  test('startup tick writes chapters from leftover conversations', () async {
    container.read(appSettingsProvider.notifier).updateStoryTurnsPerChapter(5);
    final now = DateTime.now();
    await chatRepository.createChat(
      Chat(
        id: 'old-chat',
        characterId: 'character-1',
        title: 'Old talk',
        createdAt: now,
        updatedAt: now,
      ),
    );
    for (var turn = 0; turn < 12; turn++) {
      await chatRepository.addMessage(
        ChatMessage(
          id: 'old-user-$turn',
          chatId: 'old-chat',
          role: MessageRole.user,
          content: 'Old turn $turn in the garden.',
          timestamp: now.add(Duration(seconds: turn * 2)),
        ),
      );
      await chatRepository.addMessage(
        ChatMessage(
          id: 'old-assistant-$turn',
          chatId: 'old-chat',
          role: MessageRole.assistant,
          content: 'I remember the garden.',
          timestamp: now.add(Duration(seconds: turn * 2 + 1)),
        ),
      );
    }

    expect(
      await container.read(storyQueryServiceProvider).listChapters('old-chat'),
      isEmpty,
    );

    var storyChanged = 0;
    final runtime = WorldRuntime(
      momentService: MomentService(
        momentRepository: container.read(momentRepositoryProvider),
        dataPath: dataDirectory.path,
        minInterval: Duration.zero,
        transport: (messages, config) async => '{"skip":true}',
      ),
      characterRepository: characterRepository,
      story: container.read(storyServiceProvider),
      operations: container.read(operationLogRepositoryProvider),
      store: MemoryWorldWakeStore(),
      enabled: () => false,
      storyEnabled: () => true,
      config: () => _config,
      now: () => DateTime.now().toUtc(),
      maxChaptersPerTick: 3,
      onStoryChanged: () => storyChanged++,
    );
    await runtime.tick();

    final chapters = await container
        .read(storyQueryServiceProvider)
        .listChapters('old-chat');
    expect(chapters, hasLength(2));
    expect(
      chapters.map((chapter) => chapter.endOrdinal).toList()..sort(),
      [9, 19],
    );
    expect(storyChanged, 1);
    expect(llmService.chapterRequests, 2);
    expect(
      (await container.read(storyTimelineProvider.future)).map(
        (item) => item.title,
      ),
      contains('The Hidden Garden'),
    );
  });

  test('startup does not invent chapters when story is off', () async {
    container.read(appSettingsProvider.notifier).updateStoryEnabled(false);
    container.read(appSettingsProvider.notifier).updateStoryTurnsPerChapter(5);
    final now = DateTime.now();
    await chatRepository.createChat(
      Chat(
        id: 'quiet-chat',
        characterId: 'character-1',
        title: 'Quiet talk',
        createdAt: now,
        updatedAt: now,
      ),
    );
    for (var turn = 0; turn < 6; turn++) {
      await chatRepository.addMessage(
        ChatMessage(
          id: 'quiet-user-$turn',
          chatId: 'quiet-chat',
          role: MessageRole.user,
          content: 'Quiet turn $turn.',
          timestamp: now.add(Duration(seconds: turn * 2)),
        ),
      );
      await chatRepository.addMessage(
        ChatMessage(
          id: 'quiet-assistant-$turn',
          chatId: 'quiet-chat',
          role: MessageRole.assistant,
          content: 'Noted.',
          timestamp: now.add(Duration(seconds: turn * 2 + 1)),
        ),
      );
    }

    final runtime = WorldRuntime(
      momentService: MomentService(
        momentRepository: container.read(momentRepositoryProvider),
        dataPath: dataDirectory.path,
        minInterval: Duration.zero,
        transport: (messages, config) async => '{"skip":true}',
      ),
      characterRepository: characterRepository,
      story: container.read(storyServiceProvider),
      operations: container.read(operationLogRepositoryProvider),
      store: MemoryWorldWakeStore(),
      enabled: () => false,
      storyEnabled: () => false,
      config: () => _config,
      now: () => DateTime.now().toUtc(),
    );
    await runtime.tick();

    expect(
      await container
          .read(storyQueryServiceProvider)
          .listChapters('quiet-chat'),
      isEmpty,
    );
    expect(llmService.chapterRequests, 0);
  });
}

const _config = LLMConfig(
  provider: LLMProvider.openai,
  model: 'chat-model',
  apiKey: 'secret',
  apiUrl: 'https://example.com/v1',
  streamEnabled: false,
);

class _StoryLlmService extends LLMService {
  int chatRequests = 0;
  int extractionRequests = 0;
  int chapterRequests = 0;
  bool highConfidence = true;
  bool failNextChapter = false;
  final List<List<Map<String, dynamic>>> requests = [];

  @override
  Future<LLMResponse> generateWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) async {
    requests.add(messages);
    final system = messages
        .where((message) => message['role'] == 'system')
        .map((message) => message['content'].toString())
        .join('\n');
    if (system.contains('durable, user-relevant')) {
      extractionRequests++;
      final source = jsonDecode(messages.last['content'] as String)
          as Map<String, dynamic>;
      final sourceMessages = source['messages'] as List<dynamic>;
      return LLMResponse(
        content: jsonEncode({
          'memories': [
            {
              'kind': 'preference',
              'content': highConfidence
                  ? 'Prefers jasmine tea.'
                  : 'Might prefer rain.',
              'identityKey': highConfidence ? 'person:drink' : 'person:weather',
              'confidence': highConfidence ? 0.92 : 0.4,
              'sourceMessageIds': sourceMessages
                  .map((item) => (item as Map<String, dynamic>)['id'])
                  .toList(),
            },
          ],
        }),
      );
    }
    if (system.contains('short story chapter')) {
      chapterRequests++;
      if (failNextChapter) {
        failNextChapter = false;
        throw Exception('chapter timeout');
      }
      return const LLMResponse(
        content: '{"title":"The Hidden Garden","summary":'
            '"They kept returning to the hidden garden and made a quiet plan.",'
            '"key_events":["They found the hidden gate."],'
            '"state_changes":["The garden is now open."],'
            '"open_threads":["Who left the key?"],'
            '"next_steps":["Follow the garden path."]}',
      );
    }
    chatRequests++;
    return const LLMResponse(content: 'I will remember that.');
  }
}

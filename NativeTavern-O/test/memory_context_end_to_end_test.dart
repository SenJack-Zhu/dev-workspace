import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/group_repository.dart';
import 'package:native_tavern/data/repositories/world_info_repository.dart';
import 'package:native_tavern/domain/repositories/long_term_memory_repository.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/long_term_memory_context_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/chat_extension_providers.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/providers/memory_context_providers.dart';
import 'package:native_tavern/presentation/providers/memory_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/vector_storage_providers.dart';
import 'package:native_tavern/presentation/widgets/chat/memory_context_usage_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dataDirectory;
  late ChatRepository chatRepository;
  late CharacterRepository characterRepository;
  late LongTermMemoryRepository memoryRepository;
  late WorldInfoRepository worldInfoRepository;
  late _RecordingLLMService llmService;
  late ProviderContainer container;
  late List<String> ragQueries;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    dataDirectory = Directory.systemTemp.createTempSync('nt_memory_context');
    chatRepository = ChatRepository(database);
    characterRepository = CharacterRepository(database, dataDirectory.path);
    worldInfoRepository = WorldInfoRepository(database);
    llmService = _RecordingLLMService();
    ragQueries = [];
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characterRepository),
        chatRepositoryProvider.overrideWithValue(chatRepository),
        llmServiceProvider.overrideWithValue(llmService),
        sharedPreferencesProvider.overrideWithValue(preferences),
        ragContextProvider.overrideWithValue((query) async {
          ragQueries.add(query);
          return 'RAG marker';
        }),
      ],
    );
    memoryRepository = container.read(longTermMemoryRepositoryProvider);

    final now = DateTime.now();
    await characterRepository.createCharacter(
      models.Character(
        id: 'character-1',
        name: 'Context Tester',
        description: 'Primary context test character.',
        createdAt: now,
        modifiedAt: now,
      ),
    );
    await characterRepository.createCharacter(
      models.Character(
        id: 'character-2',
        name: 'Other Character',
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

  test('summary, lorebook, RAG, memory, and current chat keep their order',
      () async {
    final notifier = container.read(activeChatProvider.notifier);
    final chatId = (await notifier.createChat('character-1'))!;
    final chat = (await chatRepository.getChat(chatId))!;
    await chatRepository.updateChat(
      chat.copyWith(
        summaries: [
          ChatSummary(
            id: 'summary-1',
            content: 'Summary marker',
            endMessageIndex: -1,
            createdAt: DateTime.now(),
          ),
        ],
      ),
    );
    final lorebook = await worldInfoRepository.createWorldInfo(
      name: 'Test lorebook',
      characterId: 'character-1',
    );
    await worldInfoRepository.addEntry(
      worldInfoId: lorebook.id,
      keys: const [],
      content: 'Lorebook marker',
      comment: 'Lore',
      constant: true,
    );
    await memoryRepository.create(
      _memory(
        id: 'ordered-memory',
        scope: MemoryScope.character('character-1'),
        content: 'Orchid memory marker',
      ),
    );
    await notifier.loadChat(chatId);

    await notifier.sendMessage('orchid', _config);

    final contents = llmService.requests.single
        .map((message) => message['content'].toString())
        .toList();
    final loreIndex = _containingIndex(contents, 'Lorebook marker');
    final summaryIndex = _containingIndex(contents, 'Summary marker');
    final ragIndex = _containingIndex(contents, 'RAG marker');
    final memoryIndex = _containingIndex(contents, 'Orchid memory marker');
    final userIndex = contents.indexOf('orchid');
    expect(loreIndex, lessThan(summaryIndex));
    expect(summaryIndex, lessThan(ragIndex));
    expect(ragIndex, lessThan(memoryIndex));
    expect(memoryIndex, lessThan(userIndex));
    expect(ragQueries.last, 'orchid');

    final assembly = container.read(lastContextAssemblyProvider)!;
    final trace = assembly.traces.singleWhere(
      (candidate) =>
          candidate.contributorId ==
          LongTermMemoryContextContributor.contributorId,
    );
    expect(assembly.chatId, chatId);
    expect(assembly.mode, ChatGenerationMode.send);
    expect(trace.itemTraces.single.itemId, 'ordered-memory');
    expect(
      trace.itemTraces.single.status,
      ContextContributionItemStatus.included,
    );
    expect(jsonEncode(trace.metadata), isNot(contains('Orchid memory marker')));

    final usage =
        await container.read(memoryContextUsageProvider(chatId).future);
    expect(usage?.items.single.memory.content, 'Orchid memory marker');
    expect(usage?.items.single.score, greaterThan(0));
  });

  test('disabled memory leaves the baseline prompt byte-for-byte unchanged',
      () async {
    const body = 'Violet memory marker';
    await memoryRepository.create(
      _memory(
        id: 'switch-memory',
        scope: MemoryScope.character('character-1'),
        content: body,
      ),
    );
    final settings = container.read(appSettingsProvider.notifier);
    settings.updateMemoryContext(false);
    expect(container.read(appSettingsProvider).memoryContextEnabled, isFalse);
    final notifier = container.read(activeChatProvider.notifier);
    final baselineChatId = (await notifier.createChat('character-1'))!;
    await notifier.sendMessage('violet', _config);
    final baseline = llmService.requests.last;
    final disabledTrace =
        container.read(lastContextAssemblyProvider)!.traces.singleWhere(
              (trace) =>
                  trace.contributorId ==
                  LongTermMemoryContextContributor.contributorId,
            );
    expect(disabledTrace.status, ContextContributionStatus.disabled);
    expect(
      baseline.any((message) => message['content'].toString().contains(body)),
      isFalse,
    );
    expect(
      await container.read(memoryContextUsageProvider(baselineChatId).future),
      isNotNull,
    );

    settings.updateMemoryContext(true);
    final enabledChatId = (await notifier.createChat('character-1'))!;
    await notifier.sendMessage('violet', _config);
    final withMemory = llmService.requests.last;
    final withoutMemory = withMemory
        .where(
          (message) => !message['content'].toString().contains(body),
        )
        .toList(growable: false);

    expect(enabledChatId, isNot(baselineChatId));
    expect(withoutMemory, baseline);
  });

  test('regeneration queries the selected user swipe', () async {
    await memoryRepository.createAll([
      _memory(
        id: 'orchid-memory',
        scope: MemoryScope.character('character-1'),
        content: 'Orchid branch memory.',
      ),
      _memory(
        id: 'jasmine-memory',
        scope: MemoryScope.character('character-1'),
        content: 'Jasmine branch memory.',
      ),
    ]);
    final notifier = container.read(activeChatProvider.notifier);
    final chatId = (await notifier.createChat('character-1'))!;
    final now = DateTime.now();
    await chatRepository.addMessage(
      ChatMessage(
        id: 'swipe-user',
        chatId: chatId,
        role: MessageRole.user,
        content: 'orchid',
        timestamp: now,
        swipes: const ['orchid', 'jasmine'],
      ),
    );
    await chatRepository.addMessage(
      ChatMessage(
        id: 'swipe-assistant',
        chatId: chatId,
        role: MessageRole.assistant,
        content: 'Old answer',
        timestamp: now.add(const Duration(seconds: 1)),
        swipes: const ['Old answer'],
      ),
    );
    await notifier.loadChat(chatId);

    await notifier.swipeMessage('swipe-user', 1);
    await notifier.regenerateLastMessage(_config);

    final request = llmService.requests.single;
    expect(
      request.any(
        (message) =>
            message['content'].toString().contains('Jasmine branch memory.'),
      ),
      isTrue,
    );
    expect(
      request.any(
        (message) =>
            message['content'].toString().contains('Orchid branch memory.'),
      ),
      isFalse,
    );
    expect(container.read(lastContextAssemblyProvider)?.mode,
        ChatGenerationMode.regenerate);
  });

  test('group response includes group and current responder scopes only',
      () async {
    final group = await GroupRepository(database).createGroup(
      name: 'Context group',
      characterIds: const ['character-1'],
    );
    final notifier = container.read(activeChatProvider.notifier);
    final chatId = (await notifier.createGroupChat(group))!;
    await memoryRepository.createAll([
      _memory(
        id: 'group-memory',
        scope: MemoryScope.group(group.id),
        content: 'Group orchid memory.',
      ),
      _memory(
        id: 'responder-memory',
        scope: MemoryScope.character('character-1'),
        content: 'Responder orchid memory.',
      ),
      _memory(
        id: 'other-memory',
        scope: MemoryScope.character('character-2'),
        content: 'Other orchid memory.',
      ),
    ]);

    await notifier.sendGroupMessage('orchid', _config);

    // Story extraction runs asynchronously after the foreground group reply.
    final request = llmService.requests.first;
    expect(_requestContains(request, 'Group orchid memory.'), isTrue);
    expect(_requestContains(request, 'Responder orchid memory.'), isTrue);
    expect(_requestContains(request, 'Other orchid memory.'), isFalse);
    final assembly = container.read(lastContextAssemblyProvider)!;
    expect(assembly.chatId, chatId);
    expect(assembly.groupId, group.id);
    expect(assembly.characterId, 'character-1');
    expect(assembly.mode, ChatGenerationMode.groupResponse);
  });

  testWidgets('usage sheet explains trimming and routes to its source',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    final usage = MemoryContextUsage(
      chatId: 'chat-panel',
      mode: MemoryRetrievalMode.hybrid,
      status: ContextContributionStatus.applied,
      allocatedTokens: 256,
      usedTokens: 72,
      items: [
        MemoryContextUsageItem(
          memory: LongTermMemory(
            id: 'panel-memory',
            kind: MemoryKind.preference,
            scope: MemoryScope.chat('chat-panel'),
            state: MemoryState.active,
            content: 'A traceable memory shown in the usage panel.',
            source: MemorySource.generated(
              sourceChatId: 'source-chat',
              sourceMessageIds: const ['source-message'],
              extractedAt: now.subtract(const Duration(minutes: 1)),
              providerId: 'provider-1',
              modelId: 'model-1',
            ),
            importance: 0.8,
            confidence: 0.9,
            createdAt: now,
            normalizedIdentityKey: 'panel-memory',
          ),
          status: ContextContributionItemStatus.truncated,
          score: 0.86,
          originalTokens: 120,
          usedTokens: 72,
        ),
      ],
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Center(
              child: IconButton(
                key: const Key('open-memory-usage'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => const MemoryContextUsageSheet(
                    chatId: 'chat-panel',
                  ),
                ),
                icon: const Icon(Icons.psychology_outlined),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/chat/:id',
          builder: (_, state) => Scaffold(
            body: Text(
              '${state.pathParameters['id']}/'
              '${state.uri.queryParameters['message']}',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryContextUsageProvider('chat-panel').overrideWith(
            (ref) async => usage,
          ),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-memory-usage')));
    await tester.pumpAndSettle();

    expect(find.text('Memories used'), findsOneWidget);
    expect(find.text('Hybrid | 72/256 tokens'), findsOneWidget);
    expect(find.text('86% relevance'), findsOneWidget);
    expect(find.text('Trimmed'), findsOneWidget);
    expect(find.text('provider-1 / model-1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const Key('memory-usage-source-panel-memory')),
    );
    await tester.pumpAndSettle();
    expect(find.text('source-chat/source-message'), findsOneWidget);
  });
}

const _config = LLMConfig(
  provider: LLMProvider.openAICompatible,
  model: 'test-model',
  apiKey: '',
  apiUrl: 'http://localhost',
  contextLength: 4096,
  maxTokens: 256,
  streamEnabled: false,
  autoSummarizeEnabled: false,
);

final class _RecordingLLMService extends LLMService {
  final List<List<ChatMessageMap>> requests = [];

  @override
  Future<LLMResponse> generateWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) async {
    requests.add([
      for (final message in messages) Map<String, dynamic>.from(message),
    ]);
    return const LLMResponse(content: 'Recorded response.');
  }
}

LongTermMemory _memory({
  required String id,
  required MemoryScope scope,
  required String content,
}) {
  return LongTermMemory(
    id: id,
    kind: MemoryKind.preference,
    scope: scope,
    state: MemoryState.active,
    content: content,
    createdAt: DateTime.now(),
    normalizedIdentityKey: id,
  );
}

int _containingIndex(List<String> contents, String value) {
  final index = contents.indexWhere((content) => content.contains(value));
  expect(index, greaterThanOrEqualTo(0),
      reason: 'Missing "$value" in $contents');
  return index;
}

bool _requestContains(List<ChatMessageMap> request, String value) {
  return request.any(
    (message) => message['content'].toString().contains(value),
  );
}

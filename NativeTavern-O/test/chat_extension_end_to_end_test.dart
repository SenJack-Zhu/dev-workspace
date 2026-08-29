import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/presentation/providers/chat_extension_providers.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/vector_storage_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dataDirectory;
  late ChatRepository chatRepository;
  late CharacterRepository characterRepository;
  late _RecordingLLMService llmService;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dataDirectory = Directory.systemTemp.createTempSync('nt_chat_extension');
    chatRepository = ChatRepository(database);
    characterRepository = CharacterRepository(database, dataDirectory.path);
    llmService = _RecordingLLMService();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      dataPathProvider.overrideWithValue(dataDirectory.path),
      characterRepositoryProvider.overrideWithValue(characterRepository),
      chatRepositoryProvider.overrideWithValue(chatRepository),
      llmServiceProvider.overrideWithValue(llmService),
      sharedPreferencesProvider.overrideWithValue(preferences),
      ragContextProvider.overrideWithValue((_) async => null),
    ]);
    container.read(appSettingsProvider.notifier).updateStoryEnabled(false);

    final now = DateTime.now();
    await characterRepository.createCharacter(models.Character(
      id: 'character-1',
      name: 'Extension Tester',
      description: 'A character used for the chat extension test.',
      createdAt: now,
      modifiedAt: now,
    ));
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    dataDirectory.deleteSync(recursive: true);
  });

  test('contributor and middleware run through a persisted chat turn',
      () async {
    final registry = container.read(chatExtensionRegistryProvider);
    registry.registerContributor(_TestContributor());
    registry.registerMiddleware(_TestMiddleware());
    final notifier = container.read(activeChatProvider.notifier);
    final chatId = await notifier.createChat('character-1');
    expect(chatId, isNotNull);

    await notifier.sendMessage('Where should we go?', _config);

    expect(llmService.requests, hasLength(1));
    final request = llmService.requests.single;
    expect(
      request.any((message) => message['content'] == 'Retrieved memory'),
      isTrue,
    );
    expect(
      request.any((message) => message['content'] == 'Middleware marker'),
      isTrue,
    );
    expect(
      request.any((message) => message['content'] == 'Where should we go?'),
      isTrue,
    );

    final savedMessages = await chatRepository.getMessages(chatId!);
    expect(savedMessages.map((message) => message.content), [
      'Where should we go?',
      'Take the eastern road.',
    ]);
    expect(container.read(activeChatProvider).isGenerating, isFalse);
    expect(container.read(activeChatProvider).error, isNull);

    final assembly = container.read(lastContextAssemblyProvider);
    expect(assembly, isNotNull);
    final testTrace = assembly!.traces.singleWhere(
      (trace) => trace.contributorId == 'test.memory',
    );
    expect(testTrace.contributorId, 'test.memory');
    expect(
      testTrace.status,
      ContextContributionStatus.applied,
    );
    final generation = container.read(lastChatGenerationTraceProvider);
    expect(generation?.mode, ChatGenerationMode.send);
    expect(generation?.middlewareTraces, hasLength(2));
  });

  test('built-in contributors with no matches preserve the baseline prompt',
      () async {
    final notifier = container.read(activeChatProvider.notifier);
    await notifier.createChat('character-1');

    await notifier.sendMessage('Baseline request', _config);

    final assembly = container.read(lastContextAssemblyProvider);
    expect(assembly, isNotNull);
    expect(assembly!.traces, hasLength(2));
    expect(
      assembly.traces.map((trace) => trace.contributorId),
      ['data-bank.retrieval', 'memory.long_term'],
    );
    expect(
      assembly.traces.every((trace) => trace.injectedMessages.isEmpty),
      isTrue,
    );
    expect(llmService.requests.single, assembly.messages);
    expect(
      llmService.requests.single
          .where((message) => message['content'] == 'Baseline request'),
      hasLength(1),
    );
  });

  test('cancelling context assembly does not persist an empty reply', () async {
    final contributor = _SlowContributor();
    container
        .read(chatExtensionRegistryProvider)
        .registerContributor(contributor);
    final notifier = container.read(activeChatProvider.notifier);
    final chatId = await notifier.createChat('character-1');

    final sending = notifier.sendMessage('Stop this request', _config);
    await contributor.started.future;
    await notifier.cancelGeneration();
    await sending;

    final savedMessages = await chatRepository.getMessages(chatId!);
    expect(savedMessages.map((message) => message.content), [
      'Stop this request',
    ]);
    expect(llmService.requests, isEmpty);
    expect(container.read(activeChatProvider).isGenerating, isFalse);
    expect(container.read(activeChatProvider).error, isNull);
    expect(container.read(lastContextAssemblyProvider)?.cancelled, isTrue);
  });

  test('cancelling middleware removes its in-memory reply placeholder',
      () async {
    final middleware = _SlowMiddleware();
    container
        .read(chatExtensionRegistryProvider)
        .registerMiddleware(middleware);
    final notifier = container.read(activeChatProvider.notifier);
    final chatId = await notifier.createChat('character-1');

    final sending = notifier.sendMessage('Cancel before output', _config);
    await middleware.started.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError('middleware did not start'),
    );
    await notifier.cancelGeneration().timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw StateError('cancelGeneration did not finish'),
        );
    await middleware.resumed.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError('middleware did not observe cancel'),
    );
    await sending.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError('sendMessage did not finish'),
    );

    final state = container.read(activeChatProvider);
    expect(state.messages.map((message) => message.content), [
      'Cancel before output',
    ]);
    expect(
      (await chatRepository.getMessages(chatId!))
          .map((message) => message.content),
      ['Cancel before output'],
    );
    expect(llmService.requests, isEmpty);
    expect(state.error, isNull);
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

class _RecordingLLMService extends LLMService {
  final List<List<ChatMessageMap>> requests = [];

  @override
  Future<LLMResponse> generateWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) async {
    requests.add(
      messages.map((message) => Map<String, dynamic>.from(message)).toList(),
    );
    return const LLMResponse(content: 'Take the eastern road.');
  }
}

class _TestContributor extends ContextContributor {
  @override
  String get id => 'test.memory';

  @override
  int get order => 100;

  @override
  int get maxTokens => 64;

  @override
  Future<ContextContribution> contribute(ChatContextRequest request) async {
    expect(request.chatId, isNotEmpty);
    expect(request.characterId, 'character-1');
    expect(request.mode, ChatGenerationMode.send);
    return ContextContribution(messages: const [
      {'role': 'system', 'content': 'Retrieved memory'},
    ]);
  }
}

class _TestMiddleware extends ChatGenerationMiddleware {
  @override
  String get id => 'test.middleware';

  @override
  ChatGenerationRequest beforeGeneration(ChatGenerationRequest request) {
    return request.copyWith(messages: [
      ...request.messages,
      {'role': 'system', 'content': 'Middleware marker'},
    ]);
  }
}

class _SlowContributor extends ContextContributor {
  final Completer<void> started = Completer<void>();

  @override
  String get id => 'test.slow';

  @override
  Future<ContextContribution> contribute(ChatContextRequest request) async {
    started.complete();
    await request.cancellationToken.whenCancelled;
    request.cancellationToken.throwIfCancelled();
    throw StateError('unreachable');
  }
}

class _SlowMiddleware extends ChatGenerationMiddleware {
  final Completer<void> started = Completer<void>();
  final Completer<void> resumed = Completer<void>();

  @override
  String get id => 'test.slow-middleware';

  @override
  Future<ChatGenerationRequest> beforeGeneration(
    ChatGenerationRequest request,
  ) async {
    started.complete();
    await request.cancellationToken.whenCancelled;
    resumed.complete();
    request.cancellationToken.throwIfCancelled();
    throw StateError('unreachable');
  }
}

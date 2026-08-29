import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as character_models;
import 'package:native_tavern/data/models/chat.dart' as chat_models;
import 'package:native_tavern/data/models/group.dart';
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
  late CharacterRepository characters;
  late ChatRepository chats;
  late GroupRepository groups;
  late _ControlledLlmService llmService;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dataDirectory = await Directory.systemTemp.createTemp(
      'group-chat-regression-',
    );
    characters = CharacterRepository(database, dataDirectory.path);
    chats = ChatRepository(database);
    groups = GroupRepository(database);
    llmService = _ControlledLlmService();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characters),
        chatRepositoryProvider.overrideWithValue(chats),
        groupRepositoryProvider.overrideWithValue(groups),
        llmServiceProvider.overrideWithValue(llmService),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    final settings = container.read(appSettingsProvider.notifier);
    settings.updateStoryEnabled(false);
    settings.updateMemoryAutoExtraction(false);

    final now = DateTime.utc(2026, 8, 23);
    for (final entry in const [
      ('character-a', 'Alice'),
      ('character-b', 'Bob')
    ]) {
      await characters.createCharacter(
        character_models.Character(
          id: entry.$1,
          name: entry.$2,
          createdAt: now,
          modifiedAt: now,
        ),
      );
    }
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await dataDirectory.delete(recursive: true);
  });

  test('all response mode survives JSON and repository persistence', () async {
    final settings = const GroupSettings().withResponseMode(
      GroupResponseMode.all,
    );
    expect(GroupSettings.fromJson(settings.toJson()).effectiveResponseMode,
        GroupResponseMode.all);

    final group = await groups.createGroup(
      name: 'Writers Room',
      characterIds: const ['character-a', 'character-b'],
    );
    await groups.updateSettings(group.id, settings);

    expect(
      (await groups.getGroup(group.id))!.settings.effectiveResponseMode,
      GroupResponseMode.all,
    );
  });

  test('all mode starts every member response together', () async {
    final created = await groups.createGroup(
      name: 'Writers Room',
      characterIds: const ['character-a', 'character-b'],
    );
    await groups.updateSettings(
      created.id,
      created.settings.withResponseMode(GroupResponseMode.all),
    );
    final group = (await groups.getGroup(created.id))!;
    final notifier = container.read(activeChatProvider.notifier);
    await notifier.createGroupChat(group);

    final send = notifier.sendGroupMessage('Your thoughts?', _config);
    try {
      await llmService.twoRequestsStarted.future.timeout(
        const Duration(seconds: 3),
      );
      final generating = container.read(activeChatProvider);
      expect(generating.isGenerating, isTrue);
      expect(generating.generatingMessageIds, hasLength(2));
      expect(
        generating.messages.where((message) =>
            message.role == chat_models.MessageRole.assistant &&
            message.content.isEmpty),
        hasLength(2),
      );
      expect(llmService.maxConcurrentRequests, 2);
    } finally {
      llmService.release();
    }
    await send;

    final completed = container.read(activeChatProvider);
    expect(completed.isGenerating, isFalse);
    expect(completed.generatingMessageIds, isEmpty);
    expect(
      completed.messages.where(
        (message) => message.role == chat_models.MessageRole.assistant,
      ),
      hasLength(2),
    );
  });
}

const _config = LLMConfig(
  provider: LLMProvider.openAICompatible,
  model: 'test-model',
  apiKey: '',
  apiUrl: 'http://localhost',
  contextLength: 4096,
  maxTokens: 128,
  streamEnabled: true,
  autoSummarizeEnabled: false,
);

final class _ControlledLlmService extends LLMService {
  final Completer<void> twoRequestsStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();
  var _requestCount = 0;
  var _activeRequests = 0;
  var maxConcurrentRequests = 0;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Stream<LLMStreamChunk> generateStreamWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) async* {
    final requestNumber = ++_requestCount;
    _activeRequests++;
    if (_activeRequests > maxConcurrentRequests) {
      maxConcurrentRequests = _activeRequests;
    }
    if (_requestCount == 2 && !twoRequestsStarted.isCompleted) {
      twoRequestsStarted.complete();
    }
    await _release.future;
    _activeRequests--;
    yield LLMStreamChunk(content: 'Response $requestNumber');
  }
}

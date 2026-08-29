import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/providers/memory_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/vector_storage_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dataDirectory;
  late ChatRepository chatRepository;
  late CharacterRepository characterRepository;
  late _ChatAndMemoryLlmService llmService;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dataDirectory = Directory.systemTemp.createTempSync('nt_memory_auto');
    chatRepository = ChatRepository(database);
    characterRepository = CharacterRepository(database, dataDirectory.path);
    llmService = _ChatAndMemoryLlmService();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      dataPathProvider.overrideWithValue(dataDirectory.path),
      characterRepositoryProvider.overrideWithValue(characterRepository),
      chatRepositoryProvider.overrideWithValue(chatRepository),
      llmServiceProvider.overrideWithValue(llmService),
      sharedPreferencesProvider.overrideWithValue(preferences),
      ragContextProvider.overrideWithValue((_) async => null),
    ]);

    final now = DateTime.now();
    await characterRepository.createCharacter(
      models.Character(
        id: 'character-1',
        name: 'Memory Tester',
        description: 'Tests automatic extraction.',
        createdAt: now,
        modifiedAt: now,
      ),
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    dataDirectory.deleteSync(recursive: true);
  });

  test('chat turns obey the extraction switch and stage inspectable sources',
      () async {
    container.read(appSettingsProvider.notifier).updateStoryEnabled(false);
    final chat = container.read(activeChatProvider.notifier);
    final chatId = await chat.createChat('character-1');
    expect(chatId, isNotNull);

    await chat.sendMessage('This turn is private.', _config);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(llmService.chatRequests, 1);
    expect(llmService.extractionRequests, 0);
    expect(
      await container
          .read(longTermMemoryRepositoryProvider)
          .findByStates({MemoryState.candidate}),
      isEmpty,
    );

    container
        .read(appSettingsProvider.notifier)
        .updateMemoryAutoExtraction(true);
    expect(
      container.read(appSettingsProvider).memoryAutoExtractionEnabled,
      isTrue,
    );
    await chat.sendMessage('I always prefer jasmine tea.', _config);

    List<LongTermMemory> candidates = const [];
    for (var attempt = 0; attempt < 40 && candidates.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      candidates = await container
          .read(longTermMemoryRepositoryProvider)
          .findByStates({MemoryState.candidate});
    }

    expect(llmService.chatRequests, 2);
    expect(llmService.extractionRequests, 1);
    expect(candidates, hasLength(1));
    final candidate = candidates.single;
    expect(candidate.state, MemoryState.candidate);
    expect(candidate.content, 'Prefers jasmine tea.');
    expect(candidate.scope, MemoryScope.character('character-1'));
    expect(candidate.source.providerId, 'openai');
    expect(candidate.source.modelId, 'chat-model');
    expect(candidate.source.sourceChatId, chatId);
    expect(candidate.source.sourceMessageIds, hasLength(2));
    final savedMessages = await chatRepository.getMessages(chatId!);
    expect(
      candidate.source.sourceMessageIds,
      savedMessages.skip(savedMessages.length - 2).map((message) => message.id),
    );
    expect(container.read(activeChatProvider).error, isNull);
    expect(container.read(activeChatProvider).isGenerating, isFalse);
  });
}

const _config = LLMConfig(
  provider: LLMProvider.openai,
  model: 'chat-model',
  apiKey: 'secret',
  apiUrl: 'https://example.com/v1',
  streamEnabled: false,
);

class _ChatAndMemoryLlmService extends LLMService {
  int chatRequests = 0;
  int extractionRequests = 0;

  @override
  Future<LLMResponse> generateWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) async {
    final isExtraction = messages.any(
      (message) =>
          message['role'] == 'system' &&
          (message['content'] as String).contains('durable, user-relevant'),
    );
    if (isExtraction) {
      extractionRequests++;
      final source = jsonDecode(messages.last['content'] as String)
          as Map<String, dynamic>;
      final sourceMessages = source['messages'] as List<dynamic>;
      return LLMResponse(
        content: jsonEncode({
          'memories': [
            {
              'kind': 'preference',
              'content': 'Prefers jasmine tea.',
              'identityKey': 'person:drink',
              'sourceMessageIds': sourceMessages
                  .map((item) => (item as Map<String, dynamic>)['id'])
                  .toList(),
            },
          ],
        }),
      );
    }
    chatRequests++;
    return const LLMResponse(content: 'I will remember that.');
  }
}

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/tool_calling/built_in_tool_service.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_calling_adapter.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/tool_calling_providers.dart';
import 'package:native_tavern/presentation/providers/vector_storage_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('chat middleware, tool loop, and persistence complete one turn',
      () async {
    SharedPreferences.setMockInitialValues({
      'tool_calling_settings':
          '{"version":1,"enabled":true,"enabledBuiltInTools":["roll_dice"],"limits":{"maxToolRounds":4,"maxCalls":8,"maxElapsedSeconds":60,"maxTokenBudget":8192}}',
    });
    final preferences = await SharedPreferences.getInstance();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final directory = Directory.systemTemp.createTempSync('nt_tool_chat');
    final chatRepository = ChatRepository(database);
    final characterRepository = CharacterRepository(database, directory.path);
    final llm = _ToolLoopLLMService();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(directory.path),
        characterRepositoryProvider.overrideWithValue(characterRepository),
        chatRepositoryProvider.overrideWithValue(chatRepository),
        llmServiceProvider.overrideWithValue(llm),
        sharedPreferencesProvider.overrideWithValue(preferences),
        ragContextProvider.overrideWithValue((_) async => null),
        builtInToolRegistryProvider.overrideWithValue(
          BuiltInToolRegistry([RollDiceToolExecutor()]),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
      directory.deleteSync(recursive: true);
    });

    final now = DateTime.now();
    await characterRepository.createCharacter(
      models.Character(
        id: 'tool-character',
        name: 'Tool Tester',
        description: 'Exercises tool-aware chat generation.',
        createdAt: now,
        modifiedAt: now,
      ),
    );
    final notifier = container.read(activeChatProvider.notifier);
    final chatId = await notifier.createChat('tool-character');

    await notifier.sendMessage('Roll a die.', _config);

    expect(llm.toolTurns, 2);
    expect(llm.normalTurns, 0);
    expect(llm.firstMessages, isNotNull);
    expect(
      llm.firstMessages!.any(
        (message) => message['content'] == 'Roll a die.',
      ),
      isTrue,
    );
    expect(llm.resultWasReturned, isTrue);
    final saved = await chatRepository.getMessages(chatId!);
    expect(saved.map((message) => message.content), [
      'Roll a die.',
      'The roll is complete.',
    ]);
    expect(container.read(activeChatProvider).error, isNull);
    expect(container.read(activeChatProvider).isGenerating, isFalse);
  });
}

const _config = LLMConfig(
  provider: LLMProvider.openAICompatible,
  model: 'tool-test',
  apiKey: '',
  apiUrl: 'http://localhost/v1',
  streamEnabled: true,
  autoSummarizeEnabled: false,
  maxTokens: 512,
  contextLength: 4096,
);

final class _ToolLoopLLMService extends LLMService {
  int toolTurns = 0;
  int normalTurns = 0;
  bool resultWasReturned = false;
  List<Map<String, dynamic>>? firstMessages;

  @override
  Future<ToolProviderTurn> generateToolTurn({
    required List<Map<String, dynamic>> baseMessages,
    required List<Map<String, dynamic>> continuationMessages,
    required LLMConfig config,
    required ToolCallingConfiguration toolConfiguration,
    required ToolCallingAdapter adapter,
    required ToolCancellationToken cancellationToken,
  }) async {
    cancellationToken.throwIfCancelled();
    toolTurns++;
    if (toolTurns == 1) {
      firstMessages = baseMessages;
      expect(
        toolConfiguration.tools.map((tool) => tool.name),
        [RollDiceToolExecutor.toolName],
      );
      return ToolProviderTurn(
        assistant: ToolAssistantMessage(
          toolCalls: [
            ToolCall.ready(
              id: 'chat-roll',
              name: RollDiceToolExecutor.toolName,
              arguments: const {'count': 1, 'sides': 6},
              rawArguments: '{"count":1,"sides":6}',
            ),
          ],
        ),
        continuationMessage: const {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'chat-roll',
              'type': 'function',
              'function': {
                'name': 'roll_dice',
                'arguments': '{"count":1,"sides":6}',
              },
            },
          ],
        },
      );
    }
    resultWasReturned = continuationMessages.any(
      (message) =>
          message['role'] == 'tool' && message['tool_call_id'] == 'chat-roll',
    );
    return ToolProviderTurn(
      assistant: ToolAssistantMessage(text: 'The roll is complete.'),
      continuationMessage: const {
        'role': 'assistant',
        'content': 'The roll is complete.',
      },
    );
  }

  @override
  Future<LLMResponse> generateWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) async {
    normalTurns++;
    return const LLMResponse(content: 'Unexpected normal response.');
  }
}

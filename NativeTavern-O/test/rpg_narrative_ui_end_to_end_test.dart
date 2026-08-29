import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/rpg_narrative_bridge.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/chat_extension_providers.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/providers/rpg_chat_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/vector_storage_providers.dart';
import 'package:native_tavern/presentation/widgets/rpg/rpg_game_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;
  late AppDatabase database;
  late ChatRepository chatRepository;
  late CharacterRepository characterRepository;
  late _ControlledLlmService llmService;
  late ProviderContainer container;
  late String chatId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    temporaryDirectory = await Directory.systemTemp.createTemp('rpg-bridge-');
    final databaseFile = File('${temporaryDirectory.path}/rpg.sqlite');
    database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    await database.customSelect('SELECT 1').get();
    chatRepository = ChatRepository(database);
    characterRepository = CharacterRepository(
      database,
      temporaryDirectory.path,
    );
    llmService = _ControlledLlmService();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      dataPathProvider.overrideWithValue(temporaryDirectory.path),
      characterRepositoryProvider.overrideWithValue(characterRepository),
      chatRepositoryProvider.overrideWithValue(chatRepository),
      llmServiceProvider.overrideWithValue(llmService),
      sharedPreferencesProvider.overrideWithValue(preferences),
      ragContextProvider.overrideWithValue((_) async => null),
    ]);
    container.read(appSettingsProvider.notifier).updateStoryEnabled(false);

    final now = DateTime.utc(2026, 8, 8);
    await characterRepository.createCharacter(models.Character(
      id: 'rpg-character',
      name: 'Game Master',
      description: 'Runs deterministic RPG tests.',
      createdAt: now,
      modifiedAt: now,
    ));
    chatId = (await container
        .read(activeChatProvider.notifier)
        .createChat('rpg-character'))!;
    await container.read(rpgChatProvider(chatId).notifier).enable(_scenario);
    container.read(rpgChatExtensionsProvider);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('injects RPG context, validates an action, and persists its result',
      () async {
    llmService.responses.add(const LLMResponse(
      content:
          '{"narrative":"You push into the ruins.","proposedAction":{"actionId":"explore"}}',
    ));

    await container
        .read(activeChatProvider.notifier)
        .sendMessage('Explore the ruins', _config);

    final request = llmService.requests.single;
    final rpgPrompt = request.singleWhere(
      (message) =>
          message['role'] == 'system' &&
          '${message['content']}'.contains('RPG_CONTEXT:'),
    );
    expect(rpgPrompt['content'], contains('"actionId": "explore"'));
    expect(rpgPrompt['content'], isNot(contains('"actionId": "expensive"')));

    final uiState = container.read(rpgChatProvider(chatId));
    expect(uiState.session!.state.turn, 1);
    expect(uiState.session!.state.attributes['energy'], 2);
    expect(uiState.session!.state.inventory.single.itemId, 'relic');
    expect(
        uiState.session!.state.quests.single.status, RpgQuestStatus.completed);
    expect(uiState.lastResult?.status, RpgNarrativeStatus.committed);

    final messages = await chatRepository.getMessages(chatId);
    expect(messages.last.content, contains('You push into the ruins.'));
    expect(messages.last.content, contains('Rule engine: Explore succeeded.'));
    expect(messages.last.content, isNot(contains('proposedAction')));
    expect(uiState.snapshots, hasLength(2));
  });

  test('buffers a streamed control envelope until it has been validated',
      () async {
    llmService.responses.add(const LLMResponse(
      content:
          '{"narrative":"A careful step forward.","proposedAction":{"actionId":"explore"}}',
    ));

    await container
        .read(activeChatProvider.notifier)
        .sendMessage('Move carefully', _streamingConfig);

    final messages = await chatRepository.getMessages(chatId);
    expect(messages.last.content, startsWith('A careful step forward.'));
    expect(messages.last.content, isNot(contains('{"narrative"')));
    expect(container.read(rpgChatProvider(chatId)).session!.state.turn, 1);
  });

  test('disabled RPG mode preserves the baseline chat request and response',
      () async {
    await container.read(rpgChatProvider(chatId).notifier).setEnabled(false);
    llmService.responses.add(
      const LLMResponse(content: 'A normal unstructured chat reply.'),
    );

    await container
        .read(activeChatProvider.notifier)
        .sendMessage('Talk normally', _config);

    expect(
      llmService.requests.single.any(
        (message) => '${message['content']}'.contains('RPG_CONTEXT:'),
      ),
      isFalse,
    );
    final messages = await chatRepository.getMessages(chatId);
    expect(messages.last.content, 'A normal unstructured chat reply.');
    expect(container.read(rpgChatProvider(chatId)).session!.state.turn, 0);
  });

  test('malformed and rejected suggestions never create partial snapshots',
      () async {
    final controller = container.read(rpgChatProvider(chatId).notifier);
    final initialSnapshot =
        container.read(rpgChatProvider(chatId)).session!.snapshot.metadata.id;

    llmService.responses.add(
      const LLMResponse(content: '{"narrative":"Broken"'),
    );
    await container
        .read(activeChatProvider.notifier)
        .sendMessage('Malformed turn', _config);
    var state = container.read(rpgChatProvider(chatId));
    expect(state.lastResult?.status, RpgNarrativeStatus.malformed);
    expect(state.session!.snapshot.metadata.id, initialSnapshot);
    expect(state.snapshots, hasLength(1));

    llmService.responses.add(const LLMResponse(
      content:
          '{"narrative":"I alter the state.","proposedAction":null,"turn":99}',
    ));
    await container
        .read(activeChatProvider.notifier)
        .sendMessage('Bypass the rules', _config);
    state = container.read(rpgChatProvider(chatId));
    expect(state.lastResult?.status, RpgNarrativeStatus.malformed);
    expect(state.lastResult?.errorCode, 'unexpected_field');
    expect(state.session!.state.turn, 0);
    expect(state.session!.snapshot.metadata.id, initialSnapshot);

    llmService.responses.add(const LLMResponse(
      content:
          '{"narrative":"You spend everything.","proposedAction":{"actionId":"expensive"}}',
    ));
    await container
        .read(activeChatProvider.notifier)
        .sendMessage('Spend energy', _config);
    state = container.read(rpgChatProvider(chatId));
    expect(state.lastResult?.status, RpgNarrativeStatus.rejected);
    expect(state.lastResult?.errorCode, 'insufficient_resource');
    expect(state.session!.snapshot.metadata.id, initialSnapshot);
    expect(state.snapshots, hasLength(1));
    expect(controller.availableActions.map((action) => action.id), ['explore']);
  });

  test('cancelling generation records cancellation and commits no action',
      () async {
    llmService.blockNextResponse();
    final sending = container
        .read(activeChatProvider.notifier)
        .sendMessage('Stop before resolving', _config);
    await llmService.started.future;

    await container.read(activeChatProvider.notifier).cancelGeneration();
    llmService.releaseBlockedResponse(const LLMResponse(
      content:
          '{"narrative":"Too late.","proposedAction":{"actionId":"explore"}}',
    ));
    await sending;

    final state = container.read(rpgChatProvider(chatId));
    expect(state.lastResult?.status, RpgNarrativeStatus.cancelled);
    expect(state.session!.state.turn, 0);
    expect(state.snapshots, hasLength(1));
    expect(
      (await chatRepository.getMessages(chatId))
          .map((message) => message.content),
      ['Stop before resolving'],
    );
  });

  testWidgets(
      'game panel covers all views and refreshes action and branch state',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RpgGamePanel(chatId: chatId, onDisable: _noop),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('rpg-game-panel')), findsOneWidget);
    for (final key in const [
      'rpg-tab-status',
      'rpg-tab-inventory',
      'rpg-tab-quests',
      'rpg-tab-relations',
      'rpg-tab-actions',
      'rpg-tab-log',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }

    final initialSnapshot =
        container.read(rpgChatProvider(chatId)).session!.snapshot.metadata.id;
    final tabController = DefaultTabController.of(
      tester.element(find.byKey(const Key('rpg-tab-status'))),
    );
    tabController.animateTo(4);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rpg-action-explore')));
    await tester.pumpAndSettle();
    var state = container.read(rpgChatProvider(chatId));
    expect(state.session!.state.turn, 1);
    final mainTurnSnapshot = state.session!.snapshot.metadata.id;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    tabController.animateTo(5);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('rpg-log-view')),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('rpg-snapshot-$initialSnapshot')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork new branch'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rpg-branch-id')), 'alternate');
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();

    state = container.read(rpgChatProvider(chatId));
    expect(state.session!.branchId, 'alternate');
    expect(state.session!.state.turn, 0);

    await container
        .read(rpgChatProvider(chatId).notifier)
        .rollback(mainTurnSnapshot);
    await tester.pumpAndSettle();
    state = container.read(rpgChatProvider(chatId));
    expect(state.session!.branchId, startsWith('chat_'));
    expect(state.session!.state.turn, 1);
    expect(find.textContaining('Turn 1'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}

const _config = LLMConfig(
  provider: LLMProvider.openAICompatible,
  model: 'test-model',
  apiKey: '',
  apiUrl: 'http://localhost',
  contextLength: 4096,
  maxTokens: 512,
  streamEnabled: false,
  autoSummarizeEnabled: false,
);

const _streamingConfig = LLMConfig(
  provider: LLMProvider.openAICompatible,
  model: 'test-model',
  apiKey: '',
  apiUrl: 'http://localhost',
  contextLength: 4096,
  maxTokens: 512,
  streamEnabled: true,
  autoSummarizeEnabled: false,
);

class _ControlledLlmService extends LLMService {
  final Queue<LLMResponse> responses = Queue<LLMResponse>();
  final List<List<ChatMessageMap>> requests = [];
  Completer<void> started = Completer<void>();
  Completer<LLMResponse>? _blockedResponse;

  void blockNextResponse() {
    started = Completer<void>();
    _blockedResponse = Completer<LLMResponse>();
  }

  void releaseBlockedResponse(LLMResponse response) {
    final blocked = _blockedResponse!;
    _blockedResponse = null;
    blocked.complete(response);
  }

  Future<LLMResponse> _next(List<Map<String, dynamic>> messages) async {
    requests.add(
      messages.map((message) => Map<String, dynamic>.from(message)).toList(),
    );
    final blocked = _blockedResponse;
    if (blocked != null) {
      if (!started.isCompleted) started.complete();
      return blocked.future;
    }
    return responses.removeFirst();
  }

  @override
  Future<LLMResponse> generateWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) =>
      _next(messages);

  @override
  Stream<LLMStreamChunk> generateStreamWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) async* {
    final response = await _next(messages);
    final midpoint = response.content.length ~/ 2;
    yield LLMStreamChunk(content: response.content.substring(0, midpoint));
    yield LLMStreamChunk(content: response.content.substring(midpoint));
  }
}

const _scenario = RpgScenario(
  metadata: RpgScenarioMetadata(
    id: 'bridge_test',
    name: 'Bridge Test',
    version: '1.0.0',
  ),
  initialSeed: 77,
  protectedFields: [
    'random.initialSeed',
    'random.state',
    'random.rollsConsumed',
    'turn',
    'attributes',
    'inventory',
    'quests',
    'cooldowns',
    'eventHistory',
  ],
  attributes: [
    RpgAttributeDefinition(
      id: 'energy',
      label: 'Energy',
      initialValue: 3,
      minimum: 0,
      maximum: 5,
    ),
  ],
  items: [RpgItemDefinition(id: 'relic', label: 'Relic')],
  actors: [RpgActorDefinition(id: 'guide', label: 'Guide')],
  locations: [RpgLocationDefinition(id: 'camp', label: 'Camp')],
  quests: [RpgQuestDefinition(id: 'ruins', label: 'Explore the ruins')],
  actions: [
    RpgActionDefinition(
      id: 'explore',
      label: 'Explore',
      costs: [RpgActionCost(path: 'attributes.energy', amount: 1)],
      check: RpgSkillCheck(
        attributeId: 'energy',
        dice: RpgDiceSpec('1d1'),
        difficulty: 1,
        successEffects: [
          RpgEffect(type: RpgEffectType.addItem, target: 'relic', amount: 1),
          RpgEffect(
            type: RpgEffectType.setQuestStatus,
            target: 'ruins',
            value: 'completed',
          ),
          RpgEffect(
            type: RpgEffectType.adjustRelationship,
            target: 'guide',
            amount: 2,
          ),
        ],
      ),
    ),
    RpgActionDefinition(
      id: 'expensive',
      label: 'Spend everything',
      costs: [RpgActionCost(path: 'attributes.energy', amount: 99)],
    ),
  ],
  initialState: RpgRuntimeState(
    scenarioId: 'bridge_test',
    scenarioVersion: '1.0.0',
    random: RpgRandomState(initialSeed: 77, state: 77),
    attributes: {'energy': 3},
    relationships: [RpgRelationshipState(actorId: 'guide')],
    locationId: 'camp',
    quests: [RpgQuestState(questId: 'ruins', status: RpgQuestStatus.active)],
  ),
);

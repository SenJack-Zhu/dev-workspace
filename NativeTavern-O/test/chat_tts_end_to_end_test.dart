import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/services/live2d_action_orchestrator.dart';
import 'package:native_tavern/domain/services/live2d_tts_playback_coordinator.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/tts_service.dart';
import 'package:native_tavern/presentation/controllers/chat_tts_autoplay_controller.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/vector_storage_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_system_tts_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persisted assistant reply drives scoped TTS and Live2D to completion',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final dataDirectory = Directory.systemTemp.createTempSync('nt_chat_tts');
    final chatRepository = ChatRepository(database);
    final characterRepository =
        CharacterRepository(database, dataDirectory.path);
    final llmService = _ReplyingLLMService();
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      dataPathProvider.overrideWithValue(dataDirectory.path),
      characterRepositoryProvider.overrideWithValue(characterRepository),
      chatRepositoryProvider.overrideWithValue(chatRepository),
      llmServiceProvider.overrideWithValue(llmService),
      sharedPreferencesProvider.overrideWithValue(preferences),
      ragContextProvider.overrideWithValue((_) async => null),
    ]);
    final backend = FakeSystemTTSBackend();
    final tts = TTSService(systemTts: backend);
    tts.updateSettings(const TTSSettings(
      enabled: true,
      autoPlay: true,
      provider: TTSProvider.system,
    ));
    await tts.initialize();

    final played = <Live2DActionKind>[];
    final mouths = <double>[];
    final playbackStates = <TTSPlaybackState>[];
    final orchestrator = Live2DActionOrchestrator(
      resolver: Live2DActionResolver(_live2dConfig()),
      player: (motion, priority) async => true,
      onPlaybackChanged: (playback) {
        if (playback != null) played.add(playback.kind);
      },
      sentenceCooldown: Duration.zero,
    );
    final live2d = Live2DTTSPlaybackCoordinator();
    TTSPlaybackState? previousPlayback = tts.playbackState;
    var live2dWork = Future<void>.value();
    final playbackSubscription = tts.playbackStates.listen((next) {
      playbackStates.add(next);
      final update = live2d.evaluate(previousPlayback, next);
      previousPlayback = next;
      live2dWork = live2dWork.then(
        (_) => _applyLive2DUpdate(update, orchestrator, mouths),
      );
    });

    final now = DateTime.now();
    await characterRepository.createCharacter(models.Character(
      id: 'character-1',
      name: 'Narrator',
      createdAt: now,
      modifiedAt: now,
    ));
    final notifier = container.read(activeChatProvider.notifier);
    final chatId = await notifier.createChat('character-1');
    expect(chatId, isNotNull);

    final autoPlay = ChatTTSAutoPlayController();
    final speechFutures = <Future<void>>[];
    final chatSubscription = container.listen<ActiveChatState>(
      activeChatProvider,
      (previous, next) {
        final action = autoPlay.evaluate(
          previous: previous,
          next: next,
          settings: tts.settings,
        );
        switch (action.kind) {
          case ChatTTSActionKind.none:
            break;
          case ChatTTSActionKind.stop:
            unawaited(tts.stop(ownerId: chatId));
          case ChatTTSActionKind.speak:
            speechFutures.add(tts.speak(
              action.text!,
              characterId: action.characterId,
              ownerId: chatId,
              sourceId: action.sourceId,
            ));
        }
      },
    );

    try {
      await notifier.sendMessage('Which way?', _llmConfig);
      await backend.waitForSpeakCount(1);
      backend.progress(0, 4, 'Take');
      backend.completeCurrent();
      await Future.wait(speechFutures);
      await live2dWork;

      final savedMessages = await chatRepository.getMessages(chatId!);
      expect(savedMessages.map((message) => message.content), [
        'Which way?',
        'Take the eastern road.',
      ]);
      final assistant = savedMessages.last;
      expect(backend.spokenTexts, ['Take the eastern road.']);
      expect(backend.audioFocusRequests, [true]);
      expect(
        playbackStates.any((state) =>
            state.phase == TTSPlaybackPhase.playing &&
            state.ownerId == chatId &&
            state.sourceId == assistant.id &&
            state.characterId == 'character-1'),
        isTrue,
      );
      expect(played, contains(Live2DActionKind.speaking));
      expect(played, contains(Live2DActionKind.completion));
      expect(mouths.any((value) => value > 0), isTrue);
      expect(mouths.last, 0);
      expect(tts.playbackState.phase, TTSPlaybackPhase.completed);
      expect(tts.playbackState.mouthOpen, 0);
    } finally {
      chatSubscription.close();
      await playbackSubscription.cancel();
      orchestrator.dispose();
      tts.dispose();
      container.dispose();
      await database.close();
      dataDirectory.deleteSync(recursive: true);
    }
  });
}

Future<void> _applyLive2DUpdate(
  Live2DTTSPlaybackUpdate update,
  Live2DActionOrchestrator orchestrator,
  List<double> mouths,
) async {
  mouths.add(update.mouthOpen);
  switch (update.lifecycle) {
    case Live2DTTSLifecycleEvent.none:
      break;
    case Live2DTTSLifecycleEvent.started:
      await orchestrator.onMessageStarted();
    case Live2DTTSLifecycleEvent.paused:
      await orchestrator.onPlaybackPaused();
    case Live2DTTSLifecycleEvent.completed:
      await orchestrator.onResponseCompleted();
    case Live2DTTSLifecycleEvent.stopped:
      await orchestrator.onPlaybackStopped();
  }
  for (var index = 0; index < update.sentenceBoundaries; index++) {
    await orchestrator.onSentenceBoundary();
  }
}

const _llmConfig = LLMConfig(
  provider: LLMProvider.openAICompatible,
  model: 'test-model',
  apiKey: '',
  apiUrl: 'http://localhost',
  contextLength: 4096,
  maxTokens: 256,
  streamEnabled: false,
  autoSummarizeEnabled: false,
);

class _ReplyingLLMService extends LLMService {
  @override
  Future<LLMResponse> generateWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) async {
    return const LLMResponse(content: 'Take the eastern road.');
  }
}

Live2DConfig _live2dConfig() {
  return Live2DConfig(
    modelId: 'test',
    displayName: 'Test',
    modelDirectory: 'models/test',
    modelFileName: 'test.model3.json',
    idleMotion: _motion('Idle'),
    speakingMotion: _motion('Talk'),
    responseMotion: _motion('Complete'),
  );
}

Live2DMotionRef _motion(String group) {
  return Live2DMotionRef(
    group: group,
    index: 0,
    file: '$group.motion3.json',
    name: group,
  );
}

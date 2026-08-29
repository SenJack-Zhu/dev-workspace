import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/rpg_game_session_service.dart';
import 'package:native_tavern/domain/services/rpg_narrative_bridge.dart';
import 'package:native_tavern/presentation/providers/rpg_chat_providers.dart';

final chatExtensionRegistryProvider = Provider<ChatExtensionRegistry>((ref) {
  final registry = ChatExtensionRegistry();
  ref.onDispose(registry.clear);
  return registry;
});

final lastContextAssemblyProvider = StateProvider<ContextAssemblyResult?>(
  (ref) => null,
);

final lastChatGenerationTraceProvider = StateProvider<ChatGenerationTrace?>(
  (ref) => null,
);

final chatGenerationPipelineProvider = Provider<ChatGenerationPipeline>((ref) {
  final pipeline = ChatGenerationPipeline(
    registry: ref.watch(chatExtensionRegistryProvider),
    onContextAssembled: (result) {
      ref.read(lastContextAssemblyProvider.notifier).state = result;
    },
    onGenerationFinished: (trace) {
      ref.read(lastChatGenerationTraceProvider.notifier).state = trace;
    },
  );
  ref.onDispose(pipeline.dispose);
  return pipeline;
});

/// Registers the RPG bridge only while a chat UI is mounted. Disabled RPG
/// sessions contribute no context and perform no response transformation.
final rpgChatExtensionsProvider = Provider<void>((ref) {
  final registry = ref.watch(chatExtensionRegistryProvider);
  final sessionService = ref.watch(rpgGameSessionServiceProvider);

  Future<bool> isEnabled(String chatId) =>
      ref.read(rpgChatProvider(chatId).notifier).isModeEnabled();
  Future<RpgGameSession?> loadSession(String chatId) =>
      ref.read(rpgChatProvider(chatId).notifier).enabledSession();

  final contributorRegistration = registry.registerContributor(
    RpgNarrativeContextContributor(
      loadSession: loadSession,
      isModeEnabled: isEnabled,
    ),
  );
  final middlewareRegistration = registry.registerMiddleware(
    RpgNarrativeMiddleware(
      sessionService: sessionService,
      loadSession: loadSession,
      isModeEnabled: isEnabled,
      onResult: (result) => ref
          .read(rpgChatProvider(result.chatId).notifier)
          .applyNarrativeResult(result),
    ),
  );

  ref.onDispose(() {
    middlewareRegistration.dispose();
    contributorRegistration.dispose();
  });
});

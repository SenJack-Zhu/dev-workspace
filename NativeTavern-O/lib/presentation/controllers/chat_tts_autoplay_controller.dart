import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/domain/services/tts_service.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';

enum ChatTTSActionKind { none, stop, speak }

class ChatTTSAction {
  const ChatTTSAction._({
    required this.kind,
    this.text,
    this.characterId,
    this.sourceId,
  });

  const ChatTTSAction.none() : this._(kind: ChatTTSActionKind.none);
  const ChatTTSAction.stop() : this._(kind: ChatTTSActionKind.stop);
  const ChatTTSAction.speak({
    required String text,
    required String sourceId,
    String? characterId,
  }) : this._(
          kind: ChatTTSActionKind.speak,
          text: text,
          sourceId: sourceId,
          characterId: characterId,
        );

  final ChatTTSActionKind kind;
  final String? text;
  final String? characterId;
  final String? sourceId;
}

/// Converts chat state transitions into idempotent playback commands.
class ChatTTSAutoPlayController {
  String? _lastSpokenRevision;

  ChatTTSAction evaluate({
    required ActiveChatState? previous,
    required ActiveChatState next,
    required TTSSettings settings,
  }) {
    if (!settings.enabled) return const ChatTTSAction.none();

    final generationStarted = previous?.isGenerating == false &&
        next.isGenerating &&
        next.messages.isNotEmpty &&
        next.messages.last.role == MessageRole.user;
    if (generationStarted) return const ChatTTSAction.stop();

    if (!settings.autoPlay ||
        previous?.isGenerating != true ||
        next.isGenerating ||
        next.error != null ||
        next.messages.isEmpty) {
      return const ChatTTSAction.none();
    }
    final message = next.messages.last;
    if (message.role != MessageRole.assistant ||
        message.content.trim().isEmpty) {
      return const ChatTTSAction.none();
    }
    final revision =
        '${message.id}:${message.currentSwipeIndex}:${message.content.hashCode}';
    if (_lastSpokenRevision == revision) return const ChatTTSAction.none();
    _lastSpokenRevision = revision;
    return ChatTTSAction.speak(
      text: message.content,
      sourceId: message.id,
      characterId: message.characterId ?? next.character?.id,
    );
  }
}

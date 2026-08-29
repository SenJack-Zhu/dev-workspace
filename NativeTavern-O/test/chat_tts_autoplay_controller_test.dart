import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/domain/services/tts_service.dart';
import 'package:native_tavern/presentation/controllers/chat_tts_autoplay_controller.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';

void main() {
  const settings = TTSSettings(enabled: true, autoPlay: true);
  final now = DateTime(2026, 8, 8);
  final character = Character(
    id: 'character-1',
    name: 'Narrator',
    createdAt: now,
    modifiedAt: now,
  );
  final assistant = ChatMessage(
    id: 'message-1',
    chatId: 'chat-1',
    role: MessageRole.assistant,
    content: 'The road is clear.',
    timestamp: now,
  );

  test('emits one scoped speak action when generation completes', () {
    final controller = ChatTTSAutoPlayController();
    final previous = ActiveChatState(
      character: character,
      messages: [assistant],
      isGenerating: true,
    );
    final next = previous.copyWith(isGenerating: false);

    final action = controller.evaluate(
      previous: previous,
      next: next,
      settings: settings,
    );
    expect(action.kind, ChatTTSActionKind.speak);
    expect(action.text, assistant.content);
    expect(action.characterId, character.id);
    expect(action.sourceId, assistant.id);

    expect(
      controller
          .evaluate(previous: previous, next: next, settings: settings)
          .kind,
      ChatTTSActionKind.none,
    );
  });

  test('stops playback when a new user turn starts', () {
    final controller = ChatTTSAutoPlayController();
    final user = ChatMessage(
      id: 'message-2',
      chatId: 'chat-1',
      role: MessageRole.user,
      content: 'Continue',
      timestamp: now,
    );

    final action = controller.evaluate(
      previous: const ActiveChatState(isGenerating: false),
      next: ActiveChatState(messages: [user], isGenerating: true),
      settings: settings,
    );
    expect(action.kind, ChatTTSActionKind.stop);
  });

  test('disabled, manual, failed, and empty turns are ignored', () {
    final controller = ChatTTSAutoPlayController();
    final previous = ActiveChatState(
      messages: [assistant],
      isGenerating: true,
    );
    final completed = previous.copyWith(isGenerating: false);

    expect(
      controller
          .evaluate(
            previous: previous,
            next: completed,
            settings: const TTSSettings(enabled: false, autoPlay: true),
          )
          .kind,
      ChatTTSActionKind.none,
    );
    expect(
      controller
          .evaluate(
            previous: previous,
            next: completed,
            settings: const TTSSettings(enabled: true, autoPlay: false),
          )
          .kind,
      ChatTTSActionKind.none,
    );
    expect(
      controller
          .evaluate(
            previous: previous,
            next: completed.copyWith(error: 'failed'),
            settings: settings,
          )
          .kind,
      ChatTTSActionKind.none,
    );
  });
}

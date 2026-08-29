import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/services/story_play_service.dart';

/// Keeps generated memories inside the story line where they happened.
final class StoryMemoryScopeService {
  const StoryMemoryScopeService({required ChatRepository chatRepository})
      : _chats = chatRepository;

  final ChatRepository _chats;

  Future<List<MemoryScope>> readableChatScopes(String chatId) async {
    final boundaries = await _lineage(chatId);
    if (boundaries.isEmpty) return [MemoryScope.chat(chatId)];
    return [
      for (final boundary in boundaries) MemoryScope.chat(boundary.chat.id),
    ];
  }

  Future<bool> isMemoryVisible({
    required String chatId,
    required LongTermMemory memory,
  }) async {
    final sourceChatId = memory.source.sourceChatId;
    if (sourceChatId == null) return true;

    final lineage = await _lineage(chatId);
    if (lineage.isEmpty) return true;
    final current = lineage.first;
    final rootId = _storyRootId(current.chat);
    if (rootId == null) return true;

    final sourceChat = await _chats.getChat(sourceChatId);
    if (sourceChat == null ||
        (_storyRootId(sourceChat) ?? sourceChat.id) != rootId) {
      return true;
    }

    _StoryMemoryBoundary? sourceBoundary;
    for (final boundary in lineage) {
      if (boundary.chat.id == sourceChatId) {
        sourceBoundary = boundary;
        break;
      }
    }
    if (sourceBoundary == null) return false;
    final visibleThrough = sourceBoundary.visibleThroughOrdinal;
    if (visibleThrough == null) return true;

    final sourceMessageIds = memory.source.sourceMessageIds;
    if (sourceMessageIds.isEmpty) return true;
    final messages = await _chats.getMessages(sourceChatId);
    final ordinals = {
      for (var index = 0; index < messages.length; index++)
        messages[index].id: index,
    };
    return sourceMessageIds.every((id) {
      final ordinal = ordinals[id];
      return ordinal != null && ordinal <= visibleThrough;
    });
  }

  Future<List<_StoryMemoryBoundary>> _lineage(String chatId) async {
    final current = await _chats.getChat(chatId);
    if (current == null) return const [];
    final lineage = <_StoryMemoryBoundary>[
      _StoryMemoryBoundary(chat: current),
    ];
    final visited = <String>{current.id};
    var child = current;
    while (true) {
      final rootId = _storyRootId(child);
      if (rootId == null || child.id == rootId) break;
      final parentId = _stringSetting(child, storyParentChatIdKey);
      final forkOrdinal = _intSetting(child, storyForkOrdinalKey);
      if (parentId == null || forkOrdinal == null) break;
      final parent = await _chats.getChat(parentId);
      if (parent == null || !visited.add(parent.id)) break;
      lineage.add(
        _StoryMemoryBoundary(
          chat: parent,
          visibleThroughOrdinal: forkOrdinal,
        ),
      );
      child = parent;
    }
    return lineage;
  }
}

final class _StoryMemoryBoundary {
  const _StoryMemoryBoundary({
    required this.chat,
    this.visibleThroughOrdinal,
  });

  final Chat chat;
  final int? visibleThroughOrdinal;
}

String? _storyRootId(Chat chat) => _stringSetting(chat, storyRootChatIdKey);

String? _stringSetting(Chat chat, String key) {
  final value = chat.settings[key];
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

int? _intSetting(Chat chat, String key) {
  final value = chat.settings[key];
  return value is num && value >= 0 ? value.toInt() : null;
}

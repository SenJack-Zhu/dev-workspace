import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/models/story/story_chapter.dart';
import 'package:native_tavern/domain/repositories/long_term_memory_repository.dart';
import 'package:native_tavern/domain/repositories/story_repository.dart';

/// Public query API for story UI (#68) and later features.
///
/// [listChapters] only returns chapters whose start and end messages still
/// exist. [jumpTargetForChapter] maps a chapter to the message the chat
/// should scroll to.
final class StoryQueryService {
  StoryQueryService({
    required StoryRepository storyRepository,
    required LongTermMemoryRepository memoryRepository,
  })  : _storyRepository = storyRepository,
        _memoryRepository = memoryRepository;

  final StoryRepository _storyRepository;
  final LongTermMemoryRepository _memoryRepository;

  Future<List<StoryChapter>> listChapters(String chatId) {
    return _storyRepository.listByChatId(chatId);
  }

  Future<List<StoryChapter>> listRecent({int limit = 100}) {
    return _storyRepository.listRecent(limit: limit);
  }

  Future<StoryChapter?> getChapter(String chapterId) {
    return _storyRepository.getById(chapterId);
  }

  /// Message ID the chat should scroll to for [chapterId], or null when the
  /// chapter is gone or no longer belongs to the surviving world-line.
  Future<String?> jumpTargetForChapter(String chapterId) async {
    final chapter = await _storyRepository.getById(chapterId);
    if (chapter == null) return null;
    final surviving = await _storyRepository.listByChatId(chapter.chatId);
    for (final candidate in surviving) {
      if (candidate.id == chapter.id) return candidate.jumpMessageId;
    }
    return null;
  }

  Future<List<StoryChapterSearchResult>> searchChapters(
    String query, {
    required String chatId,
    int topK = 20,
  }) {
    return _storyRepository.search(query, chatId: chatId, topK: topK);
  }

  Future<List<LongTermMemorySearchResult>> searchMemories(
    String query, {
    required MemoryScope scope,
    int topK = 20,
  }) {
    return _memoryRepository.search(query, scope: scope, topK: topK);
  }
}

import 'package:native_tavern/data/models/story/story_chapter.dart';

/// One full-text chapter match. Lower [rank] values are more relevant.
final class StoryChapterSearchResult {
  const StoryChapterSearchResult({
    required this.chapter,
    required this.rank,
  });

  final StoryChapter chapter;
  final double rank;
}

/// Storage-independent chapter operations used by the story feature.
abstract interface class StoryRepository {
  Future<StoryChapter?> getById(String id);

  Future<StoryChapter> create(StoryChapter chapter);

  Future<StoryChapter> update(StoryChapter chapter);

  Future<void> delete(String id);

  /// Chapters whose start and end messages still exist in [chatId].
  Future<List<StoryChapter>> listByChatId(String chatId);

  /// Surviving chapters across chats, newest first.
  Future<List<StoryChapter>> listRecent({int limit = 100});

  /// Latest surviving chapter for [chatId], or null when none exist.
  Future<StoryChapter?> latestByChatId(String chatId);

  /// Full-text search over title and summary for one chat's surviving chapters.
  Future<List<StoryChapterSearchResult>> search(
    String query, {
    required String chatId,
    int topK = 20,
  });

  Future<void> rebuildSearchIndex();
}

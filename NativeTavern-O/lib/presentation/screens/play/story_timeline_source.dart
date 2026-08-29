import 'package:native_tavern/domain/services/story_play_service.dart';
import 'package:native_tavern/presentation/screens/play/story_models.dart';

/// Chapter list used by the story page.
abstract interface class StoryTimelineSource {
  Future<List<StoryChapterTimelineItem>> listChapters();
}

final class RepositoryStoryTimelineSource implements StoryTimelineSource {
  const RepositoryStoryTimelineSource(this._play);

  final StoryPlayService _play;

  @override
  Future<List<StoryChapterTimelineItem>> listChapters() async {
    final lines = await _play.listLines();
    return [
      for (final line in lines)
        for (final chapter in line.chapters)
          StoryChapterTimelineItem(
            id: chapter.id,
            chatId: chapter.chatId,
            title: chapter.title,
            summary: chapter.summary,
            narrative: chapter.narrative,
            jumpMessageId: chapter.jumpMessageId,
            createdAt: chapter.createdAt,
            chatTitle: line.chat.title,
            rootChatId: line.rootChatId,
            parentChatId: line.parentChatId,
            branchTitle: line.branchTitle,
            forkOrdinal: line.forkOrdinal,
          ),
    ];
  }
}

final class EmptyStoryTimelineSource implements StoryTimelineSource {
  const EmptyStoryTimelineSource();

  @override
  Future<List<StoryChapterTimelineItem>> listChapters() async => const [];
}

final class FakeStoryTimelineSource implements StoryTimelineSource {
  const FakeStoryTimelineSource(this.chapters);

  final List<StoryChapterTimelineItem> chapters;

  @override
  Future<List<StoryChapterTimelineItem>> listChapters() async =>
      List<StoryChapterTimelineItem>.unmodifiable(chapters);
}

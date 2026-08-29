import 'package:native_tavern/data/models/story/story_chapter.dart';

/// UI-facing chapter row for `/play/story`.
///
/// Shape matches the #65 query contract (`chatId`, title, summary, jump
/// message) so this page can swap from fake data to the real API later.
class StoryChapterTimelineItem {
  final String id;
  final String chatId;
  final String title;
  final String summary;
  final StoryChapterNarrative narrative;
  final String jumpMessageId;
  final DateTime createdAt;
  final String? chatTitle;
  final String? rootChatId;
  final String? parentChatId;
  final String? branchTitle;
  final int? forkOrdinal;

  const StoryChapterTimelineItem({
    required this.id,
    required this.chatId,
    required this.title,
    required this.summary,
    this.narrative = const StoryChapterNarrative(),
    required this.jumpMessageId,
    required this.createdAt,
    this.chatTitle,
    this.rootChatId,
    this.parentChatId,
    this.branchTitle,
    this.forkOrdinal,
  });

  String get chatPath => '/chat/$chatId?message=$jumpMessageId';
  String get effectiveRootChatId => rootChatId ?? chatId;
  String get effectiveBranchTitle => branchTitle ?? chatTitle ?? title;
}

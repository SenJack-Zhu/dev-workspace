import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/presentation/providers/story_providers.dart';
import 'package:native_tavern/presentation/screens/play/story_models.dart';
import 'package:native_tavern/presentation/screens/play/story_timeline_source.dart';

final storyRevisionProvider = StateProvider<int>((ref) => 0);

final storyTimelineSourceProvider = Provider<StoryTimelineSource>((ref) {
  return RepositoryStoryTimelineSource(ref.watch(storyPlayServiceProvider));
});

final storyTimelineProvider =
    FutureProvider<List<StoryChapterTimelineItem>>((ref) {
  ref.watch(storyRevisionProvider);
  return ref.watch(storyTimelineSourceProvider).listChapters();
});

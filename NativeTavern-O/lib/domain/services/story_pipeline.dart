import 'dart:async';

import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/long_term_memory_context_service.dart';
import 'package:native_tavern/domain/services/story_service.dart';

/// Gates the existing memory contributor behind the story master switch.
class StoryContextContributor extends ContextContributor {
  StoryContextContributor({
    required LongTermMemoryContextContributor memoryContributor,
    required bool Function() enabled,
  })  : _memoryContributor = memoryContributor,
        _enabled = enabled;

  static const contributorId = LongTermMemoryContextContributor.contributorId;

  final LongTermMemoryContextContributor _memoryContributor;
  final bool Function() _enabled;

  @override
  String get id => contributorId;

  @override
  int get order => _memoryContributor.order;

  @override
  int? get maxTokens => _memoryContributor.maxTokens;

  @override
  FutureOr<bool> isEnabled(ChatContextRequest request) {
    if (!_enabled()) return false;
    return _memoryContributor.isEnabled(request);
  }

  @override
  Future<ContextContribution> contribute(ChatContextRequest request) {
    return _memoryContributor.contribute(request);
  }

  @override
  FutureOr<void> onCancelled(ChatContextRequest request) {
    return _memoryContributor.onCancelled(request);
  }
}

/// Registers a write hook so story stays on the generation pipeline.
///
/// Persistence happens after the chat layer saves the assistant message. The
/// middleware only records that story is attached to this generation path.
class StoryWriteMiddleware extends ChatGenerationMiddleware {
  StoryWriteMiddleware({
    StoryService? storyService,
    Future<MemoryScope> Function(String chatId)? resolveScope,
    Future<List<ChatMessage>> Function(String chatId)? loadMessages,
    required bool Function() enabled,
  }) : _enabled = enabled;

  static const middlewareId = 'story.write';

  final bool Function() _enabled;

  @override
  String get id => middlewareId;

  @override
  int get order => 850;

  @override
  bool isEnabled(ChatGenerationRequest request) {
    return _enabled() &&
        (request.mode == ChatGenerationMode.send ||
            request.mode == ChatGenerationMode.groupResponse);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/long_term_memory_governance_service.dart';
import 'package:flutter/foundation.dart';
import 'package:native_tavern/domain/services/character_social_service.dart';
import 'package:native_tavern/data/models/operation_log.dart';
import 'package:native_tavern/data/repositories/operation_log_repository.dart';
import 'package:native_tavern/domain/services/moment_service.dart';
import 'package:native_tavern/domain/services/story_service.dart';
import 'package:path/path.dart' as p;

/// Persisted per-character wake times for the world loop.
final class WorldWakeState {
  WorldWakeState({
    this.lastTickAt,
    Map<String, DateTime>? nextWakeAt,
  }) : nextWakeAt = nextWakeAt ?? <String, DateTime>{};

  DateTime? lastTickAt;
  final Map<String, DateTime> nextWakeAt;

  Map<String, dynamic> toJson() => {
        if (lastTickAt != null) 'lastTickAt': lastTickAt!.toIso8601String(),
        'nextWakeAt': {
          for (final entry in nextWakeAt.entries)
            entry.key: entry.value.toIso8601String(),
        },
      };

  factory WorldWakeState.fromJson(Map<String, dynamic> json) {
    final rawWakes = json['nextWakeAt'];
    final wakes = <String, DateTime>{};
    if (rawWakes is Map) {
      for (final entry in rawWakes.entries) {
        final parsed = DateTime.tryParse('${entry.value}');
        if (parsed != null) wakes['${entry.key}'] = parsed.toUtc();
      }
    }
    return WorldWakeState(
      lastTickAt: DateTime.tryParse('${json['lastTickAt'] ?? ''}')?.toUtc(),
      nextWakeAt: wakes,
    );
  }
}

abstract interface class WorldWakeStore {
  Future<WorldWakeState> load();

  Future<void> save(WorldWakeState state);
}

final class MemoryWorldWakeStore implements WorldWakeStore {
  WorldWakeState state = WorldWakeState();

  @override
  Future<WorldWakeState> load() async => state;

  @override
  Future<void> save(WorldWakeState next) async {
    state = next;
  }
}

final class FileWorldWakeStore implements WorldWakeStore {
  FileWorldWakeStore(this.dataPath);

  final String dataPath;

  File get _file => File(p.join(dataPath, 'world_runtime.json'));

  @override
  Future<WorldWakeState> load() async {
    if (!_file.existsSync()) return WorldWakeState();
    try {
      final document = jsonDecode(await _file.readAsString());
      if (document is Map<String, dynamic>) {
        return WorldWakeState.fromJson(document);
      }
    } catch (_) {}
    return WorldWakeState();
  }

  @override
  Future<void> save(WorldWakeState state) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(state.toJson()), flush: true);
  }
}

/// Independent world loop: characters wake on their own cadence.
///
/// Opening moments only reads the feed. Chats become observations for the
/// next wake. This is the local, small-town clock — not a user action.
final class WorldRuntime {
  WorldRuntime({
    required MomentService momentService,
    required CharacterRepository characterRepository,
    CharacterSocialService? social,
    StoryService? story,
    OperationLogRepository? operations,
    required WorldWakeStore store,
    required bool Function() enabled,
    required LLMConfig Function() config,
    bool Function()? storyEnabled,
    DateTime Function()? now,
    this.tickInterval = defaultTickInterval,
    this.maxPostsPerTick = defaultMaxPostsPerTick,
    this.maxChaptersPerTick = defaultMaxChaptersPerTick,
    Duration Function(Character character, {required bool posted})? intervalFor,
    DateTime Function(Character character, DateTime now)? firstWake,
    void Function(int published)? onPublished,
    void Function()? onStoryChanged,
  })  : _moments = momentService,
        _characters = characterRepository,
        _social = social,
        _story = story,
        _operations = operations,
        _store = store,
        _enabled = enabled,
        _storyEnabled = storyEnabled ?? (() => story != null),
        _config = config,
        _now = now ?? (() => DateTime.now().toUtc()),
        _intervalFor = intervalFor ?? defaultIntervalFor,
        _firstWake = firstWake ?? defaultFirstWake,
        _onPublished = onPublished,
        _onStoryChanged = onStoryChanged;

  static const defaultTickInterval = Duration(minutes: 1);
  static const defaultMaxPostsPerTick = 2;
  static const defaultMaxChaptersPerTick = 3;
  static const configRetryDelay = Duration(seconds: 5);
  static const quietInterval = Duration(hours: 8);
  static const chattyInterval = Duration(minutes: 90);
  static const firstWakeWindow = Duration(minutes: 45);
  static const maxWakeAttempts = 8;
  static const maxRetryAge = Duration(hours: 24);

  final MomentService _moments;
  final CharacterRepository _characters;
  final CharacterSocialService? _social;
  final StoryService? _story;
  final OperationLogRepository? _operations;
  final WorldWakeStore _store;
  final bool Function() _enabled;
  final bool Function() _storyEnabled;
  final LLMConfig Function() _config;
  final DateTime Function() _now;
  final Duration Function(Character character, {required bool posted})
      _intervalFor;
  final DateTime Function(Character character, DateTime now) _firstWake;
  final void Function(int published)? _onPublished;
  final void Function()? _onStoryChanged;

  Timer? _timer;
  Timer? _configRetry;
  bool _busy = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(tickInterval, (_) {
      unawaited(tick());
    });
    debugPrint(
      'WorldRuntime started; tick every ${tickInterval.inSeconds}s',
    );
    unawaited(tick());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _configRetry?.cancel();
    _configRetry = null;
  }

  final Duration tickInterval;
  final int maxPostsPerTick;
  final int maxChaptersPerTick;

  Future<List<MomentPost>> tick() async {
    if (_busy) return const [];
    _busy = true;
    try {
      return await _tickUnlocked();
    } finally {
      _busy = false;
    }
  }

  Future<List<MomentPost>> _tickUnlocked() async {
    final momentsOn = _enabled();
    final storyOn = _storyEnabled() && _story != null;
    if (!momentsOn && !storyOn) {
      debugPrint('WorldRuntime tick skipped: moments and story are off');
      return const [];
    }
    final config = _config();
    if (!isMemoryLlmConfigured(config)) {
      debugPrint('WorldRuntime tick skipped: AI connection is not ready');
      _scheduleConfigRetry();
      return const [];
    }
    _configRetry?.cancel();
    _configRetry = null;

    final now = _now();
    final state = await _store.load();
    var feedChanged = 0;
    final published = <MomentPost>[];
    final recovered = await _retryOpenOperations(
      config: config,
      now: now,
      state: state,
      published: published,
      momentsOn: momentsOn,
      storyOn: storyOn,
    );
    feedChanged += recovered.feedChanged;
    final retryBusy = recovered.woken;
    if (!momentsOn) {
      state.lastTickAt = now;
      await _store.save(state);
      return published;
    }

    final characters = await _characters.getAllCharacters();
    if (characters.isEmpty) {
      state.lastTickAt = now;
      await _store.save(state);
      debugPrint('WorldRuntime tick: no characters yet');
      return published;
    }

    final due = <(Character, DateTime)>[];
    for (final character in characters) {
      if (retryBusy.contains(character.id)) continue;
      if (await _hasOpenWake(character.id)) continue;
      final wake = state.nextWakeAt[character.id] ?? _firstWake(character, now);
      state.nextWakeAt[character.id] = wake;
      if (!wake.isAfter(now)) {
        due.add((character, wake));
      }
    }
    due.sort((a, b) => a.$2.compareTo(b.$2));

    for (final (character, _) in due.take(maxPostsPerTick)) {
      debugPrint('WorldRuntime wake: ${character.name} (${character.id})');
      await _befriendGroupMates(character, now);
      final result = await _runLoggedWake(
        character,
        config,
        now,
        allowNewPost: await _moments.canPublishCharacterPost(now: now),
      );
      if (result.failed) continue;
      state.nextWakeAt[character.id] = now.add(
        _intervalFor(character, posted: result.post != null),
      );
      if (result.post != null) {
        published.add(result.post!);
        feedChanged++;
        final photo = result.post!.hasPhoto ? ' +photo' : '';
        final body = result.post!.publicBody.isEmpty
            ? '(photo)'
            : result.post!.publicBody;
        debugPrint('WorldRuntime posted: ${character.name}$photo — $body');
      } else if (result.comment != null) {
        feedChanged++;
        debugPrint(
          'WorldRuntime commented: ${character.name} — ${result.comment!.body}',
        );
      } else {
        if (result.feedChanged) feedChanged++;
        debugPrint('WorldRuntime skipped: ${character.name}');
      }
    }

    state.lastTickAt = now;
    await _store.save(state);
    debugPrint(
      'WorldRuntime tick: ${characters.length} characters, '
      '${due.length} due, ${published.length} posted',
    );
    if (feedChanged > 0) _onPublished?.call(feedChanged);
    return published;
  }

  Future<({int feedChanged, Set<String> woken})> _retryOpenOperations({
    required LLMConfig config,
    required DateTime now,
    required WorldWakeState state,
    required List<MomentPost> published,
    required bool momentsOn,
    required bool storyOn,
  }) async {
    final operations = _operations;
    if (operations == null) {
      return (feedChanged: 0, woken: <String>{});
    }
    var feedChanged = 0;
    var wroteStory = false;
    final woken = <String>{};
    if (storyOn) {
      wroteStory = await _writeDueStoryChapters(config, now);
    }
    if (momentsOn) {
      final due = await operations.listRetryable(
        now: now,
        limit: 4,
        kinds: const {OperationKind.momentWake, OperationKind.momentImage},
      );
      for (final job in due) {
        if (job.attempts >= maxWakeAttempts ||
            now.difference(job.createdAt) >= maxRetryAge) {
          await operations.stopRetrying(
            job,
            reason: job.attempts >= maxWakeAttempts
                ? 'Retry limit reached.'
                : 'Retry expired after 24 hours.',
            now: now,
          );
          debugPrint(
            'WorldRuntime abandoned ${job.kind.wireName} for '
            '${job.subjectId}: ${job.attempts} attempts',
          );
          continue;
        }
        switch (job.kind) {
          case OperationKind.storyChapter:
            continue;
          case OperationKind.momentWake:
            woken.add(job.subjectId);
            final character = await _characters.getCharacter(job.subjectId);
            if (character == null || character.isDeleted) {
              await operations.stopRetrying(
                job,
                reason: 'Character no longer exists.',
                now: now,
              );
              continue;
            }
            final claimed = await operations.begin(
              kind: OperationKind.momentWake,
              subjectId: job.subjectId,
              now: now,
            );
            final result = await _runLoggedWake(
              character,
              config,
              now,
              existing: claimed,
              allowNewPost: await _moments.canPublishCharacterPost(now: now),
            );
            if (!result.failed) {
              state.nextWakeAt[character.id] = now.add(
                _intervalFor(character, posted: result.post != null),
              );
            }
            if (result.post != null) {
              published.add(result.post!);
              feedChanged++;
              debugPrint(
                'WorldRuntime posted: ${character.name} — '
                '${result.post!.publicBody}',
              );
            } else if (result.comment != null) {
              feedChanged++;
              debugPrint(
                'WorldRuntime commented: ${character.name} — '
                '${result.comment!.body}',
              );
            } else if (result.feedChanged) {
              feedChanged++;
            }
          case OperationKind.momentImage:
            woken.add(job.subjectId);
            final character = await _characters.getCharacter(job.subjectId);
            if (character == null || character.isDeleted) {
              await operations.stopRetrying(
                job,
                reason: 'Character no longer exists.',
                now: now,
              );
              continue;
            }
            if (!await _moments.canPublishCharacterPost(now: now)) {
              await operations.markIncomplete(
                job,
                error: 'Waiting for the global character-post budget.',
                dueAt: now.add(MomentService.defaultGlobalPostInterval),
                now: now,
              );
              continue;
            }
            final posted = await _moments.retryImageJob(
              job,
              maxAttempts: maxWakeAttempts,
            );
            if (posted != null) {
              published.add(posted);
              feedChanged++;
              state.nextWakeAt[character.id] = now.add(
                _intervalFor(character, posted: true),
              );
            }
        }
      }
    }
    if (wroteStory) _onStoryChanged?.call();
    return (feedChanged: feedChanged, woken: woken);
  }

  Future<bool> _writeDueStoryChapters(LLMConfig config, DateTime now) async {
    final story = _story;
    if (story == null) return false;
    var wrote = false;
    var remaining = maxChaptersPerTick;
    final resumed = <String>{};

    final operations = _operations;
    if (operations != null) {
      final due = await operations.listRetryable(
        now: now,
        limit: maxChaptersPerTick,
        kinds: const {OperationKind.storyChapter},
      );
      for (final job in due) {
        if (remaining <= 0) break;
        resumed.add(job.subjectId);
        final wroteThis = await _closeDueChapter(
          job.subjectId,
          config,
          now,
          existing: job,
        );
        wrote = wrote || wroteThis;
        remaining--;
        while (wroteThis &&
            remaining > 0 &&
            await story.isChapterWindowDue(job.subjectId)) {
          final continued = await _closeDueChapter(job.subjectId, config, now);
          wrote = wrote || continued;
          remaining--;
          if (!continued) break;
        }
      }
    }

    for (final chatId in await story.listDueChatIds()) {
      if (remaining <= 0) break;
      if (resumed.contains(chatId)) continue;
      if (await operations?.findOpen(
            kind: OperationKind.storyChapter,
            subjectId: chatId,
          ) !=
          null) {
        continue;
      }
      final wroteThis = await _closeDueChapter(chatId, config, now);
      wrote = wrote || wroteThis;
      remaining--;
      while (wroteThis &&
          remaining > 0 &&
          await story.isChapterWindowDue(chatId)) {
        final continued = await _closeDueChapter(chatId, config, now);
        wrote = wrote || continued;
        remaining--;
        if (!continued) break;
      }
    }
    return wrote;
  }

  void _scheduleConfigRetry() {
    if (_configRetry?.isActive ?? false) return;
    _configRetry = Timer(configRetryDelay, () {
      unawaited(tick());
    });
  }

  Future<bool> _closeDueChapter(
    String chatId,
    LLMConfig config,
    DateTime now, {
    OperationLog? existing,
  }) async {
    final story = _story;
    if (story == null) return false;
    final operations = _operations;
    final job = existing ??
        await operations?.begin(
          kind: OperationKind.storyChapter,
          subjectId: chatId,
          now: now,
        );
    try {
      final result = await story.maybeCloseAfterTurn(
        chatId: chatId,
        config: config,
      );
      if (result.chapter != null) {
        if (job != null) await operations?.markCompleted(job, now: now);
        debugPrint('WorldRuntime wrote story chapter for $chatId');
        return true;
      }
      if (result.skipped && result.failure == null) {
        if (job != null) await operations?.markCompleted(job, now: now);
        return false;
      }
      if (job != null) {
        await operations?.markIncomplete(
          job,
          error: result.failure?.message ?? 'Chapter write failed.',
          dueAt: now.add(_retryDelay(job.attempts)),
          now: now,
        );
      }
    } catch (error) {
      if (job != null) {
        await operations?.markIncomplete(
          job,
          error: '$error',
          dueAt: now.add(_retryDelay(job.attempts)),
          now: now,
        );
      }
    }
    return false;
  }

  Future<bool> _hasOpenWake(String characterId) async {
    final operations = _operations;
    if (operations == null) return false;
    final open = await operations.findOpen(
      kind: OperationKind.momentWake,
      subjectId: characterId,
    );
    return open != null;
  }

  Future<MomentWakeResult> _runLoggedWake(
    Character character,
    LLMConfig config,
    DateTime now, {
    OperationLog? existing,
    bool allowNewPost = true,
  }) async {
    final operations = _operations;
    final job = operations == null
        ? null
        : existing ??
            await operations.begin(
              kind: OperationKind.momentWake,
              subjectId: character.id,
              now: now,
            );
    final result = await _wakeCharacter(
      character,
      config,
      allowNewPost: allowNewPost,
    );
    if (operations == null || job == null) return result;
    if (result.failed) {
      if (job.attempts >= maxWakeAttempts) {
        await operations.stopRetrying(
          job,
          reason: 'Retry limit reached.',
          now: now,
        );
        return result;
      }
      await operations.markIncomplete(
        job,
        error: 'Moment wake failed.',
        dueAt: now.add(_retryDelay(job.attempts)),
        now: now,
      );
      debugPrint(
        'WorldRuntime will retry ${character.name} (attempt ${job.attempts})',
      );
      return result;
    }
    await operations.markCompleted(job, now: now);
    return result;
  }

  Future<MomentWakeResult> _wakeCharacter(
    Character character,
    LLMConfig config, {
    required bool allowNewPost,
  }) async {
    return _moments.attemptCharacter(
      character: character,
      config: config,
      allowNewPost: allowNewPost,
    );
  }

  static Duration _retryDelay(int attempts) {
    final minutes = 1 << (attempts - 1).clamp(0, 4);
    return Duration(minutes: minutes);
  }

  Future<void> _befriendGroupMates(Character character, DateTime now) async {
    final social = _social;
    if (social == null) return;
    final added = await social.addGroupMates(character: character, now: now);
    for (final link in added) {
      final other = await _characters.getCharacter(link.otherId(character.id));
      if (other == null) continue;
      debugPrint(
        'WorldRuntime friends: ${character.name} added ${other.name}',
      );
      await _moments.rememberFriendship(
        characterId: character.id,
        friendName: other.name,
      );
      await _moments.rememberFriendship(
        characterId: other.id,
        friendName: character.name,
      );
    }
  }

  static Duration defaultIntervalFor(
    Character character, {
    required bool posted,
  }) {
    final talk = character.talkativeness.clamp(0.0, 1.0);
    final span = quietInterval.inMilliseconds - chattyInterval.inMilliseconds;
    final base =
        chattyInterval + Duration(milliseconds: (span * (1 - talk)).round());
    return posted ? base + const Duration(minutes: 30) : base;
  }

  static DateTime defaultFirstWake(Character character, DateTime now) {
    final seconds = character.id.hashCode.abs() % firstWakeWindow.inSeconds;
    return now.add(Duration(seconds: seconds));
  }
}

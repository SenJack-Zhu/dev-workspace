import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/story/story_chapter.dart';
import 'package:native_tavern/domain/repositories/story_repository.dart';

class DriftStoryRepository implements StoryRepository {
  DriftStoryRepository(this._database);

  final AppDatabase _database;

  @override
  Future<StoryChapter?> getById(String id) async {
    final row = await (_database.select(_database.storyChapters)
          ..where((table) => table.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<StoryChapter> create(StoryChapter chapter) async {
    await _database.into(_database.storyChapters).insert(_toCompanion(chapter));
    return (await getById(chapter.id))!;
  }

  @override
  Future<StoryChapter> update(StoryChapter chapter) async {
    await _require(chapter.id);
    await (_database.update(_database.storyChapters)
          ..where((table) => table.id.equals(chapter.id)))
        .write(_toCompanion(chapter));
    return (await getById(chapter.id))!;
  }

  @override
  Future<void> delete(String id) async {
    await (_database.delete(_database.storyChapters)
          ..where((table) => table.id.equals(id)))
        .go();
  }

  @override
  Future<List<StoryChapter>> listByChatId(String chatId) async {
    final rows = await _survivingChapterQuery(chatId: chatId).get();
    return rows
        .map((row) => _toModel(row.readTable(_database.storyChapters)))
        .toList(growable: false);
  }

  @override
  Future<List<StoryChapter>> listRecent({int limit = 100}) async {
    final query = _survivingChapterQuery(newestFirst: true);
    if (limit > 0) query.limit(limit);
    final rows = await query.get();
    return rows
        .map((row) => _toModel(row.readTable(_database.storyChapters)))
        .toList(growable: false);
  }

  @override
  Future<StoryChapter?> latestByChatId(String chatId) async {
    final query = _survivingChapterQuery(chatId: chatId)..limit(1);
    final row = await query.getSingleOrNull();
    return row == null
        ? null
        : _toModel(row.readTable(_database.storyChapters));
  }

  @override
  Future<List<StoryChapterSearchResult>> search(
    String query, {
    required String chatId,
    int topK = 20,
  }) async {
    if (topK <= 0) {
      throw RangeError.range(topK, 1, null, 'topK');
    }
    final matchQuery = _plainTextFtsQuery(query);
    if (matchQuery == null) return const [];

    final rows = await _database.customSelect(
      '''
        SELECT c.id AS chapter_id, bm25(story_chapters_fts) AS rank
        FROM story_chapters_fts
        JOIN story_chapters AS c
          ON c.rowid = story_chapters_fts.rowid
        JOIN messages AS start_message
          ON start_message.id = c.start_message_id
         AND start_message.chat_id = c.chat_id
        JOIN messages AS end_message
          ON end_message.id = c.end_message_id
         AND end_message.chat_id = c.chat_id
        WHERE story_chapters_fts MATCH ?
          AND c.chat_id = ?
        ORDER BY bm25(story_chapters_fts) ASC,
                 c.end_ordinal DESC,
                 c.created_at DESC,
                 c.id ASC
        LIMIT ?
      ''',
      variables: [
        Variable<String>(matchQuery),
        Variable<String>(chatId),
        Variable<int>(topK),
      ],
      readsFrom: {
        _database.storyChapters,
        _database.messages,
      },
    ).get();

    final results = <StoryChapterSearchResult>[];
    for (final row in rows) {
      final chapterId = row.read<String>('chapter_id');
      final chapter = await getById(chapterId);
      if (chapter == null) {
        throw StateError('FTS index references missing chapter $chapterId.');
      }
      results.add(
        StoryChapterSearchResult(
          chapter: chapter,
          rank: row.read<double>('rank'),
        ),
      );
    }
    return results;
  }

  @override
  Future<void> rebuildSearchIndex() {
    return _database.rebuildStoryChapterSearchIndex();
  }

  JoinedSelectStatement<HasResultSet, dynamic> _survivingChapterQuery({
    String? chatId,
    bool newestFirst = false,
  }) {
    final startMessage = _database.alias(_database.messages, 'start_message');
    final endMessage = _database.alias(_database.messages, 'end_message');
    final query = _database.select(_database.storyChapters).join([
      innerJoin(
        startMessage,
        startMessage.id.equalsExp(_database.storyChapters.startMessageId) &
            startMessage.chatId.equalsExp(_database.storyChapters.chatId),
      ),
      innerJoin(
        endMessage,
        endMessage.id.equalsExp(_database.storyChapters.endMessageId) &
            endMessage.chatId.equalsExp(_database.storyChapters.chatId),
      ),
    ]);
    if (chatId != null) {
      query.where(_database.storyChapters.chatId.equals(chatId));
    }
    query.orderBy(
      newestFirst
          ? [
              OrderingTerm.desc(_database.storyChapters.createdAt),
              OrderingTerm.desc(_database.storyChapters.endOrdinal),
              OrderingTerm.asc(_database.storyChapters.id),
            ]
          : [
              OrderingTerm.desc(_database.storyChapters.endOrdinal),
              OrderingTerm.desc(_database.storyChapters.createdAt),
              OrderingTerm.asc(_database.storyChapters.id),
            ],
    );
    return query;
  }

  StoryChapter _toModel(StoryChapterRow row) {
    return StoryChapter(
      id: row.id,
      chatId: row.chatId,
      title: row.title,
      summary: row.summary,
      narrative: _decodeNarrative(row.narrativeJson),
      startMessageId: row.startMessageId,
      endMessageId: row.endMessageId,
      startOrdinal: row.startOrdinal,
      endOrdinal: row.endOrdinal,
      origin: StoryChapterOrigin.values.firstWhere(
        (value) => value.name == row.origin,
        orElse: () => throw StateError(
          'Unsupported persisted chapter origin: ${row.origin}',
        ),
      ),
      createdAt: row.createdAt.toUtc(),
      updatedAt: row.updatedAt.toUtc(),
    );
  }

  StoryChaptersCompanion _toCompanion(StoryChapter chapter) {
    return StoryChaptersCompanion(
      id: Value(chapter.id),
      chatId: Value(chapter.chatId),
      title: Value(chapter.title),
      summary: Value(chapter.summary),
      narrativeJson: Value(jsonEncode(chapter.narrative.toJson())),
      startMessageId: Value(chapter.startMessageId),
      endMessageId: Value(chapter.endMessageId),
      startOrdinal: Value(chapter.startOrdinal),
      endOrdinal: Value(chapter.endOrdinal),
      origin: Value(chapter.origin.name),
      createdAt: Value(chapter.createdAt),
      updatedAt: Value(chapter.updatedAt),
    );
  }

  Future<void> _require(String id) async {
    if (await getById(id) == null) {
      throw StateError('Chapter $id does not exist.');
    }
  }
}

StoryChapterNarrative _decodeNarrative(String source) {
  try {
    final value = jsonDecode(source);
    return value is Map
        ? StoryChapterNarrative.fromJson(Map<String, dynamic>.from(value))
        : const StoryChapterNarrative();
  } catch (_) {
    return const StoryChapterNarrative();
  }
}

String? _plainTextFtsQuery(String input) {
  final tokens = RegExp(
    r'[\p{L}\p{N}]+',
    unicode: true,
  ).allMatches(input).map((match) => match.group(0)!).toList();
  if (tokens.isEmpty) return null;
  return tokens.map((token) => '"$token"*').join(' AND ');
}

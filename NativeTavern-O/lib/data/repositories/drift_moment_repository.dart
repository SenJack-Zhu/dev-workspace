import 'package:drift/drift.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/domain/repositories/moment_repository.dart';

class DriftMomentRepository implements MomentRepository {
  DriftMomentRepository(this._database);

  final AppDatabase _database;

  @override
  Future<MomentPost?> getById(String id) async {
    final row = await (_database.select(_database.momentPosts)
          ..where((table) => table.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toPost(row);
  }

  @override
  Future<MomentPost> create(MomentPost post) async {
    await _database.into(_database.momentPosts).insert(_toPostCompanion(post));
    return (await getById(post.id))!;
  }

  @override
  Future<MomentPost> update(MomentPost post) async {
    await (_database.update(_database.momentPosts)
          ..where((table) => table.id.equals(post.id)))
        .write(_toPostCompanion(post));
    return (await getById(post.id))!;
  }

  @override
  Future<void> delete(String id) async {
    await (_database.delete(_database.momentPosts)
          ..where((table) => table.id.equals(id)))
        .go();
  }

  @override
  Future<List<MomentPost>> listByChatId(String chatId) async {
    final rows = await _feedQuery(
      extra: _database.momentPosts.chatId.equals(chatId),
    ).get();
    return rows
        .map((row) => _toPost(row.readTable(_database.momentPosts)))
        .toList(growable: false);
  }

  @override
  Future<List<MomentPost>> listAll() async {
    final rows = await _feedQuery().get();
    return rows
        .map((row) => _toPost(row.readTable(_database.momentPosts)))
        .toList(growable: false);
  }

  @override
  Future<List<MomentPost>> listPage({int limit = 24, int offset = 0}) async {
    final rows = await (_feedQuery()
          ..limit(limit, offset: offset < 0 ? 0 : offset))
        .get();
    return rows
        .map((row) => _toPost(row.readTable(_database.momentPosts)))
        .toList(growable: false);
  }

  @override
  Future<MomentPost?> findByChapterId(String chapterId) async {
    final query = _feedQuery(
      extra: _database.momentPosts.chapterId.equals(chapterId),
    )..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _toPost(row.readTable(_database.momentPosts));
  }

  @override
  Future<MomentComment> addComment(MomentComment comment) async {
    await _database
        .into(_database.momentComments)
        .insert(_toCommentCompanion(comment));
    return comment;
  }

  @override
  Future<List<MomentComment>> listComments(String postId) async {
    final rows = await (_database.select(_database.momentComments)
          ..where((table) => table.postId.equals(postId))
          ..orderBy([(table) => OrderingTerm.asc(table.createdAt)]))
        .get();
    return rows.map(_toComment).toList(growable: false);
  }

  @override
  Future<void> deleteComment(String commentId) async {
    await (_database.delete(_database.momentComments)
          ..where((table) => table.id.equals(commentId)))
        .go();
  }

  @override
  Future<bool> toggleLike(String postId, String authorId,
      {DateTime? at}) async {
    final existing = await (_database.select(_database.momentPostLikes)
          ..where((table) =>
              table.postId.equals(postId) & table.authorId.equals(authorId)))
        .getSingleOrNull();
    if (existing != null) {
      await (_database.delete(_database.momentPostLikes)
            ..where((table) =>
                table.postId.equals(postId) & table.authorId.equals(authorId)))
          .go();
      return false;
    }
    await _database.into(_database.momentPostLikes).insert(
          MomentPostLikesCompanion(
            postId: Value(postId),
            authorId: Value(authorId),
            createdAt: Value(at ?? DateTime.now().toUtc()),
          ),
        );
    return true;
  }

  @override
  Future<int> likeCount(String postId) async {
    final count = await (_database.selectOnly(_database.momentPostLikes)
          ..addColumns([_database.momentPostLikes.authorId.count()])
          ..where(_database.momentPostLikes.postId.equals(postId)))
        .map((row) => row.read(_database.momentPostLikes.authorId.count()))
        .getSingle();
    return count ?? 0;
  }

  @override
  Future<bool> hasLiked(String postId, String authorId) async {
    final row = await (_database.select(_database.momentPostLikes)
          ..where((table) =>
              table.postId.equals(postId) & table.authorId.equals(authorId)))
        .getSingleOrNull();
    return row != null;
  }

  JoinedSelectStatement<HasResultSet, dynamic> _feedQuery({
    Expression<bool>? extra,
  }) {
    final chapter = _database.alias(_database.storyChapters, 'source_chapter');
    final startMessage = _database.alias(_database.messages, 'start_message');
    final endMessage = _database.alias(_database.messages, 'end_message');
    final authorCharacter =
        _database.alias(_database.characters, 'moment_author_character');
    final query = _database.select(_database.momentPosts).join([
      leftOuterJoin(
        chapter,
        chapter.id.equalsExp(_database.momentPosts.chapterId),
      ),
      leftOuterJoin(
        startMessage,
        startMessage.id.equalsExp(chapter.startMessageId) &
            startMessage.chatId.equalsExp(chapter.chatId),
      ),
      leftOuterJoin(
        endMessage,
        endMessage.id.equalsExp(chapter.endMessageId) &
            endMessage.chatId.equalsExp(chapter.chatId),
      ),
      leftOuterJoin(
        authorCharacter,
        authorCharacter.id.equalsExp(_database.momentPosts.authorId),
      ),
    ])
      ..where(
        (_database.momentPosts.origin.isNotIn([MomentPostOrigin.chapter.name]) |
                (startMessage.id.isNotNull() & endMessage.id.isNotNull())) &
            (_database.momentPosts.origin
                    .isNotIn([MomentPostOrigin.character.name]) |
                (authorCharacter.id.isNotNull() &
                    authorCharacter.isDeleted.equals(false))),
      )
      ..orderBy([
        OrderingTerm.desc(_database.momentPosts.createdAt),
        OrderingTerm.desc(_database.momentPosts.id),
      ]);
    if (extra != null) query.where(extra);
    return query;
  }

  MomentPost _toPost(MomentPostRow row) {
    return MomentPost(
      id: row.id,
      chatId: row.chatId,
      authorId: row.authorId,
      authorName: row.authorName,
      publicBody: row.publicBody,
      imagePath: row.imagePath,
      factBody: row.factBody,
      chapterId: row.chapterId,
      origin: MomentPostOrigin.values.firstWhere(
        (value) => value.name == row.origin,
      ),
      status: MomentPostStatus.values.firstWhere(
        (value) => value.name == row.status,
      ),
      writeToWorld: row.writeToWorld,
      createdAt: row.createdAt.toUtc(),
      updatedAt: row.updatedAt.toUtc(),
    );
  }

  MomentPostsCompanion _toPostCompanion(MomentPost post) {
    return MomentPostsCompanion(
      id: Value(post.id),
      chatId: Value(post.chatId),
      authorId: Value(post.authorId),
      authorName: Value(post.authorName),
      publicBody: Value(post.publicBody),
      imagePath: Value(post.imagePath),
      factBody: Value(post.factBody),
      chapterId: Value(post.chapterId),
      origin: Value(post.origin.name),
      status: Value(post.status.name),
      writeToWorld: Value(post.writeToWorld),
      createdAt: Value(post.createdAt),
      updatedAt: Value(post.updatedAt),
    );
  }

  MomentComment _toComment(MomentCommentRow row) {
    return MomentComment(
      id: row.id,
      postId: row.postId,
      authorId: row.authorId,
      authorName: row.authorName,
      body: row.body,
      kind: MomentCommentKind.values.firstWhere(
        (value) => value.name == row.kind,
      ),
      parentCommentId: row.parentCommentId,
      createdAt: row.createdAt.toUtc(),
    );
  }

  MomentCommentsCompanion _toCommentCompanion(MomentComment comment) {
    return MomentCommentsCompanion(
      id: Value(comment.id),
      postId: Value(comment.postId),
      authorId: Value(comment.authorId),
      authorName: Value(comment.authorName),
      body: Value(comment.body),
      kind: Value(comment.kind.name),
      parentCommentId: Value(comment.parentCommentId),
      createdAt: Value(comment.createdAt),
    );
  }
}

import 'package:drift/drift.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character_friendship.dart';
import 'package:uuid/uuid.dart';

/// Raw-SQL friendship store. The table is created in schema v20.
final class CharacterFriendshipRepository {
  CharacterFriendshipRepository(this._db, {String Function()? createId})
      : _createId = createId ?? const Uuid().v4;

  final AppDatabase _db;
  final String Function() _createId;

  Future<List<CharacterFriendship>> listForCharacter(String characterId) async {
    final rows = await _db.customSelect(
      'SELECT * FROM character_friendships '
      'WHERE left_id = ? OR right_id = ? '
      'ORDER BY created_at DESC',
      variables: [
        Variable<String>(characterId),
        Variable<String>(characterId),
      ],
    ).get();
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<bool> areFriends(String a, String b) async {
    final (left, right) = CharacterFriendship.orderedPair(a, b);
    final row = await _db.customSelect(
      'SELECT 1 AS found FROM character_friendships '
      'WHERE left_id = ? AND right_id = ? LIMIT 1',
      variables: [Variable<String>(left), Variable<String>(right)],
    ).getSingleOrNull();
    return row != null;
  }

  Future<CharacterFriendship?> addFriends({
    required String a,
    required String b,
    String? sourceGroupId,
    DateTime? now,
  }) async {
    if (a == b) return null;
    final (left, right) = CharacterFriendship.orderedPair(a, b);
    if (await areFriends(left, right)) return null;
    final createdAt = (now ?? DateTime.now()).toUtc();
    final friendship = CharacterFriendship(
      id: _createId(),
      leftId: left,
      rightId: right,
      sourceGroupId: sourceGroupId,
      createdAt: createdAt,
    );
    await _db.customStatement(
      'INSERT INTO character_friendships '
      '(id, left_id, right_id, source_group_id, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        friendship.id,
        friendship.leftId,
        friendship.rightId,
        friendship.sourceGroupId,
        createdAt.millisecondsSinceEpoch,
      ],
    );
    return friendship;
  }

  CharacterFriendship _fromRow(QueryRow row) {
    final data = row.data;
    return CharacterFriendship(
      id: data['id'] as String,
      leftId: data['left_id'] as String,
      rightId: data['right_id'] as String,
      sourceGroupId: data['source_group_id'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        data['created_at'] as int,
        isUtc: true,
      ),
    );
  }
}

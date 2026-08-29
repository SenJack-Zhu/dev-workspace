import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/data/database/database.dart' hide Group;
import 'package:native_tavern/data/database/database.dart' as db;
import 'package:native_tavern/data/models/group.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:uuid/uuid.dart';

/// Provider for group repository
final groupRepositoryProvider = Provider<GroupRepository>((ref) {
  final database = ref.watch(databaseProvider);
  return GroupRepository(database);
});

/// Repository for managing group data
class GroupRepository {
  final AppDatabase _db;
  static const _uuid = Uuid();

  GroupRepository(this._db);

  /// Get all groups
  Future<List<Group>> getAllGroups() async {
    final rows = await _db.select(_db.groups).get();
    return Future.wait(rows.map((row) => _visibleGroup(_groupFromRow(row))));
  }

  /// Get group by ID
  Future<Group?> getGroup(String id) async {
    final row = await (_db.select(_db.groups)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _visibleGroup(_groupFromRow(row));
  }

  /// Create a new group
  Future<Group> createGroup({
    required String name,
    String? description,
    List<String> characterIds = const [],
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();

    final members = characterIds.asMap().entries.map((e) {
      return GroupMember(
        characterId: e.value,
        insertionOrder: e.key,
      );
    }).toList();

    final group = Group(
      id: id,
      name: name,
      description: description,
      members: members,
      createdAt: now,
      modifiedAt: now,
    );

    await _db.into(_db.groups).insert(_groupToCompanion(group));
    return group;
  }

  /// Update an existing group
  Future<Group> updateGroup(Group group) async {
    // Keep references to deleted members in storage. They are hidden from
    // callers, but retaining them preserves historical group chats and lets a
    // later character restore reappear in the group.
    final raw = await _getRawGroup(group.id);
    final rawIds =
        raw?.members.map((member) => member.characterId).toSet() ?? {};
    final rawCharacters = rawIds.isEmpty
        ? const <db.Character>[]
        : await (_db.select(_db.characters)
              ..where((character) => character.id.isIn(rawIds)))
            .get();
    final activeRawIds = rawCharacters
        .where((character) => !character.isDeleted)
        .map((character) => character.id)
        .toSet();
    final hiddenMembers = raw == null
        ? const <GroupMember>[]
        : raw.members
            .where((member) => !activeRawIds.contains(member.characterId))
            .toList(growable: false);
    final updatedGroup = group.copyWith(
      members: [...group.members, ...hiddenMembers],
      modifiedAt: DateTime.now(),
    );
    await (_db.update(_db.groups)..where((t) => t.id.equals(group.id)))
        .write(_groupToCompanion(updatedGroup));
    return updatedGroup;
  }

  /// Delete a group
  Future<void> deleteGroup(String id) async {
    await _db.transaction(() async {
      final chats = await (_db.select(_db.chats)
            ..where((table) => table.groupId.equals(id)))
          .get();
      for (final chat in chats) {
        await (_db.delete(_db.bookmarks)
              ..where((table) => table.chatId.equals(chat.id)))
            .go();
        await (_db.delete(_db.messages)
              ..where((table) => table.chatId.equals(chat.id)))
            .go();
      }
      await (_db.delete(_db.chats)..where((table) => table.groupId.equals(id)))
          .go();
      await (_db.delete(_db.groups)..where((table) => table.id.equals(id)))
          .go();
    });
  }

  /// Add a character to a group
  Future<Group> addMember(String groupId, String characterId) async {
    final group = await getGroup(groupId);
    if (group == null) throw Exception('Group not found');

    if (group.members.any((m) => m.characterId == characterId)) {
      return group; // Already a member
    }

    final newMember = GroupMember(
      characterId: characterId,
      insertionOrder: group.members.length,
      talkativeness: await _characterTalkativeness(characterId),
    );

    return updateGroup(group.copyWith(
      members: [...group.members, newMember],
    ));
  }

  /// Read the character's talkativeness (0.0-1.0 in extensions)
  /// as a 0-100 group member weight, defaulting to 50
  Future<int> _characterTalkativeness(String characterId) async {
    try {
      final row = await (_db.select(_db.characters)
            ..where((t) => t.id.equals(characterId)))
          .getSingleOrNull();
      if (row == null) return 50;
      final extensions = jsonDecode(row.extensionsJson) as Map<String, dynamic>;
      final value = extensions['talkativeness'];
      final talkativeness = value is num
          ? value.toDouble()
          : value is String
              ? double.tryParse(value) ?? 0.5
              : 0.5;
      return (talkativeness * 100).round().clamp(0, 100);
    } catch (_) {
      return 50;
    }
  }

  /// Remove a character from a group
  Future<Group> removeMember(String groupId, String characterId) async {
    final group = await getGroup(groupId);
    if (group == null) throw Exception('Group not found');

    return updateGroup(group.copyWith(
      members:
          group.members.where((m) => m.characterId != characterId).toList(),
    ));
  }

  /// Update a member's settings
  Future<Group> updateMember(String groupId, GroupMember member) async {
    final group = await getGroup(groupId);
    if (group == null) throw Exception('Group not found');

    final members = group.members.map((m) {
      if (m.characterId == member.characterId) {
        return member;
      }
      return m;
    }).toList();

    return updateGroup(group.copyWith(members: members));
  }

  /// Mute/unmute a member
  Future<Group> toggleMemberMute(String groupId, String characterId) async {
    final group = await getGroup(groupId);
    if (group == null) throw Exception('Group not found');

    final members = group.members.map((m) {
      if (m.characterId == characterId) {
        return m.copyWith(isMuted: !m.isMuted);
      }
      return m;
    }).toList();

    return updateGroup(group.copyWith(members: members));
  }

  /// Update group settings
  Future<Group> updateSettings(String groupId, GroupSettings settings) async {
    final group = await getGroup(groupId);
    if (group == null) throw Exception('Group not found');

    return updateGroup(group.copyWith(settings: settings));
  }

  /// Reorder members
  Future<Group> reorderMembers(
      String groupId, List<String> orderedCharacterIds) async {
    final group = await getGroup(groupId);
    if (group == null) throw Exception('Group not found');

    final members = orderedCharacterIds.asMap().entries.map((e) {
      final existing = group.members.firstWhere(
        (m) => m.characterId == e.value,
        orElse: () => GroupMember(characterId: e.value),
      );
      return existing.copyWith(insertionOrder: e.key);
    }).toList();

    return updateGroup(group.copyWith(members: members));
  }

  // Private helpers

  Group _groupFromRow(db.Group row) {
    return Group(
      id: row.id,
      name: row.name,
      description: row.description,
      members: _parseMembersJson(row.membersJson),
      settings: _parseSettingsJson(row.settingsJson),
      avatarPath: row.avatarPath,
      createdAt: row.createdAt,
      modifiedAt: row.modifiedAt,
    );
  }

  Future<Group?> _getRawGroup(String id) async {
    final row = await (_db.select(_db.groups)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _groupFromRow(row);
  }

  Future<Group> _visibleGroup(Group group) async {
    if (group.members.isEmpty) return group;
    final ids = group.members.map((member) => member.characterId).toSet();
    final rows = await (_db.select(_db.characters)
          ..where((character) => character.id.isIn(ids)))
        .get();
    final activeIds =
        rows.where((row) => !row.isDeleted).map((row) => row.id).toSet();
    return group.copyWith(
      members: group.members
          .where((member) => activeIds.contains(member.characterId))
          .toList(growable: false),
    );
  }

  GroupsCompanion _groupToCompanion(Group group) {
    return GroupsCompanion(
      id: Value(group.id),
      name: Value(group.name),
      description: Value(group.description),
      membersJson:
          Value(jsonEncode(group.members.map((m) => m.toJson()).toList())),
      settingsJson: Value(jsonEncode(group.settings.toJson())),
      avatarPath: Value(group.avatarPath),
      createdAt: Value(group.createdAt),
      modifiedAt: Value(group.modifiedAt),
    );
  }

  List<GroupMember> _parseMembersJson(String json) {
    try {
      final list = jsonDecode(json) as List;
      return list
          .map((m) => GroupMember.fromJson(m as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  GroupSettings _parseSettingsJson(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return GroupSettings.fromJson(map);
    } catch (_) {
      return const GroupSettings();
    }
  }
}

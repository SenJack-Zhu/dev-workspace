import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/character_friendship.dart';
import 'package:native_tavern/data/models/group.dart';
import 'package:native_tavern/data/repositories/character_friendship_repository.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/group_repository.dart';

/// Group-mates may become friends; accepted pairs form the social graph.
final class CharacterSocialService {
  CharacterSocialService({
    required CharacterFriendshipRepository friendships,
    required GroupRepository groups,
    required CharacterRepository characters,
    this.maxNewFriendsPerWake = 2,
  })  : _friendships = friendships,
        _groups = groups,
        _characters = characters;

  final CharacterFriendshipRepository _friendships;
  final GroupRepository _groups;
  final CharacterRepository _characters;
  final int maxNewFriendsPerWake;

  Future<List<Character>> friendsOf(String characterId) async {
    final links = await _friendships.listForCharacter(characterId);
    final friends = <Character>[];
    for (final link in links) {
      final other = await _characters.getCharacter(link.otherId(characterId));
      if (other != null) friends.add(other);
    }
    return friends;
  }

  Future<List<CharacterFriendship>> addGroupMates({
    required Character character,
    DateTime? now,
  }) async {
    final groups = await _groups.getAllGroups();
    final added = <CharacterFriendship>[];
    for (final group in groups) {
      if (!_inGroup(group, character.id)) continue;
      for (final member in group.members) {
        if (added.length >= maxNewFriendsPerWake) return added;
        if (member.characterId == character.id) continue;
        final friendship = await _friendships.addFriends(
          a: character.id,
          b: member.characterId,
          sourceGroupId: group.id,
          now: now,
        );
        if (friendship != null) added.add(friendship);
      }
    }
    return added;
  }

  bool _inGroup(Group group, String characterId) {
    return group.members.any((member) => member.characterId == characterId);
  }
}

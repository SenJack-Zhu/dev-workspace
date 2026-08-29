/// An accepted friendship between two character cards.
final class CharacterFriendship {
  const CharacterFriendship({
    required this.id,
    required this.leftId,
    required this.rightId,
    this.sourceGroupId,
    required this.createdAt,
  });

  final String id;
  final String leftId;
  final String rightId;
  final String? sourceGroupId;
  final DateTime createdAt;

  String otherId(String characterId) {
    return characterId == leftId ? rightId : leftId;
  }

  bool involves(String characterId) {
    return characterId == leftId || characterId == rightId;
  }

  static (String, String) orderedPair(String a, String b) {
    return a.compareTo(b) <= 0 ? (a, b) : (b, a);
  }
}

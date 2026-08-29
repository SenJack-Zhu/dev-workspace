/// Chat layout mode for message display
enum ChatLayoutMode {
  /// Classic bubble style chat
  bubble,

  /// Visual novel style - full screen background with text overlay at bottom
  visualNovel,
}

extension ChatLayoutModeExtension on ChatLayoutMode {
  /// Get display name for this layout mode
  String get displayName {
    switch (this) {
      case ChatLayoutMode.bubble:
        return 'Bubble';
      case ChatLayoutMode.visualNovel:
        return 'Visual novel';
    }
  }

  /// Toggle to the other mode
  ChatLayoutMode get toggle {
    return this == ChatLayoutMode.bubble
        ? ChatLayoutMode.visualNovel
        : ChatLayoutMode.bubble;
  }

  /// Create from string
  static ChatLayoutMode fromString(String value) {
    switch (value) {
      case 'visualNovel':
        return ChatLayoutMode.visualNovel;
      default:
        return ChatLayoutMode.bubble;
    }
  }

  /// Convert to string
  String toStringValue() {
    switch (this) {
      case ChatLayoutMode.bubble:
        return 'bubble';
      case ChatLayoutMode.visualNovel:
        return 'visualNovel';
    }
  }
}

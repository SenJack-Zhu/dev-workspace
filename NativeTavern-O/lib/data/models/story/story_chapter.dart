import 'package:equatable/equatable.dart';

/// How a chapter entered the story timeline.
enum StoryChapterOrigin { auto, manual }

/// Playable information extracted alongside a readable chapter summary.
class StoryChapterNarrative extends Equatable {
  final List<String> keyEvents;
  final List<String> stateChanges;
  final List<String> openThreads;
  final List<String> nextSteps;

  const StoryChapterNarrative({
    this.keyEvents = const [],
    this.stateChanges = const [],
    this.openThreads = const [],
    this.nextSteps = const [],
  });

  bool get isEmpty =>
      keyEvents.isEmpty &&
      stateChanges.isEmpty &&
      openThreads.isEmpty &&
      nextSteps.isEmpty;

  factory StoryChapterNarrative.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) =>
        (json[key] as List?)
            ?.whereType<String>()
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false) ??
        const [];

    return StoryChapterNarrative(
      keyEvents: strings('keyEvents'),
      stateChanges: strings('stateChanges'),
      openThreads: strings('openThreads'),
      nextSteps: strings('nextSteps'),
    );
  }

  Map<String, dynamic> toJson() => {
        'keyEvents': keyEvents,
        'stateChanges': stateChanges,
        'openThreads': openThreads,
        'nextSteps': nextSteps,
      };

  @override
  List<Object?> get props => [keyEvents, stateChanges, openThreads, nextSteps];
}

/// A readable chapter for one chat world-line.
///
/// Chapters bind to concrete messages. After a bookmark fork deletes later
/// messages, chapters that referenced those messages disappear with them so
/// the new branch cannot see the old branch's story.
class StoryChapter extends Equatable {
  final String id;
  final String chatId;
  final String title;
  final String summary;
  final StoryChapterNarrative narrative;
  final String startMessageId;
  final String endMessageId;
  final int startOrdinal;
  final int endOrdinal;
  final StoryChapterOrigin origin;
  final DateTime createdAt;
  final DateTime updatedAt;

  const StoryChapter._({
    required this.id,
    required this.chatId,
    required this.title,
    required this.summary,
    required this.narrative,
    required this.startMessageId,
    required this.endMessageId,
    required this.startOrdinal,
    required this.endOrdinal,
    required this.origin,
    required this.createdAt,
    required this.updatedAt,
  });

  factory StoryChapter({
    required String id,
    required String chatId,
    required String title,
    required String summary,
    StoryChapterNarrative narrative = const StoryChapterNarrative(),
    required String startMessageId,
    required String endMessageId,
    required int startOrdinal,
    required int endOrdinal,
    StoryChapterOrigin origin = StoryChapterOrigin.auto,
    required DateTime createdAt,
    DateTime? updatedAt,
  }) {
    _requireNonEmpty(id, 'id');
    _requireNonEmpty(chatId, 'chatId');
    _requireNonEmpty(title, 'title');
    _requireNonEmpty(summary, 'summary');
    _requireNonEmpty(startMessageId, 'startMessageId');
    _requireNonEmpty(endMessageId, 'endMessageId');
    if (startOrdinal < 0) {
      throw ArgumentError.value(startOrdinal, 'startOrdinal');
    }
    if (endOrdinal < startOrdinal) {
      throw ArgumentError(
        'endOrdinal must be greater than or equal to startOrdinal.',
      );
    }
    final effectiveUpdatedAt = updatedAt ?? createdAt;
    if (effectiveUpdatedAt.isBefore(createdAt)) {
      throw ArgumentError('updatedAt cannot be before createdAt.');
    }
    return StoryChapter._(
      id: id,
      chatId: chatId,
      title: title.trim(),
      summary: summary.trim(),
      narrative: narrative,
      startMessageId: startMessageId,
      endMessageId: endMessageId,
      startOrdinal: startOrdinal,
      endOrdinal: endOrdinal,
      origin: origin,
      createdAt: createdAt,
      updatedAt: effectiveUpdatedAt,
    );
  }

  factory StoryChapter.fromJson(Map<String, dynamic> json) {
    return StoryChapter(
      id: _requiredString(json, 'id'),
      chatId: _requiredString(json, 'chatId'),
      title: _requiredString(json, 'title'),
      summary: _requiredString(json, 'summary'),
      narrative: json['narrative'] is Map
          ? StoryChapterNarrative.fromJson(
              Map<String, dynamic>.from(json['narrative'] as Map),
            )
          : const StoryChapterNarrative(),
      startMessageId: _requiredString(json, 'startMessageId'),
      endMessageId: _requiredString(json, 'endMessageId'),
      startOrdinal: _requiredInt(json, 'startOrdinal'),
      endOrdinal: _requiredInt(json, 'endOrdinal'),
      origin: _originFromJson(json['origin']),
      createdAt: _requiredDateTime(json, 'createdAt'),
      updatedAt: _optionalDateTime(json, 'updatedAt'),
    );
  }

  /// Message a story page should scroll to when the user opens this chapter.
  String get jumpMessageId => startMessageId;

  StoryChapter copyWith({
    String? id,
    String? chatId,
    String? title,
    String? summary,
    StoryChapterNarrative? narrative,
    String? startMessageId,
    String? endMessageId,
    int? startOrdinal,
    int? endOrdinal,
    StoryChapterOrigin? origin,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return StoryChapter(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      narrative: narrative ?? this.narrative,
      startMessageId: startMessageId ?? this.startMessageId,
      endMessageId: endMessageId ?? this.endMessageId,
      startOrdinal: startOrdinal ?? this.startOrdinal,
      endOrdinal: endOrdinal ?? this.endOrdinal,
      origin: origin ?? this.origin,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'chatId': chatId,
        'title': title,
        'summary': summary,
        'narrative': narrative.toJson(),
        'startMessageId': startMessageId,
        'endMessageId': endMessageId,
        'startOrdinal': startOrdinal,
        'endOrdinal': endOrdinal,
        'origin': origin.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  @override
  List<Object?> get props => [
        id,
        chatId,
        title,
        summary,
        narrative,
        startMessageId,
        endMessageId,
        startOrdinal,
        endOrdinal,
        origin,
        createdAt,
        updatedAt,
      ];
}

void _requireNonEmpty(String value, String fieldName) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, fieldName, 'must not be empty');
  }
}

String _requiredString(Map<String, dynamic> json, String fieldName) {
  final value = json[fieldName];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$fieldName must be a non-empty string.');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String fieldName) {
  final value = json[fieldName];
  if (value is! num || value != value.roundToDouble()) {
    throw FormatException('$fieldName must be an integer.');
  }
  return value.toInt();
}

DateTime _requiredDateTime(Map<String, dynamic> json, String fieldName) {
  final parsed = _optionalDateTime(json, fieldName);
  if (parsed == null) {
    throw FormatException('$fieldName must be an ISO-8601 date-time.');
  }
  return parsed;
}

DateTime? _optionalDateTime(Map<String, dynamic> json, String fieldName) {
  final value = json[fieldName];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$fieldName must be an ISO-8601 date-time.');
  }
  try {
    return DateTime.parse(value);
  } on FormatException {
    throw FormatException('$fieldName must be an ISO-8601 date-time.');
  }
}

StoryChapterOrigin _originFromJson(Object? value) {
  if (value == null) return StoryChapterOrigin.auto;
  if (value is String) {
    for (final origin in StoryChapterOrigin.values) {
      if (origin.name == value) return origin;
    }
  }
  throw FormatException('origin has an unsupported value: $value');
}

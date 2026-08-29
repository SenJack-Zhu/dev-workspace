/// Resume log for one background attempt: running, completed, or incomplete.
/// Features still decide what to do; this table only records that attempt so
/// a crash or failed request can continue later.
enum OperationKind {
  momentWake,
  storyChapter,
  momentImage,
}

/// 进行中 / 已完成 / 未完成
enum OperationStatus {
  running,
  completed,
  incomplete,
}

final class OperationLog {
  const OperationLog({
    required this.id,
    required this.kind,
    required this.subjectId,
    required this.status,
    required this.attempts,
    this.payload = const {},
    this.lastError,
    required this.dueAt,
    this.startedAt,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final OperationKind kind;
  final String subjectId;
  final OperationStatus status;
  final int attempts;
  final Map<String, dynamic> payload;
  final String? lastError;
  final DateTime dueAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isOpen =>
      status == OperationStatus.running || status == OperationStatus.incomplete;

  OperationLog copyWith({
    OperationStatus? status,
    int? attempts,
    Map<String, dynamic>? payload,
    String? lastError,
    bool clearError = false,
    DateTime? dueAt,
    DateTime? startedAt,
    DateTime? completedAt,
    DateTime? updatedAt,
  }) {
    return OperationLog(
      id: id,
      kind: kind,
      subjectId: subjectId,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      payload: payload ?? this.payload,
      lastError: clearError ? null : (lastError ?? this.lastError),
      dueAt: dueAt ?? this.dueAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

extension OperationKindSql on OperationKind {
  String get wireName => switch (this) {
        OperationKind.momentWake => 'moment.wake',
        OperationKind.storyChapter => 'story.chapter',
        OperationKind.momentImage => 'moment.image',
      };

  static OperationKind parse(String value) {
    return switch (value) {
      'moment.wake' => OperationKind.momentWake,
      'story.chapter' => OperationKind.storyChapter,
      'moment.image' => OperationKind.momentImage,
      _ => throw FormatException('Unknown operation kind: $value'),
    };
  }
}

extension OperationStatusSql on OperationStatus {
  String get wireName => name;

  static OperationStatus parse(String value) {
    return OperationStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => throw FormatException('Unknown operation status: $value'),
    );
  }
}

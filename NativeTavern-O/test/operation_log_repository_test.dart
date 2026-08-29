import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/operation_log.dart';
import 'package:native_tavern/data/repositories/operation_log_repository.dart';

void main() {
  late AppDatabase database;
  late OperationLogRepository logs;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    logs = OperationLogRepository(database, createId: () => 'job-1');
  });

  tearDown(() async {
    await database.close();
  });

  test('records running, incomplete, and completed work', () async {
    final started = await logs.begin(
      kind: OperationKind.momentImage,
      subjectId: 'ava',
      payload: const {'prompt': 'a rusted gate'},
    );
    expect(started.status, OperationStatus.running);
    expect(started.attempts, 1);

    await logs.markIncomplete(started, error: 'timeout');
    final open = await logs.findOpen(
      kind: OperationKind.momentImage,
      subjectId: 'ava',
    );
    expect(open?.status, OperationStatus.incomplete);
    expect(open?.lastError, 'timeout');

    final retry = await logs.begin(
      kind: OperationKind.momentImage,
      subjectId: 'ava',
    );
    expect(retry.id, started.id);
    expect(retry.status, OperationStatus.running);
    expect(retry.attempts, 2);

    await logs.markCompleted(retry);
    expect(
      await logs.findOpen(
        kind: OperationKind.momentImage,
        subjectId: 'ava',
      ),
      isNull,
    );
    expect(await logs.listRetryable(), isEmpty);
  });

  test('retryable listing can stay on one kind', () async {
    logs = OperationLogRepository(database, createId: () => 'job-story');
    await logs.begin(
      kind: OperationKind.storyChapter,
      subjectId: 'chat-1',
    );
    logs = OperationLogRepository(database, createId: () => 'job-wake');
    await logs.begin(
      kind: OperationKind.momentWake,
      subjectId: 'ava',
    );

    final storyOnly = await logs.listRetryable(
      kinds: const {OperationKind.storyChapter},
    );
    expect(storyOnly.single.kind, OperationKind.storyChapter);
    expect(storyOnly.single.subjectId, 'chat-1');
  });
}

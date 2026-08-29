import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/storage_governance_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/storage_governance_providers.dart';
import 'package:native_tavern/presentation/screens/settings/storage_management_screen.dart';
import 'package:path/path.dart' as path;

void main() {
  testWidgets('storage screen previews cleanup and restores from undo',
      (tester) async {
    final scannedAt = DateTime.utc(2026, 8, 8, 12);
    final orphan = StorageCleanupCandidate(
      path: '/data/attachments/orphan.jpg',
      category: StorageCategory.attachments,
      kind: StorageEntityKind.file,
      bytes: 17,
      fileCount: 1,
      modifiedAt: DateTime.utc(2026, 8, 6),
      reason: StorageCleanupReason.missingFileReference,
    );
    final snapshot = StorageSnapshot(
      scannedAt: scannedAt,
      quotaBytes: 4,
      categories: {
        for (final category in StorageCategory.values)
          category: StorageCategoryUsage(
            category: category,
            bytes: category == StorageCategory.attachments ? 17 : 0,
            fileCount: category == StorageCategory.attachments ? 1 : 0,
            reclaimableBytes: category == StorageCategory.attachments ? 17 : 0,
            reclaimableCount: category == StorageCategory.attachments ? 1 : 0,
          ),
      },
      cleanupCandidates: [orphan],
      unreadablePaths: const [],
    );
    final operations = _FakeStorageOperations(snapshot);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageGovernanceServiceProvider.overrideWith(
            (ref) => operations,
          ),
          storageSnapshotProvider.overrideWith(
            (ref) => snapshot,
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: StorageManagementScreen(),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('Storage management'));

    expect(find.text('Storage management'), findsOneWidget);
    expect(find.text('Live2D models'), findsOneWidget);
    expect(find.text('Attachments and media'), findsOneWidget);
    expect(find.text('orphan.jpg'), findsOneWidget);
    expect(find.byKey(const Key('storage-clean-selected')), findsOneWidget);

    await tester.tap(find.byKey(const Key('storage-clean-selected')));
    await tester.pump();
    expect(find.text('Review cleanup'), findsOneWidget);
    expect(find.textContaining('1 item(s)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('storage-confirm-cleanup')));
    await _pumpUntilFound(tester, find.text('Undo'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(operations.cleaned, isTrue);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await _pumpUntil(tester, () => operations.restored);
    await _pumpUntilFound(tester, find.text('Cleanup undone'));
    expect(operations.restored, isTrue);
    expect(operations.committed, isFalse);
    expect(find.text('Cleanup undone'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('storage cleanup UI stages and restores a real orphaned file',
      (tester) async {
    final temporary = Directory.systemTemp.createTempSync(
      'native_tavern_storage_e2e_',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final dataRoot = Directory(path.join(temporary.path, 'NativeTavern'))
      ..createSync(recursive: true);
    final orphan = File(path.join(dataRoot.path, 'attachments', 'orphan.jpg'))
      ..createSync(recursive: true)
      ..writeAsStringSync('recoverable');
    final now = DateTime.utc(2100, 8, 8, 12);
    orphan.setLastModifiedSync(now.subtract(const Duration(days: 2)));
    final service = StorageGovernanceService(
      dataRoot: dataRoot,
      referenceSource: const _EmptyReferences(),
      clock: () => now,
      idFactory: () => 'e2e-batch',
    );
    final operations = _ControlledStorageOperations(service);
    final initialSnapshot = (await tester.runAsync(service.scan))!;
    expect(
      initialSnapshot.cleanupCandidates.map((candidate) => candidate.path),
      contains(orphan.path),
    );

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageGovernanceServiceProvider.overrideWith((ref) => operations),
          storageSnapshotProvider.overrideWith((ref) => initialSnapshot),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: StorageManagementScreen(),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('orphan.jpg'));

    await tester.tap(find.byKey(const Key('storage-clean-selected')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('storage-confirm-cleanup')));
    await _pumpUntil(tester, () => operations.cleanPending);
    await operations.executeClean(tester);
    await _pumpUntilFound(tester, find.text('Undo'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(orphan.existsSync(), isFalse);
    await tester.tap(find.text('Undo'));
    await _pumpUntil(
        tester, () => operations.transaction?.restorePending ?? false);
    await operations.transaction!.executeRestore(tester);
    await _pumpUntil(tester, orphan.existsSync);
    await _pumpUntilFound(tester, find.text('Cleanup undone'));
    expect(orphan.readAsStringSync(), 'recoverable');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder,
) {
  return _pumpUntil(tester, () => finder.evaluate().isNotEmpty);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) return;
  }
  fail('Timed out waiting for widget state.');
}

final class _EmptyReferences implements StorageReferenceSource {
  const _EmptyReferences();

  @override
  Future<StorageReferenceSet> loadReferences() async =>
      const StorageReferenceSet();
}

final class _FakeStorageOperations implements StorageGovernanceOperations {
  final StorageSnapshot snapshot;
  late final StorageGovernanceService _planner = StorageGovernanceService(
    dataRoot: dataRoot,
    referenceSource: const _EmptyReferences(),
  );
  bool cleaned = false;
  bool restored = false;
  bool committed = false;

  _FakeStorageOperations(this.snapshot);

  @override
  final Directory dataRoot = Directory('/data');

  @override
  Future<StorageSnapshot> scan() async => snapshot;

  @override
  StorageCleanupPlan createCleanupPlan(
    StorageSnapshot snapshot, {
    Set<String>? selectedPaths,
  }) =>
      _planner.createCleanupPlan(snapshot, selectedPaths: selectedPaths);

  @override
  StorageCleanupConfirmation confirmCleanup(StorageCleanupPlan reviewedPlan) =>
      _planner.confirmCleanup(reviewedPlan);

  @override
  Future<StorageCleanupTransaction> clean(
    StorageCleanupConfirmation confirmation,
  ) async {
    cleaned = true;
    return _FakeCleanupTransaction(this);
  }
}

final class _ControlledStorageOperations
    implements StorageGovernanceOperations {
  final StorageGovernanceService delegate;
  StorageCleanupConfirmation? _pendingConfirmation;
  Completer<StorageCleanupTransaction>? _cleanCompleter;
  _ControlledCleanupTransaction? transaction;

  _ControlledStorageOperations(this.delegate);

  bool get cleanPending => _pendingConfirmation != null;

  @override
  Directory get dataRoot => delegate.dataRoot;

  @override
  Future<StorageSnapshot> scan() => delegate.scan();

  @override
  StorageCleanupPlan createCleanupPlan(
    StorageSnapshot snapshot, {
    Set<String>? selectedPaths,
  }) =>
      delegate.createCleanupPlan(snapshot, selectedPaths: selectedPaths);

  @override
  StorageCleanupConfirmation confirmCleanup(StorageCleanupPlan reviewedPlan) =>
      delegate.confirmCleanup(reviewedPlan);

  @override
  Future<StorageCleanupTransaction> clean(
    StorageCleanupConfirmation confirmation,
  ) {
    _pendingConfirmation = confirmation;
    _cleanCompleter = Completer<StorageCleanupTransaction>();
    return _cleanCompleter!.future;
  }

  Future<void> executeClean(WidgetTester tester) async {
    final confirmation = _pendingConfirmation!;
    _pendingConfirmation = null;
    final delegateTransaction =
        (await tester.runAsync(() => delegate.clean(confirmation)))!;
    transaction = _ControlledCleanupTransaction(delegateTransaction);
    _cleanCompleter!.complete(transaction);
    _cleanCompleter = null;
  }
}

final class _ControlledCleanupTransaction implements StorageCleanupTransaction {
  final StorageCleanupTransaction delegate;
  Completer<void>? _restoreCompleter;

  _ControlledCleanupTransaction(this.delegate);

  bool get restorePending => _restoreCompleter != null;

  @override
  int get movedCount => delegate.movedCount;

  @override
  Future<void> commit() => delegate.commit();

  @override
  Future<void> restore() {
    _restoreCompleter = Completer<void>();
    return _restoreCompleter!.future;
  }

  Future<void> executeRestore(WidgetTester tester) async {
    await tester.runAsync(delegate.restore);
    _restoreCompleter!.complete();
    _restoreCompleter = null;
  }
}

final class _FakeCleanupTransaction implements StorageCleanupTransaction {
  final _FakeStorageOperations operations;

  const _FakeCleanupTransaction(this.operations);

  @override
  int get movedCount => 1;

  @override
  Future<void> commit() async => operations.committed = true;

  @override
  Future<void> restore() async => operations.restored = true;
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/models/data_bank_context.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/data_bank_ingestion_service.dart';
import 'package:native_tavern/domain/services/data_bank_library_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/controllers/data_bank_library_controller.dart';
import 'package:native_tavern/presentation/providers/data_bank_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/screens/data_bank/data_bank_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('management screen exposes document states and real actions',
      (tester) async {
    final operations = _FakeDataBankOperations();
    final controller = DataBankLibraryController(operations);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DataBankScreen(
            controller: controller,
            fileGateway: const _NullFileGateway(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ready.md'), findsOneWidget);
    expect(find.text('failed.txt'), findsOneWidget);
    expect(find.text('disabled.pdf'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);

    await tester.tap(find.byTooltip('Preview').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('data-bank-preview-chunks')), findsOneWidget);
    expect(find.textContaining('eastern channel'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('data-bank-search')),
      'eastern',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('data-bank-search-results')), findsOneWidget);
    expect(find.text('Eastern channel match'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('data-bank-delete-ready')));
    await tester.pumpAndSettle();
    expect(find.text('Delete ready.md?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('data-bank-confirm-delete')));
    await tester.pumpAndSettle();

    expect(operations.deletedIds, ['ready']);
    expect(find.text('ready.md'), findsNothing);
  });

  testWidgets('chat retrieval settings and citation diagnostics are operable',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final controller = DataBankLibraryController(_FakeDataBankOperations());
    final chunk = _chunk('ready');
    final diagnostics = DataBankContextSnapshot(
      sessionId: 'session-1',
      originalQuery: 'eastern channel',
      queries: const ['eastern channel'],
      mode: DataBankRetrievalMode.localFts,
      sources: [
        DataBankContextSource(
          label: 'D1',
          documentName: 'ready.md',
          snippet: 'Eastern channel match',
          injectedText: chunk.text,
          citation: chunk.toCitation('ready'),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          lastDataBankContextProvider.overrideWith((ref) => diagnostics),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DataBankScreen(
            controller: controller,
            fileGateway: const _NullFileGateway(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('data-bank-context-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('data-bank-context-enabled')), findsOneWidget);
    expect(find.byKey(const Key('data-bank-query-rewrite')), findsOneWidget);
    expect(
      find.byKey(const Key('data-bank-semantic-reranking')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('data-bank-query-rewrite')));
    await tester.pumpAndSettle();
    final stored = preferences.getString('data_bank_context_settings');
    expect(stored, contains('"queryRewriteEnabled":true'));

    await tester.scrollUntilVisible(
      find.byKey(const Key('data-bank-retrieval-diagnostics')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('data-bank-retrieval-diagnostics')),
      findsOneWidget,
    );
    expect(find.text('ready.md'), findsOneWidget);
    expect(find.textContaining('chars 0-42'), findsOneWidget);

    await tester.tap(find.byKey(const Key('data-bank-open-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('data-bank-citation-list')), findsOneWidget);
    expect(
        find.textContaining('Ships use the eastern channel'), findsOneWidget);
  });
}

final class _NullFileGateway implements DataBankFileGateway {
  const _NullFileGateway();

  @override
  Future<File?> pickDocument() async => null;
}

final class _FakeDataBankOperations implements DataBankLibraryOperations {
  final List<String> deletedIds = [];
  late final List<DataBankLibraryEntry> entries = [
    _entry('ready', DataBankProcessingState.ready),
    _entry('failed', DataBankProcessingState.failed),
    _entry('disabled', DataBankProcessingState.disabled),
  ];

  @override
  Future<void> recoverInterruptedImports() async {}

  @override
  Future<List<DataBankLibraryEntry>> listDocuments() async => List.of(entries);

  @override
  Future<List<DataBankSearchResult>> search(
    String query, {
    int topK = 20,
    DataBankSearchFilter filter = const DataBankSearchFilter(),
  }) async {
    final chunk = _chunk('ready');
    return [
      DataBankSearchResult(
        chunk: chunk,
        citation: chunk.toCitation('ready'),
        documentName: 'ready.md',
        snippet: 'Eastern channel match',
        rank: -1,
      ),
    ];
  }

  @override
  Future<DataBankDocumentPreview> previewDocument(String documentId) async {
    final entry = entries.singleWhere(
      (entry) => entry.document.id == documentId,
    );
    return DataBankDocumentPreview(
      document: entry.document,
      version: entry.version,
      sections: const [],
      chunks: [_chunk(documentId)],
    );
  }

  @override
  Future<DataBankDeletionPreview> previewDeletion(String documentId) async {
    final entry = entries.singleWhere(
      (entry) => entry.document.id == documentId,
    );
    return DataBankDeletionPreview(
      documentId: documentId,
      documentName: entry.version.originalFileName,
      versionCount: 1,
      chunkCount: 1,
      bindingCount: 1,
      managedPaths: const ['/managed/source.md'],
    );
  }

  @override
  Future<void> deleteDocument(String documentId) async {
    deletedIds.add(documentId);
    entries.removeWhere((entry) => entry.document.id == documentId);
  }

  @override
  Future<DataBankLibraryEntry> importDocument(
    File source, {
    DataBankProgressCallback? onProgress,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<DataBankLibraryEntry> retryDocument(
    String documentId, {
    DataBankProgressCallback? onProgress,
  }) async {
    return entries.singleWhere((entry) => entry.document.id == documentId);
  }

  @override
  Future<void> setDocumentEnabled(String documentId, bool enabled) async {}

  @override
  Future<void> rebuildSearchIndex() async {}

  @override
  Future<DataBankBinding> saveBinding({
    required String documentId,
    required DataBankBindingScope scope,
    String? targetId,
    bool enabled = true,
  }) async {
    return _binding(documentId);
  }

  @override
  Future<void> removeBinding(String bindingId) async {}
}

DataBankLibraryEntry _entry(String id, DataBankProcessingState state) {
  final now = DateTime.utc(2026, 8, 8, 12);
  final failure = state == DataBankProcessingState.failed
      ? DataBankFailure(
          code: 'parseFailed',
          message: 'Document parsing failed.',
          occurredAt: now,
        )
      : null;
  final indexState = switch (state) {
    DataBankProcessingState.ready => DataBankIndexState.indexed,
    DataBankProcessingState.failed => DataBankIndexState.failed,
    DataBankProcessingState.disabled => DataBankIndexState.disabled,
    _ => DataBankIndexState.notIndexed,
  };
  final extension = id == 'disabled'
      ? 'pdf'
      : id == 'failed'
          ? 'txt'
          : 'md';
  final version = DataBankDocumentVersion(
    id: '$id-version',
    documentId: id,
    versionNumber: 1,
    originalFileName: '$id.$extension',
    mediaType: extension == 'pdf' ? 'application/pdf' : 'text/plain',
    byteSize: 128,
    contentHash: DataBankContentHash(
      algorithm: DataBankHashAlgorithm.sha256,
      digest: 'a' * 64,
    ),
    importedAt: now,
    processingState: state,
    indexState: indexState,
    failure: failure,
  );
  return DataBankLibraryEntry(
    document: DataBankDocument(
      id: id,
      currentVersionId: version.id,
      processingState: state,
      indexState: indexState,
      failure: failure,
      createdAt: now,
      updatedAt: now,
    ),
    version: version,
    bindings: [_binding(id)],
    chunkCount: state == DataBankProcessingState.failed ? 0 : 1,
    managedPaths: ['/managed/$id/source.$extension'],
  );
}

DataBankBinding _binding(String documentId) {
  final now = DateTime.utc(2026, 8, 8, 12);
  return DataBankBinding(
    id: '$documentId-binding',
    documentId: documentId,
    scope: DataBankBindingScope.global,
    createdAt: now,
    updatedAt: now,
  );
}

DataBankTextChunk _chunk(String documentId) {
  return DataBankTextChunk(
    id: '$documentId-chunk',
    documentVersionId: '$documentId-version',
    sectionId: '$documentId-section',
    ordinal: 0,
    text: 'Ships use the eastern channel before dawn.',
    locator: DataBankSourceLocator(
      documentVersionId: '$documentId-version',
      sectionId: '$documentId-section',
      chapter: 'Harbor',
      startOffset: 0,
      endOffset: 42,
    ),
  );
}

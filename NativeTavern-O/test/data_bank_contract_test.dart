import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/data_bank.dart';

void main() {
  final importedAt = DateTime.utc(2026, 8, 7, 12);
  final updatedAt = importedAt.add(const Duration(minutes: 5));
  final hash = DataBankContentHash(
    algorithm: DataBankHashAlgorithm.sha256,
    digest: 'A' * 64,
  );

  DataBankSourceLocator locator({
    String versionId = 'version-1',
    String? sectionId = 'chapter-1',
  }) {
    return DataBankSourceLocator(
      documentVersionId: versionId,
      sectionId: sectionId,
      pageStart: 3,
      pageEnd: 4,
      chapter: 'Arrival',
      startOffset: 120,
      endOffset: 240,
    );
  }

  group('serialization', () {
    test('document and version preserve source and lifecycle metadata', () {
      final reprocessing = DataBankReprocessingMetadata(
        attemptCount: 2,
        requestedAt: importedAt.subtract(const Duration(minutes: 10)),
        lastAttemptAt: importedAt.subtract(const Duration(minutes: 2)),
        reason: 'Parser upgrade',
      );
      final document = DataBankDocument(
        id: 'document-1',
        currentVersionId: 'version-2',
        processingState: DataBankProcessingState.ready,
        indexState: DataBankIndexState.indexed,
        reprocessing: reprocessing,
        createdAt: importedAt,
        updatedAt: updatedAt,
      );
      final version = DataBankDocumentVersion(
        id: 'version-2',
        documentId: document.id,
        versionNumber: 2,
        supersedesVersionId: 'version-1',
        originalFileName: 'guide.pdf',
        mediaType: 'application/pdf',
        byteSize: 4096,
        contentHash: hash,
        importedAt: updatedAt,
        processingState: DataBankProcessingState.ready,
        indexState: DataBankIndexState.indexed,
        reprocessing: reprocessing,
      );

      expect(
        DataBankDocument.fromJson(document.toJson()).toJson(),
        document.toJson(),
      );
      expect(
        DataBankDocumentVersion.fromJson(version.toJson()).toJson(),
        version.toJson(),
      );
      expect(version.supersedesVersionId, 'version-1');
      expect(version.contentHash.digest, 'a' * 64);

      final failure = DataBankFailure(
        code: 'parse_failed',
        message: 'The source document is malformed.',
        occurredAt: updatedAt,
        retryable: false,
      );
      expect(
        DataBankFailure.fromJson(failure.toJson()).toJson(),
        failure.toJson(),
      );
      expect(
        DataBankReprocessingMetadata.fromJson(reprocessing.toJson()).toJson(),
        reprocessing.toJson(),
      );
    });

    test('sections, chunks, and citations preserve exact provenance', () {
      final sourceLocator = locator();
      final section = DataBankSection(
        id: 'chapter-1',
        documentVersionId: 'version-1',
        kind: DataBankSectionKind.chapter,
        title: 'Arrival',
        ordinal: 0,
        locator: sourceLocator,
      );
      final chunk = DataBankTextChunk(
        id: 'chunk-1',
        documentVersionId: 'version-1',
        sectionId: section.id,
        ordinal: 0,
        text: 'The train arrived just before dawn.',
        locator: sourceLocator,
      );
      final citation = chunk.toCitation('document-1');

      expect(
        DataBankSection.fromJson(section.toJson()).toJson(),
        section.toJson(),
      );
      expect(
        DataBankTextChunk.fromJson(chunk.toJson()).toJson(),
        chunk.toJson(),
      );
      expect(
        DataBankCitation.fromJson(citation.toJson()).toJson(),
        citation.toJson(),
      );
      expect(citation.documentId, 'document-1');
      expect(citation.documentVersionId, 'version-1');
      expect(citation.chunkId, 'chunk-1');
      expect(citation.locator.pageStart, 3);
      expect(citation.locator.effectivePageEnd, 4);
      expect(citation.locator.chapter, 'Arrival');
      expect(citation.locator.startOffset, 120);
      expect(citation.locator.endOffset, 240);
    });

    test('section and chapter variants round-trip', () {
      final sections = <DataBankSection>[
        DataBankSection(
          id: 'section-1',
          documentVersionId: 'version-1',
          kind: DataBankSectionKind.section,
          ordinal: 0,
          locator: DataBankSourceLocator(
            documentVersionId: 'version-1',
            sectionId: 'section-1',
          ),
        ),
        DataBankSection(
          id: 'chapter-1',
          documentVersionId: 'version-1',
          kind: DataBankSectionKind.chapter,
          title: 'First Steps',
          ordinal: 1,
          parentSectionId: 'section-1',
          locator: DataBankSourceLocator(
            documentVersionId: 'version-1',
            sectionId: 'chapter-1',
            chapter: 'First Steps',
          ),
        ),
      ];

      for (final section in sections) {
        expect(
          DataBankSection.fromJson(section.toJson()).toJson(),
          section.toJson(),
        );
      }
    });

    test('backward-compatible optional fields have stable defaults', () {
      final document = DataBankDocument.fromJson({
        'id': 'document-1',
        'currentVersionId': 'version-1',
        'createdAt': importedAt.toIso8601String(),
        'updatedAt': importedAt.toIso8601String(),
      });
      final binding = DataBankBinding.fromJson({
        'id': 'binding-1',
        'documentId': 'document-1',
        'scope': 'global',
        'createdAt': importedAt.toIso8601String(),
        'updatedAt': importedAt.toIso8601String(),
      });

      expect(document.processingState, DataBankProcessingState.pending);
      expect(document.indexState, DataBankIndexState.notIndexed);
      expect(document.reprocessing.attemptCount, 0);
      expect(binding.enabled, isTrue);
    });
  });

  group('document lifecycle', () {
    test('all required processing states are representable', () {
      for (final state in DataBankProcessingState.values) {
        final indexState = switch (state) {
          DataBankProcessingState.disabled => DataBankIndexState.disabled,
          DataBankProcessingState.deleted => DataBankIndexState.deleted,
          _ => DataBankIndexState.notIndexed,
        };
        final failure = state == DataBankProcessingState.failed
            ? DataBankFailure(
                code: 'parse_failed',
                message: 'Could not parse document',
                occurredAt: importedAt,
              )
            : null;
        final document = DataBankDocument(
          id: 'document-${state.name}',
          currentVersionId: 'version-${state.name}',
          processingState: state,
          indexState: indexState,
          failure: failure,
          createdAt: importedAt,
          updatedAt: importedAt,
        );

        expect(document.processingState, state);
        expect(
          DataBankDocument.fromJson(document.toJson()).processingState,
          state,
        );
      }
    });

    test('indexing states and indexing failure details are representable', () {
      for (final indexState in DataBankIndexState.values) {
        final processingState = switch (indexState) {
          DataBankIndexState.disabled => DataBankProcessingState.disabled,
          DataBankIndexState.deleted => DataBankProcessingState.deleted,
          _ => DataBankProcessingState.ready,
        };
        final failure = indexState == DataBankIndexState.failed
            ? DataBankFailure(
                code: 'index_failed',
                message: 'Embedding provider unavailable',
                occurredAt: importedAt,
              )
            : null;
        final document = DataBankDocument(
          id: 'document-${indexState.name}',
          currentVersionId: 'version-${indexState.name}',
          processingState: processingState,
          indexState: indexState,
          failure: failure,
          createdAt: importedAt,
          updatedAt: importedAt,
        );

        expect(document.indexState, indexState);
      }
    });

    test('replacement versions preserve immutable lineage', () {
      final first = DataBankDocumentVersion(
        id: 'version-1',
        documentId: 'document-1',
        versionNumber: 1,
        originalFileName: 'notes.txt',
        mediaType: 'text/plain',
        byteSize: 100,
        contentHash: hash,
        importedAt: importedAt,
        processingState: DataBankProcessingState.ready,
        indexState: DataBankIndexState.indexed,
      );
      final replacement = DataBankDocumentVersion(
        id: 'version-2',
        documentId: first.documentId,
        versionNumber: 2,
        supersedesVersionId: first.id,
        originalFileName: 'notes-revised.txt',
        mediaType: 'text/plain',
        byteSize: 120,
        contentHash: hash,
        importedAt: updatedAt,
      );
      final document = DataBankDocument(
        id: first.documentId,
        currentVersionId: replacement.id,
        createdAt: importedAt,
        updatedAt: updatedAt,
      );

      expect(document.currentVersionId, replacement.id);
      expect(replacement.supersedesVersionId, first.id);
      expect(first.supersedesVersionId, isNull);
    });

    test('disabled documents are explicitly non-enabled', () {
      final document = DataBankDocument(
        id: 'document-1',
        currentVersionId: 'version-1',
        processingState: DataBankProcessingState.disabled,
        indexState: DataBankIndexState.disabled,
        createdAt: importedAt,
        updatedAt: updatedAt,
      );

      expect(document.isEnabled, isFalse);
      expect(DataBankDocument.fromJson(document.toJson()).isEnabled, isFalse);
    });

    test('only declared processing transitions are accepted', () {
      expect(
        DataBankProcessingState.pending.canTransitionTo(
          DataBankProcessingState.processing,
        ),
        isTrue,
      );
      expect(
        DataBankProcessingState.ready.canTransitionTo(
          DataBankProcessingState.pending,
        ),
        isTrue,
      );
      expect(
        DataBankProcessingState.deleted.canTransitionTo(
          DataBankProcessingState.ready,
        ),
        isFalse,
      );
      expect(
        () => DataBankProcessingState.deleted.validateTransitionTo(
          DataBankProcessingState.pending,
        ),
        _validationFor('processingState'),
      );
    });
  });

  group('bindings', () {
    test('global, character, and chat bindings round-trip', () {
      final bindings = <DataBankBinding>[
        DataBankBinding(
          id: 'global-binding',
          documentId: 'document-1',
          scope: DataBankBindingScope.global,
          createdAt: importedAt,
          updatedAt: updatedAt,
        ),
        DataBankBinding(
          id: 'character-binding',
          documentId: 'document-1',
          scope: DataBankBindingScope.character,
          characterId: 'character-1',
          createdAt: importedAt,
          updatedAt: updatedAt,
        ),
        DataBankBinding(
          id: 'chat-binding',
          documentId: 'document-1',
          scope: DataBankBindingScope.chat,
          chatId: 'chat-1',
          enabled: false,
          createdAt: importedAt,
          updatedAt: updatedAt,
        ),
      ];

      for (final binding in bindings) {
        final restored = DataBankBinding.fromJson(binding.toJson());
        expect(restored.toJson(), binding.toJson());
        expect(restored.targetId, binding.targetId);
      }
      expect(bindings.last.enabled, isFalse);
    });
  });

  group('validation', () {
    test('rejects invalid hashes and identifiers', () {
      expect(
        () => DataBankContentHash(
          algorithm: DataBankHashAlgorithm.sha256,
          digest: 'abc123',
        ),
        _validationFor('contentHash'),
      );
      expect(
        () => DataBankDocument(
          id: ' ',
          currentVersionId: 'version-1',
          createdAt: importedAt,
          updatedAt: importedAt,
        ),
        _validationFor('document.id'),
      );
    });

    test('rejects invalid source ranges', () {
      expect(
        () => DataBankSourceLocator(documentVersionId: 'version-1'),
        _validationFor('locator'),
      );
      expect(
        () =>
            DataBankSourceLocator(documentVersionId: 'version-1', pageStart: 0),
        _validationFor('locator.pageStart'),
      );
      expect(
        () => DataBankSourceLocator(
          documentVersionId: 'version-1',
          startOffset: 20,
          endOffset: 10,
        ),
        _validationFor('locator.endOffset'),
      );
      expect(
        () => DataBankSourceLocator(
          documentVersionId: 'version-1',
          startOffset: 10,
        ),
        _validationFor('locator.textOffsets'),
      );
    });

    test('rejects provenance mismatches', () {
      expect(
        () => DataBankTextChunk(
          id: 'chunk-1',
          documentVersionId: 'version-2',
          sectionId: 'chapter-1',
          ordinal: 0,
          text: 'Text',
          locator: locator(),
        ),
        _validationFor('chunk.locator.documentVersionId'),
      );
      expect(
        () => DataBankCitation(
          documentId: 'document-1',
          documentVersionId: 'version-2',
          chunkId: 'chunk-1',
          quote: 'Text',
          locator: locator(),
        ),
        _validationFor('citation.locator.documentVersionId'),
      );
    });

    test('rejects invalid binding scope combinations', () {
      expect(
        () => DataBankBinding(
          id: 'binding-1',
          documentId: 'document-1',
          scope: DataBankBindingScope.global,
          characterId: 'character-1',
          createdAt: importedAt,
          updatedAt: updatedAt,
        ),
        _validationFor('binding.scope'),
      );
      expect(
        () => DataBankBinding(
          id: 'binding-2',
          documentId: 'document-1',
          scope: DataBankBindingScope.chat,
          createdAt: importedAt,
          updatedAt: updatedAt,
        ),
        _validationFor('binding.scope'),
      );
    });

    test('rejects invalid version replacement and state metadata', () {
      expect(
        () => DataBankDocumentVersion(
          id: 'version-2',
          documentId: 'document-1',
          versionNumber: 2,
          originalFileName: 'guide.pdf',
          mediaType: 'application/pdf',
          byteSize: 20,
          contentHash: hash,
          importedAt: importedAt,
        ),
        _validationFor('version.supersedesVersionId'),
      );
      expect(
        () => DataBankDocument(
          id: 'document-1',
          currentVersionId: 'version-1',
          processingState: DataBankProcessingState.failed,
          createdAt: importedAt,
          updatedAt: importedAt,
        ),
        _validationFor('document.failure'),
      );
      expect(
        () => DataBankDocument(
          id: 'document-1',
          currentVersionId: 'version-1',
          processingState: DataBankProcessingState.disabled,
          indexState: DataBankIndexState.indexed,
          createdAt: importedAt,
          updatedAt: importedAt,
        ),
        _validationFor('document.indexState'),
      );
    });

    test('rejects unknown serialized enum values clearly', () {
      expect(
        () => DataBankBinding.fromJson({
          'id': 'binding-1',
          'documentId': 'document-1',
          'scope': 'group',
          'createdAt': importedAt.toIso8601String(),
          'updatedAt': updatedAt.toIso8601String(),
        }),
        _validationFor('scope'),
      );
    });
  });
}

Matcher _validationFor(String field) {
  return throwsA(
    isA<DataBankValidationException>().having(
      (error) => error.field,
      'field',
      field,
    ),
  );
}

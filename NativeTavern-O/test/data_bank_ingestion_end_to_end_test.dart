import 'dart:io';

import 'package:charset/charset.dart' as charset;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/domain/services/data_bank_ingestion_service.dart';
import 'package:path/path.dart' as path;

import 'support/data_bank_document_fixtures.dart';

void main() {
  late Directory sandbox;
  late Directory inputDirectory;
  late Directory stagingRoot;
  late int stagingSequence;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('data_bank_ingestion_test_');
    inputDirectory = Directory(path.join(sandbox.path, 'input'))..createSync();
    stagingRoot = Directory(path.join(sandbox.path, 'staging'))..createSync();
    stagingSequence = 0;
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  DataBankIngestionService createService({
    DataBankPdfTextExtractor? pdfTextExtractor,
  }) {
    return DataBankIngestionService(
      pdfTextExtractor: pdfTextExtractor ?? _FixturePdfTextExtractor(),
      createStagingDirectory: () async {
        final directory = Directory(
          path.join(stagingRoot.path, 'stage-${stagingSequence++}'),
        );
        await directory.create();
        return directory;
      },
    );
  }

  group('lightweight text ingestion', () {
    test('detects GBK, hashes exact bytes, chunks paragraphs, and cleans up',
        () async {
      final sourceBytes = charset.gbk.encode(
        '第一段包含中文。\r\n\r\n第二段也能正确解析。',
      );
      final source = File(path.join(inputDirectory.path, 'notes.txt'))
        ..writeAsBytesSync(sourceBytes);
      final progress = <DataBankIngestionProgress>[];

      final result = await createService().ingest(
        DataBankIngestionRequest(
          sourceFile: source,
          documentVersionId: 'version-gbk',
          onProgress: progress.add,
        ),
      );

      expect(result.detectedEncoding?.toLowerCase(), contains('gb'));
      expect(result.normalizedText, '第一段包含中文。\n\n第二段也能正确解析。');
      expect(result.contentHash.digest, sha256.convert(sourceBytes).toString());
      expect(result.sections, hasLength(1));
      expect(result.chunks, hasLength(2));
      expect(
        progress.map((event) => event.phase),
        containsAllInOrder([
          DataBankIngestionPhase.staging,
          DataBankIngestionPhase.parsing,
          DataBankIngestionPhase.chunking,
          DataBankIngestionPhase.completed,
        ]),
      );
      _expectExactProvenance(result);
      _expectNoStagingArtifacts(stagingRoot);
    });

    test('decodes UTF-16 BOM content without leaking the marker', () async {
      const text = 'UTF-16 notes';
      final bytes = <int>[
        0xff,
        0xfe,
        for (final codeUnit in text.codeUnits) ...[
          codeUnit & 0xff,
          codeUnit >> 8,
        ],
      ];
      final source = File(path.join(inputDirectory.path, 'utf16.txt'))
        ..writeAsBytesSync(bytes);

      final result = await createService().ingest(
        DataBankIngestionRequest(
          sourceFile: source,
          documentVersionId: 'version-utf16',
        ),
      );

      expect(result.detectedEncoding, 'UTF-16');
      expect(result.normalizedText, text);
      expect(result.normalizedText, isNot(startsWith('\ufeff')));
      _expectExactProvenance(result);
      _expectNoStagingArtifacts(stagingRoot);
    });

    test('preserves Markdown headings while removing formatting markup',
        () async {
      final source = File(path.join(inputDirectory.path, 'guide.md'))
        ..writeAsStringSync('''
# Arrival

The **train** arrived before dawn.

## Safe Harbor

Ships enter from the [eastern channel](https://example.test).
''');

      final result = await createService().ingest(
        DataBankIngestionRequest(
          sourceFile: source,
          documentVersionId: 'version-markdown',
          chunking: DataBankChunkingOptions(
            strategy: DataBankChunkingStrategy.chapter,
          ),
        ),
      );

      expect(
        result.sections.map((section) => section.title),
        ['Arrival', 'Safe Harbor'],
      );
      expect(result.normalizedText, contains('The train arrived before dawn.'));
      expect(result.normalizedText, isNot(contains('**')));
      expect(result.normalizedText, isNot(contains('https://')));
      expect(result.chunks, hasLength(2));
      _expectExactProvenance(result);
      _expectNoStagingArtifacts(stagingRoot);
    });

    test('uses declared HTML encoding and drops non-content elements',
        () async {
      const html = '''
<!doctype html><html><head>
<meta charset="windows-1252"><title>Price Guide</title>
<style>.hidden { display: none; }</style></head><body>
<h1>Visible offers</h1><p>Entry price: €10 &amp; tax.</p>
<script>secretPrompt()</script>
<div hidden><p>ancestorSecret()</p></div>
<h2>Terms</h2><p>No hidden fees.</p>
</body></html>
''';
      final source = File(path.join(inputDirectory.path, 'prices.html'))
        ..writeAsBytesSync(charset.windows1252.encode(html));

      final result = await createService().ingest(
        DataBankIngestionRequest(
          sourceFile: source,
          documentVersionId: 'version-html',
        ),
      );

      expect(result.detectedEncoding?.toLowerCase(), contains('1252'));
      expect(result.sections.map((section) => section.title), [
        'Visible offers',
        'Terms',
      ]);
      expect(result.normalizedText, contains('Entry price: €10 & tax.'));
      expect(result.normalizedText, isNot(contains('secretPrompt')));
      expect(result.normalizedText, isNot(contains('ancestorSecret')));
      expect(result.normalizedText, isNot(contains('.hidden')));
      _expectExactProvenance(result);
      _expectNoStagingArtifacts(stagingRoot);
    });
  });

  group('PDF and EPUB ingestion', () {
    test('preserves PDF page numbers through the complete ingestion pipeline',
        () async {
      final pdfBytes = buildPdfFixture(['First PDF page', 'Second PDF page']);
      final extractor = _FixturePdfTextExtractor(
        expectedBytes: pdfBytes,
        pages: const [
          DataBankPdfPage(pageNumber: 1, text: 'First PDF page'),
          DataBankPdfPage(pageNumber: 2, text: 'Second PDF page'),
        ],
      );
      final source = File(path.join(inputDirectory.path, 'field-guide.pdf'))
        ..writeAsBytesSync(pdfBytes);

      final result = await createService(pdfTextExtractor: extractor).ingest(
        DataBankIngestionRequest(
          sourceFile: source,
          documentVersionId: 'version-pdf',
          chunking: DataBankChunkingOptions(
            strategy: DataBankChunkingStrategy.fixedLength,
            maxCharacters: 8,
          ),
        ),
      );

      expect(extractor.called, isTrue);
      expect(result.mediaType, 'application/pdf');
      expect(
          result.sections.map((section) => section.locator.pageStart), [1, 2]);
      expect(
        result.chunks.where((chunk) => chunk.locator.pageStart == 1),
        isNotEmpty,
      );
      expect(result.chunks.every((chunk) => chunk.text.length <= 8), isTrue);
      _expectExactProvenance(result);
      _expectNoStagingArtifacts(stagingRoot);
    });

    test('imports EPUB spine order as chapter provenance', () async {
      final bytes = buildEpubFixture();
      final source = File(path.join(inputDirectory.path, 'fixture.epub'))
        ..writeAsBytesSync(bytes);

      final result = await createService().ingest(
        DataBankIngestionRequest(
          sourceFile: source,
          documentVersionId: 'version-epub',
          chunking: DataBankChunkingOptions(
            strategy: DataBankChunkingStrategy.chapter,
          ),
        ),
      );

      expect(result.mediaType, 'application/epub+zip');
      expect(result.sections.map((section) => section.kind), [
        DataBankSectionKind.chapter,
        DataBankSectionKind.chapter,
      ]);
      expect(result.sections.map((section) => section.title), [
        'Arrival',
        'Safe Harbor',
      ]);
      expect(result.chunks.map((chunk) => chunk.locator.chapter), [
        'Arrival',
        'Safe Harbor',
      ]);
      expect(result.normalizedText, contains('eastern channel'));
      _expectExactProvenance(result);
      _expectNoStagingArtifacts(stagingRoot);
    });
  });

  group('identity and failure behavior', () {
    test('stable SHA256 distinguishes duplicate content from a new version',
        () async {
      final firstFile = File(path.join(inputDirectory.path, 'first.txt'))
        ..writeAsStringSync('Stable content');
      final duplicateFile =
          File(path.join(inputDirectory.path, 'duplicate.txt'))
            ..writeAsStringSync('Stable content');
      final changedFile = File(path.join(inputDirectory.path, 'changed.txt'))
        ..writeAsStringSync('Changed content');
      final service = createService();

      final first = await service.ingest(
        DataBankIngestionRequest(
          sourceFile: firstFile,
          documentVersionId: 'version-1',
        ),
      );
      final duplicate = await service.ingest(
        DataBankIngestionRequest(
          sourceFile: duplicateFile,
          documentVersionId: 'version-2',
        ),
      );
      final changed = await service.ingest(
        DataBankIngestionRequest(
          sourceFile: changedFile,
          documentVersionId: 'version-3',
        ),
      );

      expect(
        duplicate.compareContent(first.contentHash),
        DataBankContentComparison.identical,
      );
      expect(
        changed.compareContent(first.contentHash),
        DataBankContentComparison.changed,
      );
      _expectNoStagingArtifacts(stagingRoot);
    });

    test(
        'empty, damaged, encrypted, and unsupported inputs return typed errors',
        () async {
      final empty = File(path.join(inputDirectory.path, 'empty.txt'))
        ..writeAsStringSync(' \r\n\t');
      final damaged = File(path.join(inputDirectory.path, 'damaged.epub'))
        ..writeAsBytesSync([0x50, 0x4b, 0x03]);
      final encrypted = File(path.join(inputDirectory.path, 'encrypted.epub'))
        ..writeAsBytesSync(buildEpubFixture(encryptSecondChapter: true));
      final unsupported = File(path.join(inputDirectory.path, 'unknown.bin'))
        ..writeAsBytesSync([1, 2, 3]);
      final binaryText = File(path.join(inputDirectory.path, 'binary.txt'))
        ..writeAsBytesSync([0, 1, 2, 3, 0xff]);
      final service = createService();

      await _expectFailure(
        service.ingest(
          DataBankIngestionRequest(
            sourceFile: binaryText,
            documentVersionId: 'version-binary',
          ),
        ),
        DataBankIngestionFailureCode.invalidEncoding,
      );
      await _expectFailure(
        service.ingest(
          DataBankIngestionRequest(
            sourceFile: empty,
            documentVersionId: 'version-empty',
          ),
        ),
        DataBankIngestionFailureCode.emptyDocument,
      );
      await _expectFailure(
        service.ingest(
          DataBankIngestionRequest(
            sourceFile: damaged,
            documentVersionId: 'version-damaged',
          ),
        ),
        DataBankIngestionFailureCode.corruptDocument,
      );
      await _expectFailure(
        service.ingest(
          DataBankIngestionRequest(
            sourceFile: encrypted,
            documentVersionId: 'version-encrypted',
          ),
        ),
        DataBankIngestionFailureCode.encryptedDocument,
      );
      await _expectFailure(
        service.ingest(
          DataBankIngestionRequest(
            sourceFile: unsupported,
            documentVersionId: 'version-unsupported',
          ),
        ),
        DataBankIngestionFailureCode.unsupportedFormat,
      );
      _expectNoStagingArtifacts(stagingRoot);
    });

    test('PDF password failures retain the encrypted-document error code',
        () async {
      final source = File(path.join(inputDirectory.path, 'locked.pdf'))
        ..writeAsBytesSync(buildPdfFixture(['Locked']));

      await _expectFailure(
        createService(
          pdfTextExtractor: const _ThrowingPdfTextExtractor(
            DataBankIngestionFailureCode.encryptedDocument,
          ),
        ).ingest(
          DataBankIngestionRequest(
            sourceFile: source,
            documentVersionId: 'version-locked-pdf',
          ),
        ),
        DataBankIngestionFailureCode.encryptedDocument,
      );
      _expectNoStagingArtifacts(stagingRoot);
    });

    test('large-file cancellation returns no result and removes staging files',
        () async {
      final source = File(path.join(inputDirectory.path, 'large.txt'))
        ..writeAsBytesSync(List<int>.filled(1024 * 1024, 0x61));
      final token = DataBankCancellationToken();

      await _expectFailure(
        createService().ingest(
          DataBankIngestionRequest(
            sourceFile: source,
            documentVersionId: 'version-cancelled',
            cancellationToken: token,
            onProgress: (progress) {
              if (progress.phase == DataBankIngestionPhase.staging &&
                  progress.completedUnits > 0) {
                token.cancel();
              }
            },
          ),
        ),
        DataBankIngestionFailureCode.cancelled,
      );
      _expectNoStagingArtifacts(stagingRoot);
    });
  });
}

void _expectExactProvenance(DataBankIngestionResult result) {
  final sectionIds = result.sections.map((section) => section.id).toSet();
  for (final section in result.sections) {
    final locator = section.locator;
    expect(locator.documentVersionId, section.documentVersionId);
    expect(locator.sectionId, section.id);
    expect(
      result.normalizedText.substring(
        locator.startOffset!,
        locator.endOffset!,
      ),
      isNotEmpty,
    );
  }
  for (final chunk in result.chunks) {
    final locator = chunk.locator;
    expect(sectionIds, contains(chunk.sectionId));
    expect(locator.documentVersionId, chunk.documentVersionId);
    expect(locator.sectionId, chunk.sectionId);
    expect(
      result.normalizedText.substring(
        locator.startOffset!,
        locator.endOffset!,
      ),
      chunk.text,
    );
  }
}

void _expectNoStagingArtifacts(Directory stagingRoot) {
  expect(stagingRoot.listSync(), isEmpty);
}

Future<void> _expectFailure(
  Future<DataBankIngestionResult> future,
  DataBankIngestionFailureCode code,
) async {
  await expectLater(
    future,
    throwsA(
      isA<DataBankIngestionException>()
          .having((error) => error.code, 'code', code),
    ),
  );
}

final class _FixturePdfTextExtractor implements DataBankPdfTextExtractor {
  final List<int>? expectedBytes;
  final List<DataBankPdfPage> pages;
  bool called = false;

  _FixturePdfTextExtractor({
    this.expectedBytes,
    this.pages = const [
      DataBankPdfPage(pageNumber: 1, text: 'Fixture PDF text'),
    ],
  });

  @override
  Future<List<DataBankPdfPage>> extractPages(
    File file, {
    required DataBankCancellationToken cancellationToken,
    required void Function(int completedPages, int totalPages) onProgress,
  }) async {
    called = true;
    cancellationToken.throwIfCancelled();
    if (expectedBytes != null) {
      expect(await file.readAsBytes(), expectedBytes);
    }
    for (var index = 0; index < pages.length; index++) {
      onProgress(index + 1, pages.length);
      cancellationToken.throwIfCancelled();
    }
    return pages;
  }
}

final class _ThrowingPdfTextExtractor implements DataBankPdfTextExtractor {
  final DataBankIngestionFailureCode code;

  const _ThrowingPdfTextExtractor(this.code);

  @override
  Future<List<DataBankPdfPage>> extractPages(
    File file, {
    required DataBankCancellationToken cancellationToken,
    required void Function(int completedPages, int totalPages) onProgress,
  }) {
    throw DataBankIngestionException(code, 'Fixture PDF failure.');
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/data_bank_ingestion_service.dart';
import 'package:path/path.dart' as path;
import 'package:pdfrx/pdfrx.dart';

import 'support/data_bank_document_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pdfiumModulePath = Platform.environment['PDFIUM_MODULE_PATH'];
  final skipWithoutPdfium = pdfiumModulePath == null
      ? 'Set PDFIUM_MODULE_PATH to run the native PDFium integration test.'
      : false;

  setUpAll(() {
    if (pdfiumModulePath != null) {
      Pdfrx.pdfiumModulePath = pdfiumModulePath;
    }
  });

  test(
    'real PDFium ingestion extracts text with page provenance',
    () async {
      final sandbox = Directory.systemTemp.createTempSync('data_bank_pdf_e2e_');
      final stagingRoot = Directory(path.join(sandbox.path, 'staging'))
        ..createSync();
      var stageIndex = 0;
      try {
        final source = File(path.join(sandbox.path, 'two-pages.pdf'))
          ..writeAsBytesSync(
            buildPdfFixture(
                ['First native PDF page', 'Second native PDF page']),
          );
        final service = DataBankIngestionService(
          createStagingDirectory: () async {
            final directory = Directory(
              path.join(stagingRoot.path, 'stage-${stageIndex++}'),
            );
            await directory.create();
            return directory;
          },
        );

        final result = await service.ingest(
          DataBankIngestionRequest(
            sourceFile: source,
            documentVersionId: 'version-real-pdf',
          ),
        );

        expect(result.normalizedText, contains('First native PDF page'));
        expect(result.normalizedText, contains('Second native PDF page'));
        expect(
          result.sections.map((section) => section.locator.pageStart),
          [1, 2],
        );
        for (final chunk in result.chunks) {
          expect(
            result.normalizedText.substring(
              chunk.locator.startOffset!,
              chunk.locator.endOffset!,
            ),
            chunk.text,
          );
        }
        expect(stagingRoot.listSync(), isEmpty);
      } finally {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      }
    },
    skip: skipWithoutPdfium,
  );

  test(
    'real PDFium rejects a damaged PDF without staging residue',
    () async {
      final sandbox = Directory.systemTemp.createTempSync('data_bank_pdf_e2e_');
      final stagingRoot = Directory(path.join(sandbox.path, 'staging'))
        ..createSync();
      try {
        final source = File(path.join(sandbox.path, 'damaged.pdf'))
          ..writeAsStringSync('%PDF-1.4\nnot a valid document');
        final service = DataBankIngestionService(
          createStagingDirectory: () async {
            final directory = Directory(path.join(stagingRoot.path, 'stage'));
            await directory.create();
            return directory;
          },
        );

        await expectLater(
          service.ingest(
            DataBankIngestionRequest(
              sourceFile: source,
              documentVersionId: 'version-damaged-pdf',
            ),
          ),
          throwsA(
            isA<DataBankIngestionException>().having(
              (error) => error.code,
              'code',
              DataBankIngestionFailureCode.corruptDocument,
            ),
          ),
        );
        expect(stagingRoot.listSync(), isEmpty);
      } finally {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      }
    },
    skip: skipWithoutPdfium,
  );
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

Uint8List buildPdfFixture(List<String> pageTexts) {
  if (pageTexts.isEmpty) {
    throw ArgumentError.value(pageTexts, 'pageTexts', 'must not be empty');
  }
  if (pageTexts.any((text) => text.codeUnits.any((unit) => unit > 0x7f))) {
    throw ArgumentError('The minimal PDF fixture supports ASCII text only.');
  }

  final pageIds = [
    for (var index = 0; index < pageTexts.length; index++) 4 + index * 2
  ];
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${pageIds.map((id) => '$id 0 R').join(' ')}] '
        '/Count ${pageTexts.length} >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];

  for (var index = 0; index < pageTexts.length; index++) {
    final contentId = pageIds[index] + 1;
    final escapedText = pageTexts[index]
        .replaceAll(r'\', r'\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)');
    final stream = 'BT /F1 18 Tf 72 720 Td ($escapedText) Tj ET';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 3 0 R >> >> '
      '/Contents $contentId 0 R >>',
    );
    objects.add('<< /Length ${stream.length} >>\nstream\n$stream\nendstream');
  }

  final output = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(output.length);
    output
      ..writeln('${index + 1} 0 obj')
      ..writeln(objects[index])
      ..writeln('endobj');
  }
  final xrefOffset = output.length;
  output
    ..writeln('xref')
    ..writeln('0 ${objects.length + 1}')
    ..writeln('0000000000 65535 f ');
  for (final offset in offsets.skip(1)) {
    output.writeln('${offset.toString().padLeft(10, '0')} 00000 n ');
  }
  output
    ..writeln('trailer')
    ..writeln('<< /Size ${objects.length + 1} /Root 1 0 R >>')
    ..writeln('startxref')
    ..writeln(xrefOffset)
    ..writeln('%%EOF');
  return Uint8List.fromList(ascii.encode(output.toString()));
}

Uint8List buildEpubFixture({bool encryptSecondChapter = false}) {
  final files = <String, String>{
    'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''',
    'OEBPS/package.opf': '''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">fixture-book</dc:identifier>
    <dc:title>Fixture Book</dc:title>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter-one" href="text/chapter-one.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter-two" href="text/chapter-two.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter-one"/>
    <itemref idref="chapter-two"/>
  </spine>
</package>
''',
    'OEBPS/nav.xhtml': '''
<!doctype html>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <nav><ol>
    <li><a href="text/chapter-one.xhtml">Arrival</a></li>
    <li><a href="text/chapter-two.xhtml">Safe Harbor</a></li>
  </ol></nav>
</body></html>
''',
    'OEBPS/text/chapter-one.xhtml': '''
<!doctype html>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <h1>Arrival</h1><p>The train arrived before dawn.</p>
</body></html>
''',
    'OEBPS/text/chapter-two.xhtml': '''
<!doctype html>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <h1>Safe Harbor</h1><p>Ships enter from the eastern channel.</p>
</body></html>
''',
    if (encryptSecondChapter)
      'META-INF/encryption.xml': '''
<?xml version="1.0"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/text/chapter-two.xhtml"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>
''',
  };

  final archive = Archive()
    ..addFile(
      ArchiveFile.noCompress(
        'mimetype',
        'application/epub+zip'.length,
        utf8.encode('application/epub+zip'),
      ),
    );
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value.trim());
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

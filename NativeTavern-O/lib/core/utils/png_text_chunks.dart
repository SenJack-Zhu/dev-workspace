import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Extracts a named textual metadata value from a PNG file.
///
/// Character cards in the wild use tEXt, compressed zTXt, and international
/// iTXt chunks. SillyTavern V3 cards may also use the `ccv3` keyword.
String? extractPngTextChunk(Uint8List bytes, String keyword) {
  const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < signature.length) return null;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return null;
  }

  var offset = 8;
  while (offset + 12 <= bytes.length) {
    final length = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final typeStart = offset + 4;
    final dataStart = offset + 8;
    final dataEnd = dataStart + length;
    final chunkEnd = dataEnd + 4;
    if (length < 0 || dataEnd < dataStart || chunkEnd > bytes.length) {
      return null;
    }

    final type = ascii.decode(bytes.sublist(typeStart, dataStart));
    final data = bytes.sublist(dataStart, dataEnd);
    final value = switch (type) {
      'tEXt' => _decodeText(data, keyword),
      'zTXt' => _decodeCompressedText(data, keyword),
      'iTXt' => _decodeInternationalText(data, keyword),
      _ => null,
    };
    if (value != null) return value;
    if (type == 'IEND') return null;
    offset = chunkEnd;
  }
  return null;
}

String? _decodeText(List<int> data, String keyword) {
  final separator = data.indexOf(0);
  if (separator <= 0) return null;
  if (latin1.decode(data.sublist(0, separator)) != keyword) return null;
  return latin1.decode(data.sublist(separator + 1));
}

String? _decodeCompressedText(List<int> data, String keyword) {
  final separator = data.indexOf(0);
  if (separator <= 0 || separator + 2 > data.length) return null;
  if (latin1.decode(data.sublist(0, separator)) != keyword) return null;
  if (data[separator + 1] != 0) return null;
  try {
    return latin1.decode(zlib.decode(data.sublist(separator + 2)));
  } catch (_) {
    return null;
  }
}

String? _decodeInternationalText(List<int> data, String keyword) {
  final keywordEnd = data.indexOf(0);
  if (keywordEnd <= 0 || keywordEnd + 3 > data.length) return null;
  if (latin1.decode(data.sublist(0, keywordEnd)) != keyword) return null;

  final compressionFlag = data[keywordEnd + 1];
  final compressionMethod = data[keywordEnd + 2];
  var cursor = keywordEnd + 3;
  final languageEnd = data.indexOf(0, cursor);
  if (languageEnd < 0) return null;
  cursor = languageEnd + 1;
  final translatedKeywordEnd = data.indexOf(0, cursor);
  if (translatedKeywordEnd < 0) return null;
  cursor = translatedKeywordEnd + 1;

  try {
    final payload = compressionFlag == 1
        ? (compressionMethod == 0 ? zlib.decode(data.sublist(cursor)) : null)
        : data.sublist(cursor);
    return payload == null ? null : utf8.decode(payload);
  } catch (_) {
    return null;
  }
}

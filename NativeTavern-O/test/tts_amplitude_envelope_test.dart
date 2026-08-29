import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/tts_amplitude_envelope.dart';

void main() {
  test('extracts a normalized envelope from PCM WAV audio', () {
    final envelope = TTSAmplitudeEnvelope.tryParseWav(
      _wav16([
        ...List<int>.filled(80, 0),
        for (var index = 0; index < 160; index++)
          (math.sin(index / 5) * 28000).round(),
        ...List<int>.filled(80, 0),
      ]),
      targetSamples: 16,
    );

    expect(envelope, isNotNull);
    expect(envelope!.sampleCount, 16);
    expect(envelope.sample(0), lessThan(0.1));
    expect(envelope.sample(0.5), greaterThan(0.8));
    expect(envelope.sample(1), lessThan(0.1));
  });

  test('rejects compressed or malformed audio safely', () {
    expect(
      TTSAmplitudeEnvelope.tryParseWav(Uint8List.fromList([1, 2, 3])),
      isNull,
    );
  });

  test('system progress and compressed-audio fallbacks stay normalized', () {
    expect(TTSAmplitudeEnvelope.fromSpokenWord('AEIOU'), 1);
    expect(
        TTSAmplitudeEnvelope.fromSpokenWord('rhythm'), inInclusiveRange(0, 1));
    expect(
      TTSAmplitudeEnvelope.fromTextProgress('Hello world', 0.45),
      inInclusiveRange(0, 1),
    );
    expect(TTSAmplitudeEnvelope.fromTextProgress('Hello', 0), 0);
    expect(TTSAmplitudeEnvelope.fromTextProgress('Hello', 1), 0);
  });
}

Uint8List _wav16(List<int> samples) {
  final dataLength = samples.length * 2;
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(bytes);
  _writeAscii(bytes, 0, 'RIFF');
  data.setUint32(4, 36 + dataLength, Endian.little);
  _writeAscii(bytes, 8, 'WAVE');
  _writeAscii(bytes, 12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  _writeAscii(bytes, 36, 'data');
  data.setUint32(40, dataLength, Endian.little);
  for (var index = 0; index < samples.length; index++) {
    data.setInt16(44 + index * 2, samples[index], Endian.little);
  }
  return bytes;
}

void _writeAscii(Uint8List bytes, int offset, String value) {
  for (var index = 0; index < value.length; index++) {
    bytes[offset + index] = value.codeUnitAt(index);
  }
}

import 'dart:math' as math;
import 'dart:typed_data';

/// A normalized amplitude envelope sampled from PCM audio.
class TTSAmplitudeEnvelope {
  const TTSAmplitudeEnvelope._(this._values);

  final List<double> _values;

  int get sampleCount => _values.length;

  double sample(double progress) {
    if (_values.isEmpty) return 0;
    final position = progress.clamp(0.0, 1.0) * (_values.length - 1);
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return _values[lower];
    final weight = position - lower;
    return (_values[lower] * (1 - weight) + _values[upper] * weight).clamp(
      0.0,
      1.0,
    );
  }

  /// Parses uncompressed PCM WAV data. Compressed formats return null and use
  /// playback-position speech activity as a graceful fallback.
  static TTSAmplitudeEnvelope? tryParseWav(
    Uint8List bytes, {
    int targetSamples = 240,
  }) {
    if (bytes.length < 44 ||
        _ascii(bytes, 0, 4) != 'RIFF' ||
        _ascii(bytes, 8, 4) != 'WAVE') {
      return null;
    }

    final data = ByteData.sublistView(bytes);
    int? channels;
    int? bitsPerSample;
    int? audioFormat;
    int? pcmOffset;
    int? pcmLength;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final chunkId = _ascii(bytes, offset, 4);
      final chunkLength = data.getUint32(offset + 4, Endian.little);
      final contentOffset = offset + 8;
      if (contentOffset + chunkLength > bytes.length) return null;
      if (chunkId == 'fmt ' && chunkLength >= 16) {
        audioFormat = data.getUint16(contentOffset, Endian.little);
        channels = data.getUint16(contentOffset + 2, Endian.little);
        bitsPerSample = data.getUint16(contentOffset + 14, Endian.little);
      } else if (chunkId == 'data') {
        pcmOffset = contentOffset;
        pcmLength = chunkLength;
      }
      offset = contentOffset + chunkLength + (chunkLength.isOdd ? 1 : 0);
    }

    if (audioFormat != 1 ||
        channels == null ||
        channels <= 0 ||
        bitsPerSample == null ||
        !const {8, 16, 24, 32}.contains(bitsPerSample) ||
        pcmOffset == null ||
        pcmLength == null ||
        pcmLength <= 0) {
      return null;
    }

    final bytesPerSample = bitsPerSample ~/ 8;
    final frameSize = bytesPerSample * channels;
    final frameCount = pcmLength ~/ frameSize;
    if (frameCount == 0) return null;
    final binCount = math.min(math.max(1, targetSamples), frameCount);
    final values = List<double>.filled(binCount, 0);
    var peak = 0.0;

    for (var bin = 0; bin < binCount; bin++) {
      final firstFrame = (bin * frameCount / binCount).floor();
      final lastFrame = math.max(
        firstFrame + 1,
        ((bin + 1) * frameCount / binCount).floor(),
      );
      var sumSquares = 0.0;
      var samples = 0;
      for (var frame = firstFrame; frame < lastFrame; frame++) {
        for (var channel = 0; channel < channels; channel++) {
          final sampleOffset =
              pcmOffset + frame * frameSize + channel * bytesPerSample;
          final normalized = _readPcmSample(data, sampleOffset, bitsPerSample);
          sumSquares += normalized * normalized;
          samples++;
        }
      }
      final rms = samples == 0 ? 0.0 : math.sqrt(sumSquares / samples);
      values[bin] = rms;
      peak = math.max(peak, rms);
    }

    if (peak <= 0) return TTSAmplitudeEnvelope._(values);
    for (var index = 0; index < values.length; index++) {
      values[index] = math.sqrt(values[index] / peak).clamp(0.0, 1.0);
    }
    return TTSAmplitudeEnvelope._(List<double>.unmodifiable(values));
  }

  /// System TTS exposes real spoken-word progress instead of raw PCM. This
  /// converts the currently audible word into a stable mouth-open pulse.
  static double fromSpokenWord(String word) {
    final letters = word.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (letters.isEmpty) return 0.18;
    final openSounds = RegExp(r'[aeiouy]').allMatches(letters).length;
    final openness = 0.38 + (openSounds / letters.length) * 0.62;
    return openness.clamp(0.2, 1.0);
  }

  /// Fallback for compressed audio: timing still comes from the real player,
  /// while nearby text controls a restrained speech-activity pulse.
  static double fromTextProgress(String text, double progress) {
    if (text.isEmpty || progress <= 0 || progress >= 1) return 0;
    final index = (progress.clamp(0.0, 1.0) * (text.length - 1)).round();
    final character = text[index];
    if (RegExp(r'\s|[.,!?;:，。！？；：]').hasMatch(character)) return 0.08;
    final pulse = 0.58 + 0.24 * math.sin(progress * math.pi * 38).abs();
    return pulse.clamp(0.2, 0.9);
  }

  static double _readPcmSample(ByteData data, int offset, int bitsPerSample) {
    return switch (bitsPerSample) {
      8 => (data.getUint8(offset) - 128) / 128,
      16 => data.getInt16(offset, Endian.little) / 32768,
      24 => _readInt24(data, offset) / 8388608,
      32 => data.getInt32(offset, Endian.little) / 2147483648,
      _ => 0,
    };
  }

  static int _readInt24(ByteData data, int offset) {
    var value = data.getUint8(offset) |
        (data.getUint8(offset + 1) << 8) |
        (data.getUint8(offset + 2) << 16);
    if ((value & 0x800000) != 0) value |= ~0xffffff;
    return value;
  }

  static String _ascii(Uint8List bytes, int offset, int length) {
    if (offset < 0 || offset + length > bytes.length) return '';
    return String.fromCharCodes(bytes.sublist(offset, offset + length));
  }
}

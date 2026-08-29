import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/stt_service.dart';
import 'package:native_tavern/domain/services/voice_adapter_contract.dart';

void main() {
  late Directory directory;
  late File audioFile;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('native_tavern_stt_');
    audioFile = File('${directory.path}/speech.wav');
    audioFile.writeAsBytesSync([0x52, 0x49, 0x46, 0x46]);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('ElevenLabs adapter sends the shared multipart request contract',
      () async {
    final adapter = _JsonAdapter({'text': 'hello from elevenlabs'});
    final backend = DioRemoteSTTBackend(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final result = await backend.transcribe(
      audioPath: audioFile.path,
      settings: const STTSettings(
        enabled: true,
        provider: STTProvider.elevenLabs,
        apiKey: 'eleven-key',
        apiEndpoint: 'https://voice.example/v1/',
        language: 'en-US',
        requestTimeout: Duration(seconds: 7),
      ),
      cancelToken: CancelToken(),
    );

    expect(result.text, 'hello from elevenlabs');
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.uri.toString(), 'https://voice.example/v1/speech-to-text');
    expect(request.headers['xi-api-key'], 'eleven-key');
    expect(request.sendTimeout, const Duration(seconds: 7));
    expect(request.receiveTimeout, const Duration(seconds: 7));
    expect(request.contentType, startsWith('multipart/form-data'));
  });

  test('legacy Whisper settings migrate to OpenAI-compatible transcription',
      () async {
    final settings = STTSettings.fromJson(const {
      'enabled': true,
      'provider': 'whisper',
      'apiKey': 'openai-key',
      'language': 'en-US',
    });
    final adapter = _JsonAdapter({'text': 'migrated transcript'});
    final backend = DioRemoteSTTBackend(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final result = await backend.transcribe(
      audioPath: audioFile.path,
      settings: settings,
      cancelToken: CancelToken(),
    );

    expect(settings.provider, STTProvider.openAICompatible);
    expect(result.text, 'migrated transcript');
    expect(
      adapter.requests.single.uri.toString(),
      'https://api.openai.com/v1/audio/transcriptions',
    );
    expect(
      adapter.requests.single.headers['Authorization'],
      'Bearer openai-key',
    );
  });

  test('self-hosted adapter supports an endpoint without an API key', () async {
    final adapter = _JsonAdapter({'text': 'local transcript'});
    final backend = DioRemoteSTTBackend(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final result = await backend.transcribe(
      audioPath: audioFile.path,
      settings: const STTSettings(
        enabled: true,
        provider: STTProvider.selfHosted,
        apiEndpoint: 'http://127.0.0.1:8080/v1/audio/transcriptions',
      ),
      cancelToken: CancelToken(),
    );

    expect(result.text, 'local transcript');
    expect(adapter.requests.single.headers['Authorization'], isNull);
    expect(
      adapter.requests.single.uri.toString(),
      'http://127.0.0.1:8080/v1/audio/transcriptions',
    );
  });

  test('adapter rejects missing configuration without touching HTTP', () async {
    final adapter = _JsonAdapter({'text': 'must not be used'});
    final backend = DioRemoteSTTBackend(
      dio: Dio()..httpClientAdapter = adapter,
    );

    await expectLater(
      backend.transcribe(
        audioPath: audioFile.path,
        settings: const STTSettings(
          enabled: true,
          provider: STTProvider.selfHosted,
        ),
        cancelToken: CancelToken(),
      ),
      throwsA(
        isA<VoiceAdapterException>().having(
          (error) => error.kind,
          'kind',
          VoiceAdapterErrorKind.configuration,
        ),
      ),
    );
    expect(adapter.requests, isEmpty);
  });
}

class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.response);

  final Map<String, Object?> response;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

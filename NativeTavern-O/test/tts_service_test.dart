import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/tts_service.dart';
import 'package:native_tavern/domain/services/voice_adapter_contract.dart';

import 'support/fake_system_tts_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSystemTTSBackend backend;
  late TTSService service;

  setUp(() async {
    backend = FakeSystemTTSBackend();
    service = TTSService(systemTts: backend);
    service.updateSettings(const TTSSettings(
      enabled: true,
      provider: TTSProvider.system,
      queueMessages: true,
    ));
    await service.initialize();
  });

  tearDown(() {
    service.dispose();
  });

  test('queues messages with their own character and source scope', () async {
    service.setCharacterVoice(const CharacterVoiceSettings(
      characterId: 'character-1',
      voiceId: 'voice-a',
      rate: 1.4,
      pitch: 0.8,
      volume: 0.7,
    ));
    final observed = <TTSPlaybackState>[];
    final subscription = service.playbackStates.listen(observed.add);

    final first = service.speak(
      'First sentence.',
      characterId: 'character-1',
      ownerId: 'chat-1',
      sourceId: 'message-1',
    );
    await backend.waitForSpeakCount(1);
    final second = service.speak(
      'Second sentence.',
      characterId: 'character-2',
      ownerId: 'chat-1',
      sourceId: 'message-2',
    );
    await _flush();

    expect(service.playbackState.sourceId, 'message-1');
    expect(service.playbackState.queueDepth, 1);
    expect(backend.lastRate, closeTo(0.7, 0.001));
    expect(backend.lastPitch, 0.8);
    expect(backend.lastVolume, 0.7);
    expect(backend.lastVoice, ('voice-a', 'en-US'));
    expect(backend.audioFocusRequests, [true]);

    backend.progress(0, 5, 'First');
    expect(service.playbackState.spokenText, 'First');
    expect(service.playbackState.mouthOpen, greaterThan(0));
    backend.completeCurrent();
    await backend.waitForSpeakCount(2);

    expect(service.playbackState.sourceId, 'message-2');
    expect(service.playbackState.characterId, 'character-2');
    backend.completeCurrent();
    await Future.wait([first, second]);

    expect(backend.spokenTexts, ['First sentence.', 'Second sentence.']);
    expect(service.playbackState.phase, TTSPlaybackPhase.completed);
    expect(service.playbackState.mouthOpen, 0);
    expect(
      observed.where((state) => state.phase == TTSPlaybackPhase.playing),
      isNotEmpty,
    );
    await subscription.cancel();
  });

  test('pauses and resumes system speech from the spoken offset', () async {
    final speaking = service.speak(
      'Hello world',
      ownerId: 'chat-1',
      sourceId: 'message-1',
    );
    await backend.waitForSpeakCount(1);
    backend.progress(0, 6, 'Hello');

    await service.pause();
    expect(service.playbackState.phase, TTSPlaybackPhase.paused);
    expect(service.playbackState.mouthOpen, 0);
    expect(backend.pauseCount, 1);

    await service.resume();
    await backend.waitForSpeakCount(2);
    expect(backend.spokenTexts, ['Hello world', 'world']);
    expect(service.playbackState.phase, TTSPlaybackPhase.playing);

    backend.completeCurrent();
    await speaking;
    expect(service.playbackState.phase, TTSPlaybackPhase.completed);
  });

  test('pause resumes even when the system omits its pause callback', () async {
    backend.invokePauseHandler = false;
    final speaking = service.speak(
      'Hello world',
      ownerId: 'chat-1',
      sourceId: 'message-1',
    );
    await backend.waitForSpeakCount(1);
    backend.progress(0, 6, 'Hello');

    await service.pause();
    await service.resume();
    await backend.waitForSpeakCount(2);

    expect(backend.spokenTexts, ['Hello world', 'world']);
    backend.completeCurrent();
    await speaking;
    expect(service.playbackState.phase, TTSPlaybackPhase.completed);
  });

  test('owner-scoped stop removes only matching queued playback', () async {
    final first = service.speak(
      'Keep playing',
      ownerId: 'chat-1',
      sourceId: 'message-1',
    );
    await backend.waitForSpeakCount(1);
    final second = service.speak(
      'Remove me',
      ownerId: 'chat-2',
      sourceId: 'message-2',
    );

    await service.stop(ownerId: 'chat-2');
    await second;
    expect(service.playbackState.phase, TTSPlaybackPhase.playing);
    expect(service.playbackState.ownerId, 'chat-1');
    expect(backend.stopCount, 0);

    await service.stop(ownerId: 'chat-1');
    await first;
    expect(service.playbackState.phase, TTSPlaybackPhase.cancelled);
    expect(service.playbackState.mouthOpen, 0);
    expect(backend.stopCount, 1);
  });

  test('queue waits for the platform stop before starting the next owner',
      () async {
    final first = service.speak(
      'Stop first',
      ownerId: 'chat-1',
      sourceId: 'message-1',
    );
    await backend.waitForSpeakCount(1);
    final second = service.speak(
      'Play second',
      ownerId: 'chat-2',
      sourceId: 'message-2',
    );
    backend.holdStop();

    final stopping = service.stop(ownerId: 'chat-1');
    await first;
    await _flush();
    expect(backend.spokenTexts, ['Stop first']);

    backend.releaseStop();
    await stopping;
    await backend.waitForSpeakCount(2);
    expect(backend.spokenTexts, ['Stop first', 'Play second']);

    backend.completeCurrent();
    await second;
  });

  test('platform interruption and app background terminate playback', () async {
    final interrupted = service.speak(
      'Interrupted',
      ownerId: 'chat-1',
      sourceId: 'message-1',
    );
    await backend.waitForSpeakCount(1);
    backend.cancelCurrent();
    await interrupted;
    expect(service.playbackState.phase, TTSPlaybackPhase.cancelled);

    final backgrounded = service.speak(
      'Backgrounded',
      ownerId: 'chat-1',
      sourceId: 'message-2',
    );
    await backend.waitForSpeakCount(2);
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await backgrounded;
    expect(service.playbackState.phase, TTSPlaybackPhase.cancelled);
    expect(service.playbackState.mouthOpen, 0);
  });

  test('platform errors are observable and do not hang the queue', () async {
    final failed = service.speak(
      'Failure',
      ownerId: 'chat-1',
      sourceId: 'message-1',
    );
    await backend.waitForSpeakCount(1);
    backend.failCurrent('engine unavailable');
    await failed;

    expect(service.playbackState.phase, TTSPlaybackPhase.failed);
    expect(service.playbackState.error, contains('engine unavailable'));
    expect(service.isSpeaking, isFalse);
  });

  test('unconfigured remote TTS fails before any network request', () async {
    final adapter = _VoiceAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final remoteService = TTSService(dio: dio, systemTts: backend);
    remoteService.updateSettings(
      const TTSSettings(
        enabled: true,
        provider: TTSProvider.openaiCompatible,
      ),
    );

    await expectLater(
      remoteService.synthesize('hello'),
      throwsA(
        isA<VoiceAdapterException>().having(
          (error) => error.kind,
          'kind',
          VoiceAdapterErrorKind.configuration,
        ),
      ),
    );
    expect(adapter.fetchCount, 0);
    remoteService.dispose();
  });

  test('remote TTS normalizes timeout and cancellation', () async {
    final timeoutAdapter = _VoiceAdapter(timeout: true);
    final timeoutService = TTSService(
      dio: Dio()..httpClientAdapter = timeoutAdapter,
      systemTts: backend,
    );
    timeoutService.updateSettings(
      const TTSSettings(
        enabled: true,
        provider: TTSProvider.elevenlabs,
        apiKey: 'test-key',
      ),
    );
    await expectLater(
      timeoutService.synthesize('hello'),
      throwsA(
        isA<VoiceAdapterException>().having(
          (error) => error.kind,
          'kind',
          VoiceAdapterErrorKind.timeout,
        ),
      ),
    );
    expect(timeoutAdapter.lastOptions?.sendTimeout, defaultVoiceRequestTimeout);
    timeoutService.dispose();

    final waitingAdapter = _VoiceAdapter(waitForCancellation: true);
    final cancellingService = TTSService(
      dio: Dio()..httpClientAdapter = waitingAdapter,
      systemTts: backend,
    );
    cancellingService.updateSettings(
      const TTSSettings(
        enabled: true,
        provider: TTSProvider.elevenlabs,
        apiKey: 'test-key',
      ),
    );
    final synthesis = cancellingService.synthesize('cancel me');
    await waitingAdapter.started.future;
    await cancellingService.stop();
    await expectLater(
      synthesis,
      throwsA(
        isA<VoiceAdapterException>().having(
          (error) => error.kind,
          'kind',
          VoiceAdapterErrorKind.cancelled,
        ),
      ),
    );
    cancellingService.dispose();
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _VoiceAdapter implements HttpClientAdapter {
  _VoiceAdapter({this.timeout = false, this.waitForCancellation = false});

  final bool timeout;
  final bool waitForCancellation;
  final Completer<void> started = Completer<void>();
  int fetchCount = 0;
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount++;
    lastOptions = options;
    if (!started.isCompleted) started.complete();
    if (timeout) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      );
    }
    if (waitForCancellation) {
      await cancelFuture;
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: 'cancelled',
      );
    }
    return ResponseBody.fromBytes([1, 2, 3], 200);
  }

  @override
  void close({bool force = false}) {}
}

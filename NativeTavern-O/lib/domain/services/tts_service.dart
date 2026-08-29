import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:native_tavern/domain/services/ai_data_sharing_consent_service.dart';
import 'package:native_tavern/domain/services/tts_amplitude_envelope.dart';
import 'package:native_tavern/domain/services/voice_adapter_contract.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:native_tavern/domain/services/external_call_audit_service.dart';

/// TTS Provider types
enum TTSProvider {
  system('system', 'System TTS'),
  elevenlabs('elevenlabs', 'ElevenLabs'),
  azure('azure', 'Azure Speech'),
  volcengine('volcengine', 'Volcengine (火山引擎)'),
  gptSovits('gpt_sovits', 'GPT-SoVITS'),
  openaiCompatible('openai_compatible', 'OAI Compatible');

  final String id;
  final String displayName;

  const TTSProvider(this.id, this.displayName);

  static TTSProvider? fromId(String id) {
    try {
      return TTSProvider.values.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}

/// TTS Voice configuration
class TTSVoice {
  final String id;
  final String name;
  final String? language;
  final String? gender;
  final TTSProvider provider;

  const TTSVoice({
    required this.id,
    required this.name,
    this.language,
    this.gender,
    required this.provider,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'language': language,
        'gender': gender,
        'provider': provider.id,
      };

  factory TTSVoice.fromJson(Map<String, dynamic> json) => TTSVoice(
        id: json['id'] as String,
        name: json['name'] as String,
        language: json['language'] as String?,
        gender: json['gender'] as String?,
        provider: TTSProvider.fromId(json['provider'] as String) ??
            TTSProvider.system,
      );
}

/// TTS Settings
class TTSSettings {
  final bool enabled;
  final TTSProvider provider;
  final String? voiceId;
  final double rate;
  final double pitch;
  final double volume;
  final bool autoPlay;
  final bool queueMessages;
  final String? apiKey;
  final String? apiEndpoint;

  /// Provider-specific extras (e.g. Volcengine appId/cluster,
  /// GPT-SoVITS reference audio settings, OpenAI-compatible model name)
  final Map<String, String> providerOptions;

  const TTSSettings({
    this.enabled = false,
    this.provider = TTSProvider.system,
    this.voiceId,
    this.rate = 1.0,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.autoPlay = false,
    this.queueMessages = true,
    this.apiKey,
    this.apiEndpoint,
    this.providerOptions = const {},
  });

  TTSSettings copyWith({
    bool? enabled,
    TTSProvider? provider,
    String? voiceId,
    double? rate,
    double? pitch,
    double? volume,
    bool? autoPlay,
    bool? queueMessages,
    String? apiKey,
    String? apiEndpoint,
    Map<String, String>? providerOptions,
  }) {
    return TTSSettings(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      voiceId: voiceId ?? this.voiceId,
      rate: rate ?? this.rate,
      pitch: pitch ?? this.pitch,
      volume: volume ?? this.volume,
      autoPlay: autoPlay ?? this.autoPlay,
      queueMessages: queueMessages ?? this.queueMessages,
      apiKey: apiKey ?? this.apiKey,
      apiEndpoint: apiEndpoint ?? this.apiEndpoint,
      providerOptions: providerOptions ?? this.providerOptions,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'provider': provider.id,
        'voiceId': voiceId,
        'rate': rate,
        'pitch': pitch,
        'volume': volume,
        'autoPlay': autoPlay,
        'queueMessages': queueMessages,
        'apiKey': apiKey,
        'apiEndpoint': apiEndpoint,
        'providerOptions': providerOptions,
      };

  factory TTSSettings.fromJson(Map<String, dynamic> json) => TTSSettings(
        enabled: json['enabled'] as bool? ?? false,
        provider: TTSProvider.fromId(json['provider'] as String? ?? 'system') ??
            TTSProvider.system,
        voiceId: json['voiceId'] as String?,
        rate: (json['rate'] as num?)?.toDouble() ?? 1.0,
        pitch: (json['pitch'] as num?)?.toDouble() ?? 1.0,
        volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
        autoPlay: json['autoPlay'] as bool? ?? false,
        queueMessages: json['queueMessages'] as bool? ?? true,
        apiKey: json['apiKey'] as String?,
        apiEndpoint: json['apiEndpoint'] as String?,
        providerOptions:
            (json['providerOptions'] as Map<String, dynamic>?)?.map(
                  (k, v) => MapEntry(k, v.toString()),
                ) ??
                const {},
      );
}

/// Character voice settings
class CharacterVoiceSettings {
  final String characterId;
  final String? voiceId;
  final double? rate;
  final double? pitch;
  final double? volume;

  const CharacterVoiceSettings({
    required this.characterId,
    this.voiceId,
    this.rate,
    this.pitch,
    this.volume,
  });

  Map<String, dynamic> toJson() => {
        'characterId': characterId,
        'voiceId': voiceId,
        'rate': rate,
        'pitch': pitch,
        'volume': volume,
      };

  factory CharacterVoiceSettings.fromJson(Map<String, dynamic> json) =>
      CharacterVoiceSettings(
        characterId: json['characterId'] as String,
        voiceId: json['voiceId'] as String?,
        rate: (json['rate'] as num?)?.toDouble(),
        pitch: (json['pitch'] as num?)?.toDouble(),
        volume: (json['volume'] as num?)?.toDouble(),
      );
}

enum TTSPlaybackPhase {
  idle,
  queued,
  playing,
  paused,
  completed,
  cancelled,
  failed,
}

@immutable
class TTSPlaybackState {
  const TTSPlaybackState({
    this.sessionId,
    this.ownerId,
    this.sourceId,
    this.characterId,
    this.text = '',
    this.spokenText = '',
    this.phase = TTSPlaybackPhase.idle,
    this.progress = 0,
    this.mouthOpen = 0,
    this.queueDepth = 0,
    this.error,
    this.sequence = 0,
  });

  final String? sessionId;
  final String? ownerId;
  final String? sourceId;
  final String? characterId;
  final String text;
  final String spokenText;
  final TTSPlaybackPhase phase;
  final double progress;
  final double mouthOpen;
  final int queueDepth;
  final String? error;

  /// Increases for every observable transition, including word progress.
  final int sequence;

  bool get isActive =>
      phase == TTSPlaybackPhase.queued ||
      phase == TTSPlaybackPhase.playing ||
      phase == TTSPlaybackPhase.paused;
  bool get isPlaying => phase == TTSPlaybackPhase.playing;
  bool get isPaused => phase == TTSPlaybackPhase.paused;

  TTSPlaybackState copyWith({
    String? sessionId,
    String? ownerId,
    String? sourceId,
    String? characterId,
    String? text,
    String? spokenText,
    TTSPlaybackPhase? phase,
    double? progress,
    double? mouthOpen,
    int? queueDepth,
    String? error,
    bool clearError = false,
    int? sequence,
  }) {
    return TTSPlaybackState(
      sessionId: sessionId ?? this.sessionId,
      ownerId: ownerId ?? this.ownerId,
      sourceId: sourceId ?? this.sourceId,
      characterId: characterId ?? this.characterId,
      text: text ?? this.text,
      spokenText: spokenText ?? this.spokenText,
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      mouthOpen: mouthOpen ?? this.mouthOpen,
      queueDepth: queueDepth ?? this.queueDepth,
      error: clearError ? null : (error ?? this.error),
      sequence: sequence ?? this.sequence,
    );
  }
}

typedef TTSProgressHandler = void Function(
    String text, int startOffset, int endOffset, String word);

/// Narrow platform boundary so playback lifecycle can be tested without a
/// device TTS engine.
abstract interface class SystemTTSBackend {
  void setStartHandler(VoidCallback handler);
  void setCompletionHandler(VoidCallback handler);
  void setPauseHandler(VoidCallback handler);
  void setContinueHandler(VoidCallback handler);
  void setCancelHandler(VoidCallback handler);
  void setProgressHandler(TTSProgressHandler handler);
  void setErrorHandler(void Function(String message) handler);
  Future<void> initialize();
  Future<List<Map<String, Object?>>> loadVoices();
  Future<void> setSpeechRate(double rate);
  Future<void> setPitch(double pitch);
  Future<void> setVolume(double volume);
  Future<void> setVoice(String name, String locale);
  Future<void> speak(String text, {required bool requestAudioFocus});
  Future<void> pause();
  Future<void> stop();
}

class FlutterSystemTTSBackend implements SystemTTSBackend {
  FlutterSystemTTSBackend([FlutterTts? flutterTts])
      : _flutterTts = flutterTts ?? FlutterTts();

  final FlutterTts _flutterTts;

  @override
  void setStartHandler(VoidCallback handler) =>
      _flutterTts.setStartHandler(handler);

  @override
  void setCompletionHandler(VoidCallback handler) =>
      _flutterTts.setCompletionHandler(handler);

  @override
  void setPauseHandler(VoidCallback handler) =>
      _flutterTts.setPauseHandler(handler);

  @override
  void setContinueHandler(VoidCallback handler) =>
      _flutterTts.setContinueHandler(handler);

  @override
  void setCancelHandler(VoidCallback handler) =>
      _flutterTts.setCancelHandler(handler);

  @override
  void setProgressHandler(TTSProgressHandler handler) =>
      _flutterTts.setProgressHandler(handler);

  @override
  void setErrorHandler(void Function(String message) handler) =>
      _flutterTts.setErrorHandler((message) => handler(message.toString()));

  @override
  Future<void> initialize() async {
    await _flutterTts.awaitSpeakCompletion(true);
  }

  @override
  Future<List<Map<String, Object?>>> loadVoices() async {
    final raw = await _flutterTts.getVoices;
    if (raw is! List) return const [];
    return raw.whereType<Map<Object?, Object?>>().map((voice) {
      return voice.map((key, value) => MapEntry(key.toString(), value));
    }).toList(growable: false);
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    await _flutterTts.setSpeechRate(rate);
  }

  @override
  Future<void> setPitch(double pitch) async {
    await _flutterTts.setPitch(pitch);
  }

  @override
  Future<void> setVolume(double volume) async {
    await _flutterTts.setVolume(volume);
  }

  @override
  Future<void> setVoice(String name, String locale) async {
    await _flutterTts.setVoice({'name': name, 'locale': locale});
  }

  @override
  Future<void> speak(String text, {required bool requestAudioFocus}) async {
    await _flutterTts.speak(text, focus: requestAudioFocus);
  }

  @override
  Future<void> pause() async {
    await _flutterTts.pause();
  }

  @override
  Future<void> stop() async {
    await _flutterTts.stop();
  }
}

class _TTSQueueItem {
  _TTSQueueItem({
    required this.id,
    required this.text,
    required this.characterId,
    required this.ownerId,
    required this.sourceId,
  });

  final String id;
  final String text;
  final String? characterId;
  final String? ownerId;
  final String? sourceId;
  final Completer<void> completed = Completer<void>();
}

/// TTS Service for text-to-speech functionality
class TTSService with WidgetsBindingObserver {
  bool _isInitialized = false;
  bool _isSpeaking = false;
  bool _isDisposed = false;
  bool _lifecycleObserverRegistered = false;
  final List<_TTSQueueItem> _queue = [];
  TTSSettings _settings = const TTSSettings();
  final Map<String, CharacterVoiceSettings> _characterVoices = {};
  final StreamController<TTSPlaybackState> _playbackStates =
      StreamController<TTSPlaybackState>.broadcast(sync: true);
  final SystemTTSBackend _systemTts;

  /// Player for remote-synthesized audio
  final AudioPlayer _audioPlayer;
  final Dio _dio;
  TTSPlaybackState _playbackState = const TTSPlaybackState();
  _TTSQueueItem? _currentItem;
  Future<void>? _queueRunner;
  StreamSubscription<Duration>? _remotePositionSubscription;
  StreamSubscription<PlayerState>? _remotePlayerStateSubscription;
  Timer? _mouthCloseTimer;
  Completer<void>? _resumeSignal;
  Completer<void>? _systemTerminalSignal;
  Completer<void>? _remoteTerminalSignal;
  Future<void> _stopBarrier = Future<void>.value();
  bool _intentionalSystemStop = false;
  int _playbackGeneration = 0;
  int _nextSessionId = 0;
  int _systemSegmentOffset = 0;
  TTSAmplitudeEnvelope? _remoteEnvelope;
  CancelToken? _remoteRequestCancelToken;

  TTSService({
    Dio? dio,
    SystemTTSBackend? systemTts,
    AudioPlayer? audioPlayer,
    ExternalCallAuditRepository auditRepository =
        const NoopExternalCallAuditRepository(),
    AiDataSharingConsentRepository consentRepository =
        const AllowAllAiDataSharingConsentRepository(),
  })  : _dio = dio ?? Dio(),
        _systemTts = systemTts ?? FlutterSystemTTSBackend(),
        _audioPlayer = audioPlayer ?? AudioPlayer() {
    _dio.interceptors.add(
      ExternalCallAuditInterceptor(
        repository: auditRepository,
        capabilityId: 'tts',
        classifyData: (request) => const {
          ExternalDataType.chatText,
          ExternalDataType.audio,
        },
        consentRepository: consentRepository,
      ),
    );
    _systemTts.setStartHandler(_handleSystemStart);
    _systemTts.setCompletionHandler(_handleSystemCompletion);
    _systemTts.setPauseHandler(_handleSystemPause);
    _systemTts.setContinueHandler(_handleSystemContinue);
    _systemTts.setCancelHandler(_handleSystemCancel);
    _systemTts.setProgressHandler(_handleSystemProgress);
    _systemTts.setErrorHandler(_handleSystemError);
  }

  /// Available voices (populated after initialization)
  List<TTSVoice> _availableVoices = [];

  /// Callbacks
  VoidCallback? onStart;
  VoidCallback? onComplete;
  VoidCallback? onCancel;
  void Function(String)? onError;

  bool get isInitialized => _isInitialized;
  bool get isSpeaking => _isSpeaking;
  List<TTSVoice> get availableVoices => _availableVoices;
  TTSSettings get settings => _settings;
  TTSPlaybackState get playbackState => _playbackState;
  Stream<TTSPlaybackState> get playbackStates => _playbackStates.stream;

  /// Initialize the TTS service
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await _systemTts.initialize();
      _availableVoices = await _loadSystemVoices();
      if (_availableVoices.isEmpty) {
        _availableVoices = _getDefaultVoices();
      }
      _isInitialized = true;
      if (!_lifecycleObserverRegistered) {
        WidgetsBinding.instance.addObserver(this);
        _lifecycleObserverRegistered = true;
      }
    } catch (e) {
      // Keep the service usable for remote providers even if the
      // system engine fails to initialize
      _availableVoices = _getDefaultVoices();
      _isInitialized = true;
      onError?.call('Failed to initialize system TTS: $e');
    }
    if (!_lifecycleObserverRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleObserverRegistered = true;
    }
  }

  /// Query real system voices from the platform TTS engine
  Future<List<TTSVoice>> _loadSystemVoices() async {
    final voices = <TTSVoice>[];
    final raw = await _systemTts.loadVoices();
    for (final item in raw) {
      final name = item['name']?.toString();
      final locale = item['locale']?.toString();
      if (name == null || name.isEmpty) continue;
      voices.add(
        TTSVoice(
          id: name,
          name: locale != null ? '$name ($locale)' : name,
          language: locale,
          provider: TTSProvider.system,
        ),
      );
    }
    voices.sort((a, b) => (a.language ?? '').compareTo(b.language ?? ''));
    return voices;
  }

  /// Get default system voices (placeholder)
  List<TTSVoice> _getDefaultVoices() {
    return [
      const TTSVoice(
        id: 'default',
        name: 'Default',
        language: 'en-US',
        gender: 'neutral',
        provider: TTSProvider.system,
      ),
      const TTSVoice(
        id: 'en-us-female',
        name: 'English (US) Female',
        language: 'en-US',
        gender: 'female',
        provider: TTSProvider.system,
      ),
      const TTSVoice(
        id: 'en-us-male',
        name: 'English (US) Male',
        language: 'en-US',
        gender: 'male',
        provider: TTSProvider.system,
      ),
      const TTSVoice(
        id: 'en-gb-female',
        name: 'English (UK) Female',
        language: 'en-GB',
        gender: 'female',
        provider: TTSProvider.system,
      ),
      const TTSVoice(
        id: 'en-gb-male',
        name: 'English (UK) Male',
        language: 'en-GB',
        gender: 'male',
        provider: TTSProvider.system,
      ),
    ];
  }

  /// Update settings
  void updateSettings(TTSSettings settings) {
    final mustStop = _playbackState.isActive &&
        (!settings.enabled || settings.provider != _settings.provider);
    _settings = settings;
    if (mustStop) unawaited(stop());
  }

  /// Set character voice settings
  void setCharacterVoice(CharacterVoiceSettings voiceSettings) {
    _characterVoices[voiceSettings.characterId] = voiceSettings;
  }

  /// Get character voice settings
  CharacterVoiceSettings? getCharacterVoice(String characterId) {
    return _characterVoices[characterId];
  }

  /// Speaks [text] and completes when that specific queued item terminates.
  Future<void> speak(
    String text, {
    String? characterId,
    String? ownerId,
    String? sourceId,
  }) async {
    if (_isDisposed || !_isInitialized || !_settings.enabled) return;
    final cleanText = _cleanTextForTTS(text);
    if (cleanText.isEmpty) return;

    if (!_settings.queueMessages) await stop();

    final item = _TTSQueueItem(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_nextSessionId++}',
      text: cleanText,
      characterId: characterId,
      ownerId: ownerId,
      sourceId: sourceId,
    );
    _queue.add(item);
    if (_currentItem == null) {
      _emitState(
        TTSPlaybackState(
          sessionId: item.id,
          ownerId: item.ownerId,
          sourceId: item.sourceId,
          characterId: item.characterId,
          text: item.text,
          phase: TTSPlaybackPhase.queued,
          queueDepth: _queue.length,
        ),
      );
    } else {
      _emitState(_playbackState.copyWith(queueDepth: _queue.length));
    }
    _ensureQueueRunner();
    await item.completed.future;
  }

  void _ensureQueueRunner() {
    if (_queueRunner != null || _isDisposed) return;
    late final Future<void> runner;
    runner = _processQueue().whenComplete(() {
      if (identical(_queueRunner, runner)) _queueRunner = null;
      if (_queue.isNotEmpty) _ensureQueueRunner();
    });
    _queueRunner = runner;
  }

  Future<void> _processQueue() async {
    while (_queue.isNotEmpty && !_isDisposed) {
      final item = _queue.removeAt(0);
      await _speakItem(item);
      await _stopBarrier;
    }
  }

  Future<void> _speakItem(_TTSQueueItem item) async {
    final generation = _playbackGeneration;
    _currentItem = item;
    _isSpeaking = true;
    _systemSegmentOffset = 0;
    _emitState(
      TTSPlaybackState(
        sessionId: item.id,
        ownerId: item.ownerId,
        sourceId: item.sourceId,
        characterId: item.characterId,
        text: item.text,
        phase: TTSPlaybackPhase.queued,
        mouthOpen: 0,
        queueDepth: _queue.length,
      ),
    );

    try {
      final charVoice =
          item.characterId != null ? _characterVoices[item.characterId] : null;
      final voiceId = charVoice?.voiceId ?? _settings.voiceId;
      final rate = charVoice?.rate ?? _settings.rate;
      final pitch = charVoice?.pitch ?? _settings.pitch;
      final volume = charVoice?.volume ?? _settings.volume;

      if (_settings.provider == TTSProvider.system) {
        await _speakWithSystemTts(
          item,
          voiceId: voiceId,
          rate: rate,
          pitch: pitch,
          volume: volume,
        );
      } else {
        await _speakWithRemoteTts(item, volume: volume);
      }

      if (_isCurrent(item, generation) &&
          _playbackState.phase != TTSPlaybackPhase.failed) {
        _emitState(
          _playbackState.copyWith(
            phase: TTSPlaybackPhase.completed,
            spokenText: item.text,
            progress: 1,
            mouthOpen: 0,
            queueDepth: _queue.length,
            clearError: true,
          ),
        );
        onComplete?.call();
      }
    } catch (error) {
      if (_isCurrent(item, generation)) {
        final message = 'TTS error: $error';
        _emitState(
          _playbackState.copyWith(
            phase: TTSPlaybackPhase.failed,
            mouthOpen: 0,
            queueDepth: _queue.length,
            error: message,
          ),
        );
        onError?.call(message);
      }
    } finally {
      _mouthCloseTimer?.cancel();
      await _remotePositionSubscription?.cancel();
      _remotePositionSubscription = null;
      await _remotePlayerStateSubscription?.cancel();
      _remotePlayerStateSubscription = null;
      _remoteTerminalSignal = null;
      _remoteEnvelope = null;
      if (_isCurrent(item, generation)) {
        _currentItem = null;
        _isSpeaking = false;
      }
      if (!item.completed.isCompleted) item.completed.complete();
    }
  }

  bool _isCurrent(_TTSQueueItem item, int generation) =>
      generation == _playbackGeneration && identical(item, _currentItem);

  /// Speak with the platform TTS engine (flutter_tts).
  Future<void> _speakWithSystemTts(
    _TTSQueueItem item, {
    String? voiceId,
    required double rate,
    required double pitch,
    required double volume,
  }) async {
    await _systemTts.setSpeechRate((rate * 0.5).clamp(0.0, 1.0));
    await _systemTts.setPitch(pitch.clamp(0.5, 2.0));
    await _systemTts.setVolume(volume.clamp(0.0, 1.0));

    if (voiceId != null && voiceId.isNotEmpty) {
      final voices = _availableVoices.where(
        (voice) => voice.id == voiceId && voice.provider == TTSProvider.system,
      );
      if (voices.isNotEmpty) {
        await _systemTts.setVoice(
          voices.first.id,
          voices.first.language ?? 'en-US',
        );
      }
    }

    var segment = item.text;
    while (segment.isNotEmpty && identical(item, _currentItem)) {
      final terminal = Completer<void>();
      _systemTerminalSignal = terminal;
      final speaking = _systemTts.speak(segment, requestAudioFocus: true);
      await Future.any([speaking, terminal.future]);
      if (identical(_systemTerminalSignal, terminal)) {
        _systemTerminalSignal = null;
      }
      if (!identical(item, _currentItem)) return;
      final resumeSignal = _resumeSignal;
      if (resumeSignal == null) return;
      await resumeSignal.future;
      if (identical(_resumeSignal, resumeSignal)) _resumeSignal = null;
      if (!identical(item, _currentItem)) return;
      segment = item.text.substring(
        _playbackState.spokenText.length.clamp(0, item.text.length),
      );
      _systemSegmentOffset = item.text.length - segment.length;
    }
  }

  /// Synthesize remotely and drive progress from the actual audio player.
  Future<void> _speakWithRemoteTts(
    _TTSQueueItem item, {
    required double volume,
  }) async {
    final bytes = await synthesize(item.text, characterId: item.characterId);
    if (bytes == null || bytes.isEmpty) {
      throw Exception('TTS provider returned no audio');
    }

    _remoteEnvelope = TTSAmplitudeEnvelope.tryParseWav(bytes);
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(dir.path, 'tts_${DateTime.now().microsecondsSinceEpoch}.audio'),
    );
    await file.writeAsBytes(bytes);

    try {
      await _audioPlayer.setVolume(volume.clamp(0.0, 1.0));
      final duration = await _audioPlayer.setFilePath(file.path);
      await _remotePositionSubscription?.cancel();
      _remotePositionSubscription = _audioPlayer.positionStream.listen(
        (position) => _handleRemoteProgress(item, position, duration),
      );
      final terminal = Completer<void>();
      _remoteTerminalSignal = terminal;
      await _remotePlayerStateSubscription?.cancel();
      _remotePlayerStateSubscription = _audioPlayer.playerStateStream.listen(
        (state) {
          if (state.playing &&
              identical(item, _currentItem) &&
              _playbackState.phase != TTSPlaybackPhase.playing) {
            _emitState(
              _playbackState.copyWith(
                phase: TTSPlaybackPhase.playing,
                mouthOpen: 0.12,
                clearError: true,
              ),
            );
            onStart?.call();
          }
          if (state.processingState == ProcessingState.completed) {
            _completeSignal(terminal);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!terminal.isCompleted) {
            terminal.completeError(error, stackTrace);
          }
        },
      );
      _startRemotePlayback(terminal);
      await terminal.future;
    } finally {
      await _remotePositionSubscription?.cancel();
      _remotePositionSubscription = null;
      await _remotePlayerStateSubscription?.cancel();
      _remotePlayerStateSubscription = null;
      _remoteTerminalSignal = null;
      try {
        await file.delete();
      } catch (_) {
        // Temporary audio cleanup is best-effort.
      }
    }
  }

  void _startRemotePlayback(Completer<void> terminal) {
    unawaited(() async {
      try {
        await _audioPlayer.play();
      } catch (error, stackTrace) {
        if (!terminal.isCompleted) {
          terminal.completeError(error, stackTrace);
        }
      }
    }());
  }

  void _handleRemoteProgress(
    _TTSQueueItem item,
    Duration position,
    Duration? duration,
  ) {
    if (!identical(item, _currentItem) ||
        _playbackState.phase != TTSPlaybackPhase.playing) {
      return;
    }
    final totalMicros = duration?.inMicroseconds ?? 0;
    if (totalMicros <= 0) return;
    final progress = (position.inMicroseconds / totalMicros).clamp(0.0, 1.0);
    final end = (item.text.length * progress).round().clamp(
          0,
          item.text.length,
        );
    final envelope = _remoteEnvelope;
    final mouthOpen = envelope?.sample(progress) ??
        TTSAmplitudeEnvelope.fromTextProgress(item.text, progress);
    _emitState(
      _playbackState.copyWith(
        spokenText: item.text.substring(0, end),
        progress: progress,
        mouthOpen: mouthOpen,
        queueDepth: _queue.length,
      ),
    );
  }

  /// Stop immediately and discard every queued message.
  Future<void> stop({String? ownerId}) async {
    if (ownerId == null) {
      _remoteRequestCancelToken?.cancel('TTS request cancelled');
    }
    final current = _currentItem;
    final cancelCurrent =
        current != null && (ownerId == null || current.ownerId == ownerId);
    final hasQueuedOwner =
        ownerId == null || _queue.any((item) => item.ownerId == ownerId);
    if (!cancelCurrent && !hasQueuedOwner) {
      return;
    }
    final removed = ownerId == null
        ? List<_TTSQueueItem>.from(_queue)
        : _queue.where((item) => item.ownerId == ownerId).toList();
    if (ownerId == null) {
      _queue.clear();
    } else {
      _queue.removeWhere((item) => item.ownerId == ownerId);
    }
    for (final item in removed) {
      if (!item.completed.isCompleted) item.completed.complete();
    }

    if (!cancelCurrent) {
      _emitState(_playbackState.copyWith(queueDepth: _queue.length));
      return;
    }

    _playbackGeneration++;
    _remoteRequestCancelToken?.cancel('TTS playback cancelled');
    _mouthCloseTimer?.cancel();
    await _remotePositionSubscription?.cancel();
    _remotePositionSubscription = null;
    await _remotePlayerStateSubscription?.cancel();
    _remotePlayerStateSubscription = null;
    _intentionalSystemStop = true;
    _stopBarrier = Future.wait<void>([
      _systemTts.stop(),
      _audioPlayer.stop(),
    ]).then<void>((_) {}).catchError((_) {
      // Stopping is best-effort.
    });
    _completeSignal(_resumeSignal);
    _resumeSignal = null;
    _completeSignal(_systemTerminalSignal);
    _systemTerminalSignal = null;
    _completeSignal(_remoteTerminalSignal);
    _remoteTerminalSignal = null;
    _currentItem = null;
    _isSpeaking = false;
    _emitState(
      _playbackState.copyWith(
        phase: TTSPlaybackPhase.cancelled,
        mouthOpen: 0,
        queueDepth: _queue.length,
        clearError: true,
      ),
    );
    if (!current.completed.isCompleted) current.completed.complete();
    onCancel?.call();

    await _stopBarrier;
    _intentionalSystemStop = false;
  }

  Future<void> pause() async {
    if (_currentItem == null ||
        _playbackState.phase != TTSPlaybackPhase.playing) {
      return;
    }
    _resumeSignal ??= Completer<void>();
    _emitState(
      _playbackState.copyWith(phase: TTSPlaybackPhase.paused, mouthOpen: 0),
    );
    try {
      if (_settings.provider == TTSProvider.system) {
        await _systemTts.pause();
        // Some engines pause successfully without invoking their pause
        // callback. Always release the current segment after the command.
        _completeSignal(_systemTerminalSignal);
      } else {
        await _audioPlayer.pause();
      }
    } catch (error) {
      _handleSystemError(error.toString());
    }
  }

  Future<void> resume() async {
    if (_currentItem == null ||
        _playbackState.phase != TTSPlaybackPhase.paused) {
      return;
    }
    _emitState(
      _playbackState.copyWith(
        phase: TTSPlaybackPhase.playing,
        mouthOpen: 0.12,
        clearError: true,
      ),
    );
    if (_settings.provider == TTSProvider.system) {
      final signal = _resumeSignal;
      if (signal != null && !signal.isCompleted) signal.complete();
    } else {
      final terminal = _remoteTerminalSignal;
      if (terminal != null) _startRemotePlayback(terminal);
    }
  }

  void _handleSystemStart() {
    final item = _currentItem;
    if (item == null || _settings.provider != TTSProvider.system) return;
    if (_playbackState.phase != TTSPlaybackPhase.playing) {
      _emitState(
        _playbackState.copyWith(
          phase: TTSPlaybackPhase.playing,
          mouthOpen: 0.12,
          clearError: true,
        ),
      );
      onStart?.call();
    }
  }

  void _handleSystemCompletion() {
    final item = _currentItem;
    if (item == null || _settings.provider != TTSProvider.system) return;
    _mouthCloseTimer?.cancel();
    _emitState(
      _playbackState.copyWith(spokenText: item.text, progress: 1, mouthOpen: 0),
    );
    _completeSignal(_systemTerminalSignal);
  }

  void _handleSystemPause() {
    if (_currentItem == null || _settings.provider != TTSProvider.system) {
      return;
    }
    if (_playbackState.phase != TTSPlaybackPhase.paused) {
      _emitState(
        _playbackState.copyWith(phase: TTSPlaybackPhase.paused, mouthOpen: 0),
      );
    }
    _completeSignal(_systemTerminalSignal);
  }

  void _handleSystemContinue() {
    if (_currentItem == null || _settings.provider != TTSProvider.system) {
      return;
    }
    if (_playbackState.phase == TTSPlaybackPhase.paused) {
      unawaited(resume());
    }
  }

  void _handleSystemCancel() {
    final item = _currentItem;
    if (item == null || _settings.provider != TTSProvider.system) return;
    if (_intentionalSystemStop) {
      _completeSignal(_systemTerminalSignal);
      return;
    }
    _playbackGeneration++;
    _currentItem = null;
    _isSpeaking = false;
    _mouthCloseTimer?.cancel();
    _completeSignal(_resumeSignal);
    _resumeSignal = null;
    _completeSignal(_systemTerminalSignal);
    _systemTerminalSignal = null;
    _completeSignal(_remoteTerminalSignal);
    _remoteTerminalSignal = null;
    _emitState(
      _playbackState.copyWith(
        phase: TTSPlaybackPhase.cancelled,
        mouthOpen: 0,
        queueDepth: _queue.length,
        clearError: true,
      ),
    );
    if (!item.completed.isCompleted) item.completed.complete();
    onCancel?.call();
  }

  void _handleSystemError(String error) {
    final item = _currentItem;
    if (item == null) return;
    final message = 'TTS error: $error';
    _playbackGeneration++;
    _currentItem = null;
    _isSpeaking = false;
    _mouthCloseTimer?.cancel();
    _completeSignal(_resumeSignal);
    _resumeSignal = null;
    _completeSignal(_systemTerminalSignal);
    _systemTerminalSignal = null;
    _completeSignal(_remoteTerminalSignal);
    _remoteTerminalSignal = null;
    _emitState(
      _playbackState.copyWith(
        phase: TTSPlaybackPhase.failed,
        mouthOpen: 0,
        queueDepth: _queue.length,
        error: message,
      ),
    );
    if (!item.completed.isCompleted) item.completed.complete();
    onError?.call(message);
  }

  void _handleSystemProgress(
    String text,
    int startOffset,
    int endOffset,
    String word,
  ) {
    final item = _currentItem;
    if (item == null ||
        _settings.provider != TTSProvider.system ||
        _playbackState.phase != TTSPlaybackPhase.playing) {
      return;
    }
    final start = (_systemSegmentOffset + startOffset).clamp(
      0,
      item.text.length,
    );
    final end = (_systemSegmentOffset + endOffset).clamp(
      start,
      item.text.length,
    );
    final progress = item.text.isEmpty ? 1.0 : end / item.text.length;
    _emitState(
      _playbackState.copyWith(
        spokenText: item.text.substring(0, end),
        progress: progress,
        mouthOpen: TTSAmplitudeEnvelope.fromSpokenWord(word),
        queueDepth: _queue.length,
      ),
    );
    _mouthCloseTimer?.cancel();
    _mouthCloseTimer = Timer(const Duration(milliseconds: 140), () {
      if (identical(item, _currentItem) &&
          _playbackState.phase == TTSPlaybackPhase.playing) {
        _emitState(_playbackState.copyWith(mouthOpen: 0.08));
      }
    });
  }

  void _emitState(TTSPlaybackState state) {
    if (_isDisposed) return;
    _playbackState = state.copyWith(sequence: _playbackState.sequence + 1);
    if (!_playbackStates.isClosed) _playbackStates.add(_playbackState);
  }

  void _completeSignal(Completer<void>? signal) {
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _playbackState.isActive) {
      unawaited(stop());
    }
  }

  /// Clean text for TTS
  String _cleanTextForTTS(String text) {
    var cleaned = text;

    // Remove markdown formatting
    cleaned = cleaned.replaceAll(RegExp(r'\*\*([^*]+)\*\*'), r'$1'); // Bold
    cleaned = cleaned.replaceAll(RegExp(r'\*([^*]+)\*'), r'$1'); // Italic
    cleaned = cleaned.replaceAll(RegExp(r'__([^_]+)__'), r'$1'); // Underline
    cleaned = cleaned.replaceAll(
      RegExp(r'~~([^~]+)~~'),
      r'$1',
    ); // Strikethrough
    cleaned = cleaned.replaceAll(RegExp(r'`([^`]+)`'), r'$1'); // Code
    cleaned = cleaned.replaceAll(RegExp(r'```[^`]*```'), ''); // Code blocks

    // Remove links but keep text
    cleaned = cleaned.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1');

    // Remove HTML tags
    cleaned = cleaned.replaceAll(RegExp(r'<[^>]+>'), '');

    // Remove action markers but keep content
    cleaned = cleaned.replaceAll(RegExp(r'\*([^*]+)\*'), r'$1');

    // Remove multiple spaces
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');

    // Remove leading/trailing whitespace
    cleaned = cleaned.trim();

    return cleaned;
  }

  // ==================== Remote synthesis ====================

  /// Synthesize [text] to audio bytes with the configured remote provider.
  /// Returns null for providers without a remote API (system TTS).
  /// Playback is handled by the caller once an audio player is available.
  Future<Uint8List?> synthesize(String text, {String? characterId}) async {
    final charVoice =
        characterId != null ? _characterVoices[characterId] : null;
    final voiceId = charVoice?.voiceId ?? _settings.voiceId;

    if (_settings.provider == TTSProvider.system) return null;
    _validateRemoteConfiguration();
    final cancelToken = CancelToken();
    _remoteRequestCancelToken?.cancel('Superseded by a new TTS request');
    _remoteRequestCancelToken = cancelToken;
    try {
      return await switch (_settings.provider) {
        TTSProvider.system => null,
        TTSProvider.elevenlabs =>
          _synthesizeElevenLabs(text, voiceId, cancelToken),
        TTSProvider.azure => _synthesizeAzure(text, voiceId, cancelToken),
        TTSProvider.volcengine =>
          _synthesizeVolcengine(text, voiceId, cancelToken),
        TTSProvider.gptSovits =>
          _synthesizeGptSovits(text, voiceId, cancelToken),
        TTSProvider.openaiCompatible =>
          _synthesizeOpenAICompatible(text, voiceId, cancelToken),
      };
    } catch (error) {
      throw normalizeVoiceAdapterError(error, operation: 'Speech synthesis');
    } finally {
      if (identical(_remoteRequestCancelToken, cancelToken)) {
        _remoteRequestCancelToken = null;
      }
    }
  }

  Future<Uint8List?> _synthesizeElevenLabs(
    String text,
    String? voiceId,
    CancelToken cancelToken,
  ) async {
    final endpoint = _remoteEndpoint('https://api.elevenlabs.io');
    final voice = voiceId ?? '21m00Tcm4TlvDq8ikWAM';
    final url = endpoint.endsWith('/v1')
        ? '$endpoint/text-to-speech/$voice'
        : '$endpoint/v1/text-to-speech/$voice';
    final response = await _dio.post<List<int>>(
      url,
      cancelToken: cancelToken,
      options: voiceRequestOptions(
        headers: {
          'xi-api-key': _settings.apiKey!.trim(),
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.bytes,
      ),
      data: {
        'text': text,
        'model_id':
            _settings.providerOptions['model'] ?? 'eleven_multilingual_v2',
      },
    );
    return response.data != null ? Uint8List.fromList(response.data!) : null;
  }

  Future<Uint8List?> _synthesizeAzure(
    String text,
    String? voiceId,
    CancelToken cancelToken,
  ) async {
    final region = _settings.providerOptions['region'] ?? 'eastus';
    final endpoint =
        _remoteEndpoint('https://$region.tts.speech.microsoft.com');
    final voice = voiceId ?? 'en-US-JennyNeural';
    final ssml = '<speak version="1.0" xml:lang="en-US"><voice name="$voice">'
        '${_escapeXml(text)}</voice></speak>';
    final response = await _dio.post<List<int>>(
      '$endpoint/cognitiveservices/v1',
      cancelToken: cancelToken,
      options: voiceRequestOptions(
        headers: {
          'Ocp-Apim-Subscription-Key': _settings.apiKey!.trim(),
          'Content-Type': 'application/ssml+xml',
          'X-Microsoft-OutputFormat': 'audio-24khz-96kbitrate-mono-mp3',
        },
        responseType: ResponseType.bytes,
      ),
      data: ssml,
    );
    return response.data != null ? Uint8List.fromList(response.data!) : null;
  }

  /// Volcengine (火山引擎) TTS - openspeech binary API
  Future<Uint8List?> _synthesizeVolcengine(
    String text,
    String? voiceId,
    CancelToken cancelToken,
  ) async {
    final endpoint = _remoteEndpoint(
      'https://openspeech.bytedance.com/api/v1/tts',
    );
    final appId = _settings.providerOptions['appId'] ?? '';
    final cluster = _settings.providerOptions['cluster'] ?? 'volcano_tts';
    final response = await _dio.post<Map<String, dynamic>>(
      endpoint,
      cancelToken: cancelToken,
      options: voiceRequestOptions(
        headers: {
          'Authorization': 'Bearer;${_settings.apiKey!.trim()}',
          'Content-Type': 'application/json',
        },
      ),
      data: {
        'app': {'appid': appId, 'cluster': cluster},
        'user': {'uid': 'native_tavern'},
        'audio': {
          'voice_type': voiceId ?? 'BV001_streaming',
          'encoding': 'mp3',
          'speed_ratio': _settings.rate,
          'volume_ratio': _settings.volume,
          'pitch_ratio': _settings.pitch,
        },
        'request': {
          'reqid': DateTime.now().millisecondsSinceEpoch.toString(),
          'text': text,
          'operation': 'query',
        },
      },
    );
    // Response carries base64 audio in the `data` field
    final b64 = response.data?['data'] as String?;
    if (b64 == null || b64.isEmpty) return null;
    return Uint8List.fromList(const Base64Decoder().convert(b64));
  }

  /// GPT-SoVITS local inference server (api_v2 style)
  Future<Uint8List?> _synthesizeGptSovits(
    String text,
    String? voiceId,
    CancelToken cancelToken,
  ) async {
    final endpoint = _remoteEndpoint('http://127.0.0.1:9880');
    final options = _settings.providerOptions;
    final response = await _dio.post<List<int>>(
      endpoint.endsWith('/tts') ? endpoint : '$endpoint/tts',
      cancelToken: cancelToken,
      options: voiceRequestOptions(responseType: ResponseType.bytes),
      data: {
        'text': text,
        'text_lang': options['textLang'] ?? 'zh',
        'ref_audio_path': options['refAudioPath'] ?? '',
        'prompt_text': options['promptText'] ?? '',
        'prompt_lang': options['promptLang'] ?? 'zh',
        'media_type': 'wav',
        'speed_factor': _settings.rate,
      },
    );
    return response.data != null ? Uint8List.fromList(response.data!) : null;
  }

  /// OpenAI-compatible /v1/audio/speech endpoint
  Future<Uint8List?> _synthesizeOpenAICompatible(
    String text,
    String? voiceId,
    CancelToken cancelToken,
  ) async {
    final endpoint = _remoteEndpoint('https://api.openai.com/v1');
    final response = await _dio.post<List<int>>(
      endpoint.endsWith('/audio/speech') ? endpoint : '$endpoint/audio/speech',
      cancelToken: cancelToken,
      options: voiceRequestOptions(
        headers: {
          if (_settings.apiKey?.trim().isNotEmpty == true)
            'Authorization': 'Bearer ${_settings.apiKey!.trim()}',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.bytes,
      ),
      data: {
        'model': _settings.providerOptions['model'] ?? 'tts-1',
        'input': text,
        'voice': voiceId ?? 'alloy',
        'speed': _settings.rate,
      },
    );
    return response.data != null ? Uint8List.fromList(response.data!) : null;
  }

  void _validateRemoteConfiguration() {
    final apiKeyConfigured = _settings.apiKey?.trim().isNotEmpty == true;
    final configured = switch (_settings.provider) {
      TTSProvider.system => true,
      TTSProvider.elevenlabs => apiKeyConfigured &&
          _validHttpEndpoint(_remoteEndpoint('https://api.elevenlabs.io')),
      TTSProvider.azure => apiKeyConfigured &&
          _validHttpEndpoint(
            _remoteEndpoint(
              'https://${_settings.providerOptions['region'] ?? 'eastus'}.tts.speech.microsoft.com',
            ),
          ),
      TTSProvider.volcengine => apiKeyConfigured &&
          _settings.providerOptions['appId']?.trim().isNotEmpty == true &&
          _validHttpEndpoint(
            _remoteEndpoint(
              'https://openspeech.bytedance.com/api/v1/tts',
            ),
          ),
      TTSProvider.gptSovits =>
        _validHttpEndpoint(_remoteEndpoint('http://127.0.0.1:9880')),
      TTSProvider.openaiCompatible =>
        _validHttpEndpoint(_remoteEndpoint('https://api.openai.com/v1')) &&
            (apiKeyConfigured ||
                _settings.apiEndpoint?.trim().isNotEmpty == true),
    };
    if (!configured) {
      throw const VoiceAdapterException(
        VoiceAdapterErrorKind.configuration,
        'Complete the selected text-to-speech provider configuration',
      );
    }
  }

  bool _validHttpEndpoint(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  String _remoteEndpoint(String fallback) {
    final configured = _settings.apiEndpoint?.trim();
    final endpoint = configured?.isNotEmpty == true ? configured! : fallback;
    return endpoint.replaceAll(RegExp(r'/+$'), '');
  }

  String _escapeXml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// Preview voice with sample text
  Future<void> previewVoice(String voiceId, {String? sampleText}) async {
    final text =
        sampleText ?? 'Hello! This is a preview of the selected voice.';
    final originalVoice = _settings.voiceId;

    try {
      _settings = _settings.copyWith(voiceId: voiceId);
      await speak(text);
    } finally {
      _settings = _settings.copyWith(voiceId: originalVoice);
    }
  }

  /// Dispose the service
  void dispose() {
    if (_isDisposed) return;
    if (_lifecycleObserverRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _lifecycleObserverRegistered = false;
    }
    _isDisposed = true;
    _playbackGeneration++;
    _remoteRequestCancelToken?.cancel('TTS service disposed');
    _mouthCloseTimer?.cancel();
    _completeSignal(_resumeSignal);
    _completeSignal(_systemTerminalSignal);
    final current = _currentItem;
    _currentItem = null;
    if (current != null && !current.completed.isCompleted) {
      current.completed.complete();
    }
    for (final item in _queue) {
      if (!item.completed.isCompleted) item.completed.complete();
    }
    _queue.clear();
    unawaited(_remotePositionSubscription?.cancel());
    unawaited(_remotePlayerStateSubscription?.cancel());
    _completeSignal(_remoteTerminalSignal);
    unawaited(_systemTts.stop());
    unawaited(_audioPlayer.stop());
    unawaited(_audioPlayer.dispose());
    unawaited(_playbackStates.close());
    _isInitialized = false;
  }
}

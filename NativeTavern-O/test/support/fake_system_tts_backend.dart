import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:native_tavern/domain/services/tts_service.dart';

class FakeSystemTTSBackend implements SystemTTSBackend {
  VoidCallback? _onStart;
  VoidCallback? _onComplete;
  VoidCallback? _onPause;
  VoidCallback? _onContinue;
  VoidCallback? _onCancel;
  TTSProgressHandler? _onProgress;
  void Function(String message)? _onError;
  Completer<void>? _activeSpeech;

  final List<String> spokenTexts = [];
  final List<bool> audioFocusRequests = [];
  final List<Completer<void>> _speakWaiters = [];
  double? lastRate;
  double? lastPitch;
  double? lastVolume;
  (String, String)? lastVoice;
  int pauseCount = 0;
  int stopCount = 0;
  bool invokePauseHandler = true;
  Completer<void>? stopGate;

  void holdStop() => stopGate = Completer<void>();

  void releaseStop() {
    final gate = stopGate;
    stopGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> waitForSpeakCount(int count) async {
    if (spokenTexts.length >= count) return;
    final waiter = Completer<void>();
    _speakWaiters.add(waiter);
    await waiter.future.timeout(const Duration(seconds: 2));
    if (spokenTexts.length < count) return waitForSpeakCount(count);
  }

  void progress(int start, int end, String word) {
    _onProgress?.call(spokenTexts.last, start, end, word);
  }

  void completeCurrent() {
    _onComplete?.call();
    _finishActiveSpeech();
  }

  void cancelCurrent() {
    _onCancel?.call();
    _finishActiveSpeech();
  }

  void failCurrent(String message) {
    _onError?.call(message);
    _finishActiveSpeech();
  }

  void continueCurrent() => _onContinue?.call();

  void _finishActiveSpeech() {
    final speech = _activeSpeech;
    _activeSpeech = null;
    if (speech != null && !speech.isCompleted) speech.complete();
  }

  void _notifySpeakWaiters() {
    for (final waiter in _speakWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _speakWaiters.clear();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Map<String, Object?>>> loadVoices() async => const [
        {'name': 'voice-a', 'locale': 'en-US'},
        {'name': 'voice-b', 'locale': 'en-GB'},
      ];

  @override
  void setStartHandler(VoidCallback handler) => _onStart = handler;

  @override
  void setCompletionHandler(VoidCallback handler) => _onComplete = handler;

  @override
  void setPauseHandler(VoidCallback handler) => _onPause = handler;

  @override
  void setContinueHandler(VoidCallback handler) => _onContinue = handler;

  @override
  void setCancelHandler(VoidCallback handler) => _onCancel = handler;

  @override
  void setProgressHandler(TTSProgressHandler handler) => _onProgress = handler;

  @override
  void setErrorHandler(void Function(String message) handler) =>
      _onError = handler;

  @override
  Future<void> setSpeechRate(double rate) async => lastRate = rate;

  @override
  Future<void> setPitch(double pitch) async => lastPitch = pitch;

  @override
  Future<void> setVolume(double volume) async => lastVolume = volume;

  @override
  Future<void> setVoice(String name, String locale) async =>
      lastVoice = (name, locale);

  @override
  Future<void> speak(
    String text, {
    required bool requestAudioFocus,
  }) async {
    spokenTexts.add(text);
    audioFocusRequests.add(requestAudioFocus);
    _activeSpeech = Completer<void>();
    _onStart?.call();
    _notifySpeakWaiters();
    await _activeSpeech!.future;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    if (invokePauseHandler) _onPause?.call();
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _finishActiveSpeech();
    _onCancel?.call();
    await stopGate?.future;
  }
}

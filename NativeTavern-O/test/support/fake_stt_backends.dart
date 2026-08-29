import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:native_tavern/domain/services/stt_service.dart';

class FakeSTTPermissionGateway implements STTPermissionGateway {
  FakeSTTPermissionGateway({
    this.current = STTPermissionState.granted,
    List<STTPermissionState>? requests,
  }) : requests = requests ?? [];

  STTPermissionState current;
  final List<STTPermissionState> requests;
  int requestCount = 0;
  int openSettingsCount = 0;

  @override
  Future<STTPermissionState> check() async => current;

  @override
  Future<STTPermissionState> request() async {
    requestCount++;
    if (requests.isNotEmpty) current = requests.removeAt(0);
    return current;
  }

  @override
  Future<bool> openSettings() async {
    openSettingsCount++;
    return true;
  }
}

class FakeSystemSTTBackend implements SystemSTTBackend {
  bool initializeResult = true;
  bool available = true;
  int initializeCount = 0;
  int listenCount = 0;
  int stopCount = 0;
  int cancelCount = 0;
  ValueChanged<String>? _onError;
  ValueChanged<String>? _onStatus;
  final List<ValueChanged<STTResult>> _resultHandlers = [];

  @override
  bool get isAvailable => available;

  @override
  Future<bool> initialize({
    required ValueChanged<String> onError,
    required ValueChanged<String> onStatus,
  }) async {
    initializeCount++;
    _onError = onError;
    _onStatus = onStatus;
    return initializeResult;
  }

  @override
  Future<void> listen({
    required ValueChanged<STTResult> onResult,
    required String localeId,
    required bool partialResults,
    required bool continuous,
  }) async {
    listenCount++;
    _resultHandlers.add(onResult);
    _onStatus?.call('listening');
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    _onStatus?.call('notListening');
  }

  void result(
    String text, {
    bool isFinal = false,
    int? sessionIndex,
  }) {
    final index = sessionIndex ?? _resultHandlers.length - 1;
    _resultHandlers[index](STTResult(text: text, isFinal: isFinal));
  }

  void error(String message) => _onError?.call(message);
  void status(String status) => _onStatus?.call(status);
}

class FakeSTTAudioRecorder implements STTAudioRecorder {
  int startCount = 0;
  int stopCount = 0;
  int cancelCount = 0;
  int disposeCount = 0;
  String? outputPath = '/virtual/voice.wav';

  @override
  Future<void> start() async => startCount++;

  @override
  Future<String?> stop() async {
    stopCount++;
    return outputPath;
  }

  @override
  Future<void> cancel() async => cancelCount++;

  @override
  Future<void> dispose() async => disposeCount++;
}

class FakeRemoteSTTBackend implements RemoteSTTBackend {
  int transcribeCount = 0;
  STTSettings? lastSettings;
  String? lastPath;
  Future<STTResult> Function(CancelToken token)? handler;

  @override
  Future<STTResult> transcribe({
    required String audioPath,
    required STTSettings settings,
    required CancelToken cancelToken,
  }) {
    transcribeCount++;
    lastSettings = settings;
    lastPath = audioPath;
    return handler?.call(cancelToken) ??
        Future.value(const STTResult(text: 'remote transcript', isFinal: true));
  }
}

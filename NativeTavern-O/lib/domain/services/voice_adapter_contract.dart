import 'dart:async';

import 'package:dio/dio.dart';

const defaultVoiceRequestTimeout = Duration(seconds: 30);

enum VoiceAdapterErrorKind {
  configuration,
  cancelled,
  timeout,
  unavailable,
  service,
}

class VoiceAdapterException implements Exception {
  const VoiceAdapterException(this.kind, this.message, {this.cause});

  final VoiceAdapterErrorKind kind;
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

Options voiceRequestOptions({
  Map<String, Object?>? headers,
  ResponseType? responseType,
  Duration timeout = defaultVoiceRequestTimeout,
  String? contentType,
}) {
  return Options(
    headers: headers,
    responseType: responseType,
    contentType: contentType,
    sendTimeout: timeout,
    receiveTimeout: timeout,
  );
}

VoiceAdapterException normalizeVoiceAdapterError(
  Object error, {
  String operation = 'Voice request',
}) {
  if (error is VoiceAdapterException) return error;
  if (error is DioException) {
    if (CancelToken.isCancel(error) || error.type == DioExceptionType.cancel) {
      return VoiceAdapterException(
        VoiceAdapterErrorKind.cancelled,
        '$operation cancelled',
        cause: error,
      );
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return VoiceAdapterException(
        VoiceAdapterErrorKind.timeout,
        '$operation timed out',
        cause: error,
      );
    }
    return VoiceAdapterException(
      VoiceAdapterErrorKind.service,
      '$operation failed: ${error.message ?? error.type.name}',
      cause: error,
    );
  }
  if (error is TimeoutException) {
    return VoiceAdapterException(
      VoiceAdapterErrorKind.timeout,
      '$operation timed out',
      cause: error,
    );
  }
  return VoiceAdapterException(
    VoiceAdapterErrorKind.service,
    '$operation failed: $error',
    cause: error,
  );
}

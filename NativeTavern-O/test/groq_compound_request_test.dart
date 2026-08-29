import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/llm_service.dart';

void main() {
  const assistantPrefill = [
    {'role': 'user', 'content': 'Tell me a story.'},
    {'role': 'assistant', 'content': 'Once upon a time'},
  ];

  test('Groq Compound non-streaming requests end with a user message',
      () async {
    final adapter = _RecordingLlmAdapter();
    final service = LLMService(dio: Dio()..httpClientAdapter = adapter);

    await service.generateWithReasoning(
      assistantPrefill,
      _config(model: 'groq/compound'),
    );

    expect(_messages(adapter.lastOptions).last, {
      'role': 'user',
      'content': 'Continue.',
    });
    expect(_messages(adapter.lastOptions)[1], assistantPrefill[1]);
  });

  test('Groq Compound streaming requests end with a user message', () async {
    final adapter = _RecordingLlmAdapter(streaming: true);
    final service = LLMService(dio: Dio()..httpClientAdapter = adapter);

    await service
        .generateStreamWithReasoning(
          assistantPrefill,
          _config(model: 'compound-beta'),
        )
        .toList();

    expect(_messages(adapter.lastOptions).last['role'], 'user');
  });

  test('other OAI Compatible endpoints preserve assistant prefill', () async {
    final adapter = _RecordingLlmAdapter();
    final service = LLMService(dio: Dio()..httpClientAdapter = adapter);

    await service.generateWithReasoning(
      assistantPrefill,
      _config(
        model: 'compatible-model',
        apiUrl: 'https://llm.example.com/v1',
      ),
    );

    expect(_messages(adapter.lastOptions), assistantPrefill);
  });
}

LLMConfig _config({required String model, String? apiUrl}) {
  return LLMConfig(
    provider: LLMProvider.openAICompatible,
    model: model,
    apiKey: 'test-key',
    apiUrl: apiUrl ?? 'https://api.groq.com/openai/v1',
  );
}

List<dynamic> _messages(RequestOptions? options) {
  final data = options?.data as Map<String, dynamic>;
  return data['messages'] as List<dynamic>;
}

class _RecordingLlmAdapter implements HttpClientAdapter {
  _RecordingLlmAdapter({this.streaming = false});

  final bool streaming;
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    if (streaming) {
      return ResponseBody.fromString(
        'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":null}]}\n\n'
        'data: [DONE]\n\n',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

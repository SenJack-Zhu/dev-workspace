import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/llm_service.dart';

void main() {
  test('Gemini streaming emits each JSON array object exactly once', () async {
    final first = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': 'Hello, {friend} '},
            ],
          },
        },
      ],
    });
    final second = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': 'world'},
            ],
          },
        },
      ],
    });
    final adapter = _FragmentedGeminiAdapter([
      '[\n$first',
      ',\n${second.substring(0, second.length ~/ 2)}',
      '${second.substring(second.length ~/ 2)}\n]',
    ]);
    final service = LLMService(dio: Dio()..httpClientAdapter = adapter);

    final chunks = await service.generateStreamWithReasoning(
      const [
        {'role': 'user', 'content': 'Hi'},
      ],
      _geminiConfig,
    ).toList();

    expect(chunks.map((chunk) => chunk.content).whereType<String>().join(),
        'Hello, {friend} world');
    expect(chunks.where((chunk) => chunk.isReasoningChunk), isEmpty);
  });

  test('Gemini thought parts are emitted only as reasoning', () async {
    final thought = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'thought': true, 'text': 'Consider options.'},
            ],
          },
        },
      ],
    });
    final answer = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': 'Done.'},
            ],
          },
        },
      ],
    });
    final adapter = _FragmentedGeminiAdapter(['[$thought', ',$answer]']);
    final service = LLMService(dio: Dio()..httpClientAdapter = adapter);

    final chunks = await service.generateStreamWithReasoning(
      const [
        {'role': 'user', 'content': 'Choose'},
      ],
      _geminiConfig,
    ).toList();

    expect(chunks.map((chunk) => chunk.reasoning).whereType<String>().join(),
        'Consider options.');
    expect(chunks.map((chunk) => chunk.content).whereType<String>().join(),
        'Done.');
  });
}

const _geminiConfig = LLMConfig(
  provider: LLMProvider.gemini,
  model: 'gemini-test',
  apiKey: 'test-key',
  apiUrl: 'https://generativelanguage.googleapis.com/v1beta',
);

class _FragmentedGeminiAdapter implements HttpClientAdapter {
  _FragmentedGeminiAdapter(this.fragments);

  final List<String> fragments;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream.fromIterable(
        fragments.map((fragment) => Uint8List.fromList(utf8.encode(fragment))),
      ),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

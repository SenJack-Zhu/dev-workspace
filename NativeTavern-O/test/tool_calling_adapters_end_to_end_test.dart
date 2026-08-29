import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/tool_calling/claude_tool_calling_adapter.dart';
import 'package:native_tavern/domain/services/tool_calling/gemini_tool_calling_adapter.dart';
import 'package:native_tavern/domain/services/tool_calling/openai_tool_calling_adapter.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_calling_adapter.dart';

void main() {
  test('all providers round-trip one request through calls and results', () {
    final configuration = ToolCallingConfiguration.enabled(
      tools: [
        ToolDefinition(
          name: 'weather',
          description: 'Read weather for a city.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'city': {'type': 'string'},
            },
            'required': ['city'],
          },
        ),
        ToolDefinition(
          name: 'time',
          description: 'Read time in a time zone.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'zone': {'type': 'string'},
            },
            'required': ['zone'],
          },
        ),
      ],
      choice: ToolChoice.required,
    );
    const cases = [
      (
        adapter: OpenAiToolCallingAdapter() as ToolCallingAdapter,
        fixture: 'test/fixtures/tool_calling/openai_stream.json',
      ),
      (
        adapter: ClaudeToolCallingAdapter() as ToolCallingAdapter,
        fixture: 'test/fixtures/tool_calling/claude_stream.json',
      ),
      (
        adapter: GeminiToolCallingAdapter() as ToolCallingAdapter,
        fixture: 'test/fixtures/tool_calling/gemini_stream.json',
      ),
    ];

    for (final testCase in cases) {
      final request = testCase.adapter.decorateRequest(
        {
          'model': 'fixture-model',
          'messages': const [
            {'role': 'user', 'content': 'Weather and time in Singapore?'},
          ],
        },
        configuration,
      );
      final parser = testCase.adapter.createStreamParser();
      final calls = <ToolCall>[];
      for (final chunk in _fixture(testCase.fixture)) {
        calls.addAll(parser.addChunk(chunk).completedCalls);
      }
      calls.addAll(parser.finish().completedCalls);

      expect(request, contains('tools'));
      expect(calls.map((call) => call.name), ['weather', 'time']);
      expect(
          calls.every((call) => call.status == ToolCallStatus.ready), isTrue);
      expect(calls[0].arguments, {'city': 'Singapore'});
      expect(calls[1].arguments, {'zone': 'Asia/Singapore'});

      for (final call in calls) {
        final encoded = testCase.adapter.encodeResult(ToolResultMessage(
          callId: call.id,
          toolName: call.name,
          output: {'ok': true, 'tool': call.name},
        ));
        final wireJson = jsonEncode(encoded);
        expect(wireJson, contains(call.id));
        expect(wireJson, contains(call.name));
      }
    }
  });

  test('cancelling a partial stream produces cancelled calls only', () {
    const adapter = OpenAiToolCallingAdapter();
    final parser = adapter.createStreamParser();
    final firstChunk = _fixture(
      'test/fixtures/tool_calling/openai_stream.json',
    ).first;

    expect(parser.addChunk(firstChunk).completedCalls, isEmpty);
    final cancelled = parser.finish(
      cancelled: true,
      reason: 'user stopped generation',
    );

    expect(cancelled.finishReason, 'cancelled');
    expect(cancelled.completedCalls, hasLength(2));
    expect(
      cancelled.completedCalls.every(
        (call) => call.status == ToolCallStatus.cancelled,
      ),
      isTrue,
    );
  });
}

List<Map<String, dynamic>> _fixture(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync()) as List<dynamic>;
  return decoded.cast<Map<String, dynamic>>();
}

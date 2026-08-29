import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/tool_calling/claude_tool_calling_adapter.dart';
import 'package:native_tavern/domain/services/tool_calling/gemini_tool_calling_adapter.dart';
import 'package:native_tavern/domain/services/tool_calling/openai_tool_calling_adapter.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_calling_adapter.dart';

void main() {
  final tools = _tools();
  final enabled = ToolCallingConfiguration.enabled(
    tools: tools,
    choice: ToolChoice.named('weather'),
  );

  group('request mapping', () {
    test('disabled tools preserve the exact ordinary request object', () {
      final baseline = <String, dynamic>{
        'model': 'baseline-model',
        'messages': const [
          {'role': 'user', 'content': 'Hello'},
        ],
      };
      const adapters = <ToolCallingAdapter>[
        OpenAiToolCallingAdapter(),
        ClaudeToolCallingAdapter(),
        GeminiToolCallingAdapter(),
      ];

      for (final adapter in adapters) {
        final result = adapter.decorateRequest(
          baseline,
          const ToolCallingConfiguration.disabled(),
        );
        expect(identical(result, baseline), isTrue);
        expect(result, baseline);
      }
    });

    test('maps definitions and named choices to native request fields', () {
      final openAi = const OpenAiToolCallingAdapter().decorateRequest(
        {'model': 'gpt'},
        enabled,
      );
      final claude = const ClaudeToolCallingAdapter().decorateRequest(
        {'model': 'claude'},
        enabled,
      );
      final gemini = const GeminiToolCallingAdapter().decorateRequest(
        {'model': 'gemini'},
        enabled,
      );

      expect((openAi['tools'] as List), hasLength(2));
      expect(
        ((openAi['tool_choice'] as Map)['function'] as Map)['name'],
        'weather',
      );
      expect((claude['tools'] as List).first, contains('input_schema'));
      expect((claude['tool_choice'] as Map)['type'], 'tool');
      final geminiConfig = (gemini['toolConfig']
          as Map)['functionCallingConfig'] as Map<String, dynamic>;
      expect(geminiConfig['mode'], 'ANY');
      expect(geminiConfig['allowedFunctionNames'], ['weather']);
    });
  });

  group('OpenAI-compatible adapter', () {
    test('parses non-streaming calls and encodes associated results', () {
      const adapter = OpenAiToolCallingAdapter();
      final message = adapter.parseResponse({
        'choices': [
          {
            'message': {
              'content': null,
              'tool_calls': [
                {
                  'id': 'call_weather',
                  'type': 'function',
                  'function': {
                    'name': 'weather',
                    'arguments': '{"city":"Singapore"}',
                  },
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      });

      expect(message.toolCalls.single.arguments['city'], 'Singapore');
      expect(message.finishReason, 'tool_calls');
      expect(
        adapter.encodeResult(ToolResultMessage(
          callId: message.toolCalls.single.id,
          toolName: 'weather',
          output: const {'temperature': 30},
        )),
        {
          'role': 'tool',
          'tool_call_id': 'call_weather',
          'content': '{"temperature":30}',
        },
      );
    });

    test('fixture accumulates parallel fragments and flags malformed JSON', () {
      const adapter = OpenAiToolCallingAdapter();
      final calls = _parseFixture(
        adapter,
        'test/fixtures/tool_calling/openai_stream.json',
      );
      final malformed = _parseFixture(
        adapter,
        'test/fixtures/tool_calling/openai_malformed_stream.json',
      );

      expect(calls, hasLength(2));
      expect(calls[0].arguments, {'city': 'Singapore'});
      expect(calls[1].arguments, {'zone': 'Asia/Singapore'});
      expect(malformed.single.status, ToolCallStatus.invalidArguments);
    });

    test('a text-only finish closes its request-scoped parser', () {
      final parser = const OpenAiToolCallingAdapter().createStreamParser();
      final update = parser.addChunk({
        'choices': [
          {
            'delta': {'content': 'Done'},
            'finish_reason': 'stop',
          },
        ],
      });

      expect(update.textDelta, 'Done');
      expect(update.finishReason, 'stop');
      expect(
        () => parser.addChunk(const <String, dynamic>{
          'choices': <dynamic>[],
        }),
        throwsA(isA<ToolProtocolException>()),
      );
    });
  });

  group('Claude adapter', () {
    test('maps text, thinking, tool_use, and tool_result blocks', () {
      const adapter = ClaudeToolCallingAdapter();
      final message = adapter.parseResponse({
        'content': [
          {'type': 'thinking', 'thinking': 'Need weather.'},
          {
            'type': 'tool_use',
            'id': 'call_weather',
            'name': 'weather',
            'input': {'city': 'Singapore'},
          },
          {'type': 'text', 'text': 'Checking.'},
        ],
        'stop_reason': 'tool_use',
      });

      expect(message.reasoning, 'Need weather.');
      expect(message.text, 'Checking.');
      expect(message.toolCalls.single.arguments['city'], 'Singapore');
      final result = adapter.encodeResult(ToolResultMessage(
        callId: 'call_weather',
        toolName: 'weather',
        output: 'service unavailable',
        status: ToolResultStatus.failed,
      ));
      final block = (result['content'] as List).single as Map;
      expect(block['tool_use_id'], 'call_weather');
      expect(block['is_error'], isTrue);
    });

    test('fixture preserves interleaved thinking, text, and tool blocks', () {
      const adapter = ClaudeToolCallingAdapter();
      final parser = adapter.createStreamParser();
      final calls = <ToolCall>[];
      final text = StringBuffer();
      final reasoning = StringBuffer();
      for (final chunk in _fixture(
        'test/fixtures/tool_calling/claude_stream.json',
      )) {
        final update = parser.addChunk(chunk);
        calls.addAll(update.completedCalls);
        text.write(update.textDelta);
        reasoning.write(update.reasoningDelta);
      }

      expect(text.toString(), 'Checking now.');
      expect(reasoning.toString(), 'Need both tools. ');
      expect(calls.map((call) => call.name), ['weather', 'time']);
      expect(calls[0].arguments['city'], 'Singapore');
    });
  });

  group('Gemini adapter', () {
    test('maps functionCall and functionResponse parts', () {
      const adapter = GeminiToolCallingAdapter();
      final message = adapter.parseResponse({
        'candidates': [
          {
            'content': {
              'parts': [
                {'thought': true, 'text': 'Need weather.'},
                {
                  'functionCall': {
                    'id': 'call_weather',
                    'name': 'weather',
                    'args': {'city': 'Singapore'},
                  },
                },
              ],
            },
            'finishReason': 'STOP',
          },
        ],
      });

      expect(message.reasoning, 'Need weather.');
      expect(message.toolCalls.single.id, 'call_weather');
      final result = adapter.encodeResult(ToolResultMessage(
        callId: 'call_weather',
        toolName: 'weather',
        output: const {'temperature': 30},
      ));
      final part = (result['parts'] as List).single as Map;
      final response = part['functionResponse'] as Map;
      expect(response['id'], 'call_weather');
      expect(response['response'], {'temperature': 30});
    });

    test('fixture emits structured parallel calls without shared state', () {
      const adapter = GeminiToolCallingAdapter();
      final calls = _parseFixture(
        adapter,
        'test/fixtures/tool_calling/gemini_stream.json',
      );

      expect(calls.map((call) => call.id), ['call_weather', 'call_time']);
      expect(calls[1].arguments['zone'], 'Asia/Singapore');
    });
  });
}

List<ToolDefinition> _tools() {
  return [
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
  ];
}

List<ToolCall> _parseFixture(ToolCallingAdapter adapter, String path) {
  final parser = adapter.createStreamParser();
  final calls = <ToolCall>[];
  for (final chunk in _fixture(path)) {
    calls.addAll(parser.addChunk(chunk).completedCalls);
  }
  calls.addAll(parser.finish().completedCalls);
  return calls;
}

List<Map<String, dynamic>> _fixture(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync()) as List<dynamic>;
  return decoded.cast<Map<String, dynamic>>();
}

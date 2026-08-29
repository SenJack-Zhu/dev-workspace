import 'dart:convert';

import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_calling_adapter.dart';

final class OpenAiToolCallingAdapter implements ToolCallingAdapter {
  const OpenAiToolCallingAdapter();

  @override
  Map<String, dynamic> decorateRequest(
    Map<String, dynamic> baseRequest,
    ToolCallingConfiguration configuration,
  ) {
    if (!configuration.enabled) return baseRequest;

    return {
      ...baseRequest,
      'tools': [
        for (final tool in configuration.tools)
          {
            'type': 'function',
            'function': {
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.inputSchema,
            },
          },
      ],
      'tool_choice': switch (configuration.choice.mode) {
        ToolChoiceMode.auto => 'auto',
        ToolChoiceMode.none => 'none',
        ToolChoiceMode.required => 'required',
        ToolChoiceMode.named => {
            'type': 'function',
            'function': {'name': configuration.choice.toolName},
          },
      },
    };
  }

  @override
  ToolAssistantMessage parseResponse(Map<String, dynamic> response) {
    final choices = toolObjectList(response['choices']);
    if (choices.isEmpty) return ToolAssistantMessage();
    final choice = choices.first;
    final message = toolObject(choice['message']) ?? const {};
    final accumulator = ToolCallStreamAccumulator();
    final completed = <ToolCall>[];
    final calls = toolObjectList(message['tool_calls']);

    for (var index = 0; index < calls.length; index++) {
      final call = calls[index];
      final function = toolObject(call['function']) ?? const {};
      final arguments = function['arguments'];
      completed.add(
        accumulator.add(
          ToolCallDelta(
            slot: 'response:$index',
            id: toolString(call['id']),
            name: toolString(function['name']),
            argumentsFragment: arguments is String
                ? arguments
                : arguments == null
                    ? ''
                    : jsonEncode(arguments),
            isFinal: true,
          ),
        )!,
      );
    }

    return ToolAssistantMessage(
      text: toolString(message['content']),
      reasoning: _optionalString(message['reasoning_content']),
      toolCalls: completed,
      finishReason: _optionalString(choice['finish_reason']),
    );
  }

  @override
  ToolCallingStreamParser createStreamParser() => _OpenAiStreamParser();

  @override
  Map<String, dynamic> encodeResult(ToolResultMessage result) {
    return {
      'role': 'tool',
      'tool_call_id': result.callId,
      'content': toolOutputAsText(result.output),
    };
  }
}

final class _OpenAiStreamParser implements ToolCallingStreamParser {
  final ToolCallStreamAccumulator _accumulator = ToolCallStreamAccumulator();
  bool _finished = false;

  @override
  ToolStreamUpdate addChunk(Map<String, dynamic> chunk) {
    if (_finished) {
      throw const ToolProtocolException(
        'stream_finished',
        'The OpenAI tool stream has already finished.',
      );
    }

    final text = StringBuffer();
    final reasoning = StringBuffer();
    final completed = <ToolCall>[];
    String? finishReason;
    final choices = toolObjectList(chunk['choices']);

    for (var choiceIndex = 0; choiceIndex < choices.length; choiceIndex++) {
      final choice = choices[choiceIndex];
      final delta = toolObject(choice['delta']) ?? const {};
      text.write(toolString(delta['content']));
      reasoning.write(toolString(delta['reasoning_content']));

      final calls = toolObjectList(delta['tool_calls']);
      for (var listIndex = 0; listIndex < calls.length; listIndex++) {
        final call = calls[listIndex];
        final function = toolObject(call['function']) ?? const {};
        final providerIndex =
            call['index'] is int ? call['index'] as int : listIndex;
        _accumulator.add(
          ToolCallDelta(
            slot: 'choice:$choiceIndex:call:$providerIndex',
            id: _optionalString(call['id']),
            name: _optionalString(function['name']),
            argumentsFragment: toolString(function['arguments']),
          ),
        );
      }

      finishReason ??= _optionalString(choice['finish_reason']);
    }

    if (finishReason != null) {
      if (_accumulator.hasPendingCalls) {
        completed.addAll(_accumulator.completeAll());
      }
      _finished = true;
    }

    return ToolStreamUpdate(
      textDelta: text.toString(),
      reasoningDelta: reasoning.toString(),
      completedCalls: completed,
      finishReason: finishReason,
    );
  }

  @override
  ToolStreamUpdate finish({bool cancelled = false, String? reason}) {
    if (_finished) return ToolStreamUpdate();
    _finished = true;
    return ToolStreamUpdate(
      completedCalls: cancelled
          ? _accumulator.cancelAll(reason)
          : _accumulator.completeAll(),
      finishReason: cancelled ? 'cancelled' : null,
    );
  }
}

String? _optionalString(Object? value) {
  return value is String && value.isNotEmpty ? value : null;
}

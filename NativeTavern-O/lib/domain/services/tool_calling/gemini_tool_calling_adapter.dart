import 'dart:convert';

import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_calling_adapter.dart';

final class GeminiToolCallingAdapter implements ToolCallingAdapter {
  const GeminiToolCallingAdapter();

  @override
  Map<String, dynamic> decorateRequest(
    Map<String, dynamic> baseRequest,
    ToolCallingConfiguration configuration,
  ) {
    if (!configuration.enabled) return baseRequest;

    return {
      ...baseRequest,
      'tools': [
        {
          'functionDeclarations': [
            for (final tool in configuration.tools)
              {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.inputSchema,
              },
          ],
        },
      ],
      'toolConfig': {
        'functionCallingConfig': switch (configuration.choice.mode) {
          ToolChoiceMode.auto => {'mode': 'AUTO'},
          ToolChoiceMode.none => {'mode': 'NONE'},
          ToolChoiceMode.required => {'mode': 'ANY'},
          ToolChoiceMode.named => {
              'mode': 'ANY',
              'allowedFunctionNames': [configuration.choice.toolName],
            },
        },
      },
    };
  }

  @override
  ToolAssistantMessage parseResponse(Map<String, dynamic> response) {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final calls = <ToolCall>[];
    final accumulator = ToolCallStreamAccumulator();
    String? finishReason;
    final candidates = toolObjectList(response['candidates']);

    for (var candidateIndex = 0;
        candidateIndex < candidates.length;
        candidateIndex++) {
      final candidate = candidates[candidateIndex];
      final content = toolObject(candidate['content']) ?? const {};
      final parts = toolObjectList(content['parts']);
      for (var partIndex = 0; partIndex < parts.length; partIndex++) {
        final part = parts[partIndex];
        _readTextPart(part, text, reasoning);
        final function = toolObject(part['functionCall']);
        if (function == null) continue;
        final name = toolString(function['name']);
        final arguments = function['args'];
        calls.add(
          accumulator.add(
            ToolCallDelta(
              slot: 'candidate:$candidateIndex:part:$partIndex',
              id: _callId(function, candidateIndex, partIndex, name),
              name: name,
              argumentsFragment: arguments == null ? '' : jsonEncode(arguments),
              isFinal: true,
            ),
          )!,
        );
      }
      finishReason ??= _optionalString(candidate['finishReason']);
    }

    return ToolAssistantMessage(
      text: text.toString(),
      reasoning: reasoning.isEmpty ? null : reasoning.toString(),
      toolCalls: calls,
      finishReason: finishReason,
    );
  }

  @override
  ToolCallingStreamParser createStreamParser() => _GeminiStreamParser();

  @override
  Map<String, dynamic> encodeResult(ToolResultMessage result) {
    return {
      'role': 'user',
      'parts': [
        {
          'functionResponse': {
            'id': result.callId,
            'name': result.toolName,
            'response': toolOutputAsObject(result),
          },
        },
      ],
    };
  }
}

final class _GeminiStreamParser implements ToolCallingStreamParser {
  final ToolCallStreamAccumulator _accumulator = ToolCallStreamAccumulator();
  bool _finished = false;

  @override
  ToolStreamUpdate addChunk(Map<String, dynamic> chunk) {
    if (_finished) {
      throw const ToolProtocolException(
        'stream_finished',
        'The Gemini tool stream has already finished.',
      );
    }

    final text = StringBuffer();
    final reasoning = StringBuffer();
    final completed = <ToolCall>[];
    String? finishReason;
    final candidates = toolObjectList(chunk['candidates']);

    for (var listIndex = 0; listIndex < candidates.length; listIndex++) {
      final candidate = candidates[listIndex];
      final candidateIndex =
          candidate['index'] is int ? candidate['index'] as int : listIndex;
      final content = toolObject(candidate['content']) ?? const {};
      final parts = toolObjectList(content['parts']);

      for (var partIndex = 0; partIndex < parts.length; partIndex++) {
        final part = parts[partIndex];
        _readTextPart(part, text, reasoning);
        final function = toolObject(part['functionCall']);
        if (function == null) continue;

        final name = toolString(function['name']);
        final arguments = function['args'];
        final slot = 'candidate:$candidateIndex:part:$partIndex';
        final directArguments = arguments is Map;
        final call = _accumulator.add(
          ToolCallDelta(
            slot: slot,
            id: _callId(function, candidateIndex, partIndex, name),
            name: name,
            argumentsFragment:
                directArguments ? jsonEncode(arguments) : toolString(arguments),
            isFinal: directArguments,
          ),
        );
        if (call != null) completed.add(call);
      }

      finishReason ??= _optionalString(candidate['finishReason']);
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

void _readTextPart(
  Map<String, dynamic> part,
  StringBuffer text,
  StringBuffer reasoning,
) {
  final partText = toolString(part['text']);
  final thought = part['thought'];
  if (thought == true) {
    reasoning.write(partText);
  } else if (thought is String) {
    reasoning.write(thought);
  } else {
    text.write(partText);
  }
}

String _callId(
  Map<String, dynamic> function,
  int candidateIndex,
  int partIndex,
  String name,
) {
  return _optionalString(function['id']) ??
      'gemini-$candidateIndex-$partIndex-$name';
}

String? _optionalString(Object? value) {
  return value is String && value.isNotEmpty ? value : null;
}

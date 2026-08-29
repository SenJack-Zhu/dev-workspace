import 'dart:convert';

import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_calling_adapter.dart';

final class ClaudeToolCallingAdapter implements ToolCallingAdapter {
  const ClaudeToolCallingAdapter();

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
            'name': tool.name,
            'description': tool.description,
            'input_schema': tool.inputSchema,
          },
      ],
      'tool_choice': switch (configuration.choice.mode) {
        ToolChoiceMode.auto => {'type': 'auto'},
        ToolChoiceMode.none => {'type': 'none'},
        ToolChoiceMode.required => {'type': 'any'},
        ToolChoiceMode.named => {
            'type': 'tool',
            'name': configuration.choice.toolName,
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
    final blocks = toolObjectList(response['content']);

    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      switch (toolString(block['type'])) {
        case 'text':
          text.write(toolString(block['text']));
        case 'thinking':
          reasoning.write(toolString(block['thinking']));
        case 'tool_use':
          final input = block['input'];
          calls.add(
            accumulator.add(
              ToolCallDelta(
                slot: 'response:$index',
                id: toolString(block['id']),
                name: toolString(block['name']),
                argumentsFragment: input == null ? '' : jsonEncode(input),
                isFinal: true,
              ),
            )!,
          );
      }
    }

    return ToolAssistantMessage(
      text: text.toString(),
      reasoning: reasoning.isEmpty ? null : reasoning.toString(),
      toolCalls: calls,
      finishReason: _optionalString(response['stop_reason']),
    );
  }

  @override
  ToolCallingStreamParser createStreamParser() => _ClaudeStreamParser();

  @override
  Map<String, dynamic> encodeResult(ToolResultMessage result) {
    return {
      'role': 'user',
      'content': [
        {
          'type': 'tool_result',
          'tool_use_id': result.callId,
          'content': toolOutputAsText(result.output),
          if (result.isError) 'is_error': true,
        },
      ],
    };
  }
}

final class _ClaudeStreamParser implements ToolCallingStreamParser {
  final ToolCallStreamAccumulator _accumulator = ToolCallStreamAccumulator();
  final Set<String> _toolSlots = {};
  bool _finished = false;

  @override
  ToolStreamUpdate addChunk(Map<String, dynamic> chunk) {
    if (_finished) {
      throw const ToolProtocolException(
        'stream_finished',
        'The Claude tool stream has already finished.',
      );
    }

    final type = toolString(chunk['type']);
    final index = chunk['index'] is int ? chunk['index'] as int : 0;
    final slot = 'block:$index';
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final completed = <ToolCall>[];
    String? finishReason;

    switch (type) {
      case 'content_block_start':
        final block = toolObject(chunk['content_block']) ?? const {};
        if (block['type'] == 'tool_use') {
          final input = toolObject(block['input']);
          _toolSlots.add(slot);
          _accumulator.add(
            ToolCallDelta(
              slot: slot,
              id: _optionalString(block['id']),
              name: _optionalString(block['name']),
              argumentsFragment:
                  input == null || input.isEmpty ? '' : jsonEncode(input),
            ),
          );
        }
      case 'content_block_delta':
        final delta = toolObject(chunk['delta']) ?? const {};
        switch (toolString(delta['type'])) {
          case 'input_json_delta':
            _toolSlots.add(slot);
            _accumulator.add(
              ToolCallDelta(
                slot: slot,
                argumentsFragment: toolString(delta['partial_json']),
              ),
            );
          case 'text_delta':
            text.write(toolString(delta['text']));
          case 'thinking_delta':
            reasoning.write(toolString(delta['thinking']));
        }
      case 'content_block_stop':
        if (_toolSlots.remove(slot)) {
          completed.add(_accumulator.complete(slot));
        }
      case 'message_delta':
        final delta = toolObject(chunk['delta']);
        finishReason = _optionalString(delta?['stop_reason']);
      case 'message_stop':
        _finished = true;
        if (_accumulator.hasPendingCalls) {
          completed.addAll(_accumulator.completeAll());
        }
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

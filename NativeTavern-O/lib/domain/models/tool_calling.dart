import 'dart:convert';

enum ToolChoiceMode { auto, none, required, named }

enum ToolCallStatus { ready, invalidArguments, cancelled }

enum ToolResultStatus { succeeded, failed, cancelled }

final class ToolProtocolException implements Exception {
  final String code;
  final String message;
  final String? slot;

  const ToolProtocolException(this.code, this.message, {this.slot});

  @override
  String toString() {
    final location = slot == null ? '' : ' at $slot';
    return 'Tool protocol error [$code]$location: $message';
  }
}

final class ToolDefinition {
  static final RegExp _validName = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  factory ToolDefinition({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
  }) {
    if (!_validName.hasMatch(name)) {
      throw const ToolProtocolException(
        'invalid_tool_name',
        'Tool names must contain 1-64 letters, digits, underscores, or dashes.',
      );
    }
    if (description.trim().isEmpty) {
      throw const ToolProtocolException(
        'invalid_tool_description',
        'Tool descriptions must not be empty.',
      );
    }
    final schema = copyToolJsonObject(inputSchema);
    final schemaType = schema['type'];
    if (schemaType != null && schemaType != 'object') {
      throw const ToolProtocolException(
        'invalid_tool_schema',
        'The root input schema must have type object.',
      );
    }
    return ToolDefinition._(name, description, schema);
  }

  const ToolDefinition._(this.name, this.description, this.inputSchema);
}

final class ToolChoice {
  final ToolChoiceMode mode;
  final String? toolName;

  const ToolChoice._(this.mode, this.toolName);

  static const auto = ToolChoice._(ToolChoiceMode.auto, null);
  static const none = ToolChoice._(ToolChoiceMode.none, null);
  static const required = ToolChoice._(ToolChoiceMode.required, null);

  factory ToolChoice.named(String toolName) {
    if (!ToolDefinition._validName.hasMatch(toolName)) {
      throw const ToolProtocolException(
        'invalid_tool_choice',
        'A named tool choice must contain a valid tool name.',
      );
    }
    return ToolChoice._(ToolChoiceMode.named, toolName);
  }
}

final class ToolCallingConfiguration {
  final bool enabled;
  final List<ToolDefinition> tools;
  final ToolChoice choice;
  final int maxRecursionDepth;

  const ToolCallingConfiguration.disabled()
      : enabled = false,
        tools = const [],
        choice = ToolChoice.none,
        maxRecursionDepth = 0;

  factory ToolCallingConfiguration.enabled({
    required Iterable<ToolDefinition> tools,
    ToolChoice choice = ToolChoice.auto,
    int maxRecursionDepth = 8,
  }) {
    final definitions = List<ToolDefinition>.unmodifiable(tools);
    if (definitions.isEmpty) {
      throw const ToolProtocolException(
        'missing_tools',
        'Enabled tool calling requires at least one tool definition.',
      );
    }
    final names = definitions.map((tool) => tool.name).toSet();
    if (names.length != definitions.length) {
      throw const ToolProtocolException(
        'duplicate_tool_name',
        'Tool names must be unique within a request.',
      );
    }
    if (choice.mode == ToolChoiceMode.named &&
        !names.contains(choice.toolName)) {
      throw const ToolProtocolException(
        'unknown_tool_choice',
        'The named tool choice must reference a declared tool.',
      );
    }
    if (maxRecursionDepth < 1) {
      throw const ToolProtocolException(
        'invalid_recursion_limit',
        'The recursion limit must be at least one.',
      );
    }
    return ToolCallingConfiguration._(definitions, choice, maxRecursionDepth);
  }

  const ToolCallingConfiguration._(
    this.tools,
    this.choice,
    this.maxRecursionDepth,
  ) : enabled = true;
}

final class ToolCancellationToken {
  bool _cancelled = false;
  Object? _reason;
  final List<void Function(Object?)> _listeners = [];

  ToolCancellationToken._();

  bool get isCancelled => _cancelled;
  Object? get reason => _reason;

  void throwIfCancelled() {
    if (_cancelled) {
      throw ToolProtocolException(
        'cancelled',
        _reason?.toString() ?? 'Tool processing was cancelled.',
      );
    }
  }

  void whenCancelled(void Function(Object?) listener) {
    if (_cancelled) {
      listener(_reason);
      return;
    }
    _listeners.add(listener);
  }

  void _cancel(Object? reason) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final listeners = List<void Function(Object?)>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener(reason);
    }
  }
}

final class ToolCancellationController {
  final ToolCancellationToken token = ToolCancellationToken._();

  void cancel([Object? reason]) => token._cancel(reason);
}

final class ToolInvocationContext {
  final int depth;
  final int maxDepth;
  final ToolCancellationToken cancellationToken;

  const ToolInvocationContext({
    this.depth = 0,
    required this.maxDepth,
    required this.cancellationToken,
  });

  ToolInvocationContext next() {
    cancellationToken.throwIfCancelled();
    if (depth >= maxDepth) {
      throw ToolProtocolException(
        'recursion_limit',
        'Tool recursion depth $maxDepth has been reached.',
      );
    }
    return ToolInvocationContext(
      depth: depth + 1,
      maxDepth: maxDepth,
      cancellationToken: cancellationToken,
    );
  }
}

final class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String rawArguments;
  final ToolCallStatus status;
  final String? error;

  factory ToolCall.ready({
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    required String rawArguments,
  }) {
    _validateIdentity(id, name);
    return ToolCall._(
      id,
      name,
      copyToolJsonObject(arguments),
      rawArguments,
      ToolCallStatus.ready,
      null,
    );
  }

  factory ToolCall.invalidArguments({
    required String id,
    required String name,
    required String rawArguments,
    required String error,
  }) {
    _validateIdentity(id, name);
    return ToolCall._(
      id,
      name,
      const {},
      rawArguments,
      ToolCallStatus.invalidArguments,
      error,
    );
  }

  factory ToolCall.cancelled({
    required String id,
    required String name,
    required String rawArguments,
    String? reason,
  }) {
    _validateIdentity(id, name);
    return ToolCall._(
      id,
      name,
      const {},
      rawArguments,
      ToolCallStatus.cancelled,
      reason,
    );
  }

  const ToolCall._(
    this.id,
    this.name,
    this.arguments,
    this.rawArguments,
    this.status,
    this.error,
  );

  static void _validateIdentity(String id, String name) {
    if (id.trim().isEmpty) {
      throw const ToolProtocolException(
        'missing_call_id',
        'Tool calls require a non-empty ID.',
      );
    }
    if (!ToolDefinition._validName.hasMatch(name)) {
      throw const ToolProtocolException(
        'invalid_call_name',
        'Tool calls require a valid tool name.',
      );
    }
  }
}

final class ToolResultMessage {
  final String callId;
  final String toolName;
  final Object? output;
  final ToolResultStatus status;

  factory ToolResultMessage({
    required String callId,
    required String toolName,
    required Object? output,
    ToolResultStatus status = ToolResultStatus.succeeded,
  }) {
    ToolCall._validateIdentity(callId, toolName);
    return ToolResultMessage._(
      callId,
      toolName,
      copyToolJsonValue(output),
      status,
    );
  }

  const ToolResultMessage._(
    this.callId,
    this.toolName,
    this.output,
    this.status,
  );

  bool get isError => status != ToolResultStatus.succeeded;
}

final class ToolAssistantMessage {
  final String text;
  final String? reasoning;
  final List<ToolCall> toolCalls;
  final String? finishReason;

  ToolAssistantMessage({
    this.text = '',
    this.reasoning,
    Iterable<ToolCall> toolCalls = const [],
    this.finishReason,
  }) : toolCalls = List<ToolCall>.unmodifiable(toolCalls);

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

final class ToolProviderTurn {
  ToolProviderTurn({
    required this.assistant,
    required Map<String, dynamic> continuationMessage,
  }) : continuationMessage = copyToolJsonObject(continuationMessage);

  final ToolAssistantMessage assistant;
  final Map<String, dynamic> continuationMessage;
}

final class ToolStreamUpdate {
  final String textDelta;
  final String reasoningDelta;
  final List<ToolCall> completedCalls;
  final String? finishReason;

  ToolStreamUpdate({
    this.textDelta = '',
    this.reasoningDelta = '',
    Iterable<ToolCall> completedCalls = const [],
    this.finishReason,
  }) : completedCalls = List<ToolCall>.unmodifiable(completedCalls);

  bool get isEmpty =>
      textDelta.isEmpty &&
      reasoningDelta.isEmpty &&
      completedCalls.isEmpty &&
      finishReason == null;
}

final class ToolCallDelta {
  final String slot;
  final String? id;
  final String? name;
  final String argumentsFragment;
  final bool isFinal;

  const ToolCallDelta({
    required this.slot,
    this.id,
    this.name,
    this.argumentsFragment = '',
    this.isFinal = false,
  });
}

final class ToolCallStreamAccumulator {
  final Map<String, _PendingToolCall> _pending = {};
  final Map<String, String> _idSlots = {};
  final Set<String> _completedSlots = {};

  bool get hasPendingCalls => _pending.isNotEmpty;

  ToolCall? add(ToolCallDelta delta) {
    if (delta.slot.trim().isEmpty) {
      throw const ToolProtocolException(
        'missing_stream_slot',
        'Streamed tool deltas require a stable slot.',
      );
    }
    if (_completedSlots.contains(delta.slot)) {
      throw ToolProtocolException(
        'completed_stream_slot',
        'A completed tool call cannot accept more deltas.',
        slot: delta.slot,
      );
    }
    final pending = _pending.putIfAbsent(delta.slot, () => _PendingToolCall());

    if (delta.id != null && delta.id!.isNotEmpty) {
      final existingSlot = _idSlots[delta.id];
      if (existingSlot != null && existingSlot != delta.slot) {
        throw ToolProtocolException(
          'duplicate_call_id',
          'Call ID ${delta.id} is already assigned to stream slot $existingSlot.',
          slot: delta.slot,
        );
      }
      if (pending.id != null && pending.id != delta.id) {
        throw ToolProtocolException(
          'changed_call_id',
          'A stream slot cannot change its call ID.',
          slot: delta.slot,
        );
      }
      pending.id = delta.id;
      _idSlots[delta.id!] = delta.slot;
    }

    if (delta.name != null && delta.name!.isNotEmpty) {
      if (pending.name != null && pending.name != delta.name) {
        throw ToolProtocolException(
          'changed_call_name',
          'A stream slot cannot change its tool name.',
          slot: delta.slot,
        );
      }
      pending.name = delta.name;
    }
    pending.arguments.write(delta.argumentsFragment);

    return delta.isFinal ? complete(delta.slot) : null;
  }

  ToolCall complete(String slot) {
    final pending = _pending.remove(slot);
    if (pending == null) {
      throw ToolProtocolException(
        'unknown_stream_slot',
        'No pending tool call exists for this stream slot.',
        slot: slot,
      );
    }
    final id = pending.id;
    final name = pending.name;
    if (id == null || id.isEmpty) {
      throw ToolProtocolException(
        'missing_call_id',
        'The streamed tool call completed without an ID.',
        slot: slot,
      );
    }
    if (name == null || name.isEmpty) {
      throw ToolProtocolException(
        'missing_call_name',
        'The streamed tool call completed without a tool name.',
        slot: slot,
      );
    }

    _completedSlots.add(slot);
    final raw = pending.arguments.toString();
    if (raw.trim().isEmpty) {
      return ToolCall.ready(
        id: id,
        name: name,
        arguments: const {},
        rawArguments: raw,
      );
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return ToolCall.invalidArguments(
          id: id,
          name: name,
          rawArguments: raw,
          error: 'Tool arguments must decode to a JSON object.',
        );
      }
      return ToolCall.ready(
        id: id,
        name: name,
        arguments: decoded,
        rawArguments: raw,
      );
    } on FormatException catch (error) {
      return ToolCall.invalidArguments(
        id: id,
        name: name,
        rawArguments: raw,
        error: error.message,
      );
    }
  }

  List<ToolCall> completeAll() {
    return [for (final slot in _pending.keys.toList()) complete(slot)];
  }

  List<ToolCall> cancelAll([String? reason]) {
    final cancelled = <ToolCall>[];
    for (final entry in _pending.entries.toList()) {
      final pending = entry.value;
      final id = pending.id;
      final name = pending.name;
      if (id == null || name == null) {
        _pending.remove(entry.key);
        _completedSlots.add(entry.key);
        continue;
      }
      cancelled.add(
        ToolCall.cancelled(
          id: id,
          name: name,
          rawArguments: pending.arguments.toString(),
          reason: reason,
        ),
      );
      _pending.remove(entry.key);
      _completedSlots.add(entry.key);
    }
    return cancelled;
  }
}

final class _PendingToolCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

Map<String, dynamic> copyToolJsonObject(Map<String, dynamic> value) {
  return Map<String, dynamic>.unmodifiable({
    for (final entry in value.entries)
      entry.key: copyToolJsonValue(entry.value),
  });
}

Object? copyToolJsonValue(Object? value) {
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(copyToolJsonValue));
  }
  if (value is Map) {
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const ToolProtocolException(
          'invalid_json_value',
          'Tool JSON objects require string keys.',
        );
      }
      result[key] = copyToolJsonValue(entry.value);
    }
    return Map<String, dynamic>.unmodifiable(result);
  }
  throw ToolProtocolException(
    'invalid_json_value',
    'Unsupported tool JSON value of type ${value.runtimeType}.',
  );
}

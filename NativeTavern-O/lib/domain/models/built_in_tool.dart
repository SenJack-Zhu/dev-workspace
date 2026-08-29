import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/capability_registry.dart';

enum ToolAccessLevel { readOnly, write, externalSideEffect }

enum ToolDataScope {
  randomValue,
  variableName,
  variableValue,
  worldInfoQuery,
  worldInfoContent,
  imagePrompt,
  generatedImage,
  mcpToolArguments,
  mcpToolResult,
}

enum ToolAuthorizationSource { none, userSettings, oneTimeApproval, dryRun }

enum ToolExecutionOutcome { succeeded, failed, cancelled, denied, dryRun }

enum ToolApprovalDecision { approveOnce, deny, cancel }

final class BuiltInToolException implements Exception {
  final String code;
  final String message;

  const BuiltInToolException(this.code, this.message);

  @override
  String toString() => 'Built-in tool error [$code]: $message';
}

final class BuiltInToolDescriptor {
  final ToolDefinition definition;
  final ToolAccessLevel accessLevel;
  final Set<CapabilityId> requiredCapabilities;
  final Set<ToolDataScope> dataScopes;
  final bool supportsDryRun;
  final String target;
  final Set<String> sensitiveArgumentNames;

  BuiltInToolDescriptor({
    required this.definition,
    required this.accessLevel,
    Iterable<CapabilityId> requiredCapabilities = const [],
    Iterable<ToolDataScope> dataScopes = const [],
    this.supportsDryRun = false,
    required String target,
    Iterable<String> sensitiveArgumentNames = const [],
  })  : requiredCapabilities = Set<CapabilityId>.unmodifiable(
          requiredCapabilities,
        ),
        dataScopes = Set<ToolDataScope>.unmodifiable(dataScopes),
        target = _requireTarget(target),
        sensitiveArgumentNames = Set<String>.unmodifiable(
          sensitiveArgumentNames,
        );

  bool get requiresOneTimeApproval => accessLevel != ToolAccessLevel.readOnly;

  static String _requireTarget(String value) {
    final target = value.trim();
    final validTarget = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$');
    if (!validTarget.hasMatch(target) || target.contains('..')) {
      throw ArgumentError.value(
        value,
        'target',
        'Target must be a logical identifier without credentials or query data.',
      );
    }
    return target;
  }
}

final class ToolPermissionSnapshot {
  static const none = ToolPermissionSnapshot._(<String>{});

  final Set<String> allowedToolNames;

  factory ToolPermissionSnapshot.fromUserSettings(
    Iterable<String> allowedToolNames,
  ) {
    final names = allowedToolNames.map((name) => name.trim()).toSet();
    if (names.any((name) => name.isEmpty)) {
      throw ArgumentError.value(
        allowedToolNames,
        'allowedToolNames',
        'Enabled tool names must not be empty.',
      );
    }
    return ToolPermissionSnapshot._(Set<String>.unmodifiable(names));
  }

  const ToolPermissionSnapshot._(this.allowedToolNames);

  bool allows(String toolName) => allowedToolNames.contains(toolName);
}

final class ToolCapabilitySnapshot {
  static const none = ToolCapabilitySnapshot._(<CapabilityId>{});

  final Set<CapabilityId> availableCapabilities;

  factory ToolCapabilitySnapshot.available(
    Iterable<CapabilityId> capabilities,
  ) {
    return ToolCapabilitySnapshot._(
      Set<CapabilityId>.unmodifiable(capabilities),
    );
  }

  const ToolCapabilitySnapshot._(this.availableCapabilities);

  bool satisfies(Iterable<CapabilityId> required) {
    return required.every(availableCapabilities.contains);
  }
}

final class ToolExecutionPreview {
  final String callId;
  final String toolName;
  final ToolAccessLevel accessLevel;
  final String target;
  final Map<String, dynamic> parameters;
  final Set<CapabilityId> requiredCapabilities;
  final Set<ToolDataScope> dataScopes;
  final bool requiresConfirmation;
  final bool supportsDryRun;
  final bool dryRun;

  ToolExecutionPreview({
    required this.callId,
    required this.toolName,
    required this.accessLevel,
    required this.target,
    required Map<String, dynamic> parameters,
    required Iterable<CapabilityId> requiredCapabilities,
    required Iterable<ToolDataScope> dataScopes,
    required this.requiresConfirmation,
    required this.supportsDryRun,
    required this.dryRun,
  })  : parameters = copyToolJsonObject(parameters),
        requiredCapabilities = Set<CapabilityId>.unmodifiable(
          requiredCapabilities,
        ),
        dataScopes = Set<ToolDataScope>.unmodifiable(dataScopes);
}

typedef ToolApprovalHandler = Future<ToolApprovalDecision> Function(
    ToolExecutionPreview preview);

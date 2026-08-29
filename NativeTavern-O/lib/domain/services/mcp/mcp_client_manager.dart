import 'dart:async';

import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/repositories/mcp_repository.dart';
import 'package:native_tavern/domain/services/capability_registry.dart';
import 'package:native_tavern/domain/services/mcp/mcp_protocol_client.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_execution_audit_service.dart';

typedef McpApprovalHandler = Future<McpApprovalDecision> Function(
  ToolExecutionPreview preview,
);

final class McpClientManager {
  McpClientManager({
    required McpSettingsRepository settingsRepository,
    required McpCredentialRepository credentialRepository,
    required McpActivityRepository activityRepository,
    required ToolExecutionAuditRepository toolAuditRepository,
    McpProtocolClientFactory protocolClientFactory =
        const McpDartProtocolClientFactory(),
    DateTime Function()? clock,
  })  : _settingsRepository = settingsRepository,
        _credentialRepository = credentialRepository,
        _activityRepository = activityRepository,
        _toolAuditRepository = toolAuditRepository,
        _protocolClientFactory = protocolClientFactory,
        _clock = clock ?? DateTime.now;

  final McpSettingsRepository _settingsRepository;
  final McpCredentialRepository _credentialRepository;
  final McpActivityRepository _activityRepository;
  final ToolExecutionAuditRepository _toolAuditRepository;
  final McpProtocolClientFactory _protocolClientFactory;
  final DateTime Function() _clock;
  final StreamController<void> _changes = StreamController.broadcast();
  final Map<String, McpProtocolSession> _sessions = {};
  final Map<String, ToolCancellationController> _operations = {};
  final Map<String, McpServerSnapshot> _snapshots = {};
  Future<void>? _initializing;
  McpStoredSettings _settings = McpStoredSettings();
  bool _initialized = false;
  bool _closed = false;

  Stream<void> get changes => _changes.stream;
  bool get enabled => _settings.enabled;
  List<McpServerConfig> get servers => List.unmodifiable(_settings.servers);
  List<McpServerSnapshot> get snapshots => _settings.servers
      .map((server) => _snapshotFor(server))
      .toList(growable: false);

  List<McpToolDescriptor> get discoveredTools => snapshots
      .where((snapshot) => snapshot.isConnected)
      .expand((snapshot) => snapshot.tools)
      .toList(growable: false);

  Future<void> initialize() {
    if (_initialized) return Future.value();
    final current = _initializing;
    if (current != null) return current;
    final operation = _initialize();
    _initializing = operation;
    return operation.whenComplete(() => _initializing = null);
  }

  Future<void> _initialize() async {
    _requireOpen();
    _settings = await _settingsRepository.load();
    _snapshots
      ..clear()
      ..addEntries(_settings.servers.map((server) => MapEntry(
            server.id,
            McpServerSnapshot(
              config: server,
              status: !_settings.enabled || !server.enabled
                  ? McpConnectionStatus.disabled
                  : McpConnectionStatus.disconnected,
            ),
          )));
    _initialized = true;
    _notify();
  }

  McpServerSnapshot snapshot(String serverId) {
    final config = _server(serverId);
    return _snapshotFor(config);
  }

  McpToolPermission permissionFor(String serverId, String toolName) {
    for (final permission in _settings.permissions) {
      if (permission.serverId == serverId && permission.toolName == toolName) {
        return permission.permission;
      }
    }
    return McpToolPermission.askEveryTime;
  }

  bool hasNameCollision(McpToolDescriptor tool) {
    return discoveredTools
            .where((candidate) => candidate.name == tool.name)
            .map((candidate) => candidate.serverId)
            .toSet()
            .length >
        1;
  }

  Future<void> setEnabled(bool value) async {
    await initialize();
    if (_settings.enabled == value) return;
    if (!value) await disconnectAll();
    _settings = McpStoredSettings(
      enabled: value,
      servers: _settings.servers,
      permissions: _settings.permissions,
    );
    for (final server in _settings.servers) {
      final current = _snapshotFor(server);
      _snapshots[server.id] = current.copyWith(
        status: !value || !server.enabled
            ? McpConnectionStatus.disabled
            : McpConnectionStatus.disconnected,
        clearError: true,
      );
    }
    await _save();
    _notify();
  }

  Future<void> upsertServer(
    McpServerConfig config, {
    String? bearerToken,
    bool clearCredential = false,
  }) async {
    await initialize();
    final existing =
        _settings.servers.where((server) => server.id == config.id).firstOrNull;
    if (existing != null &&
        (existing.endpoint != config.endpoint ||
            existing.transport != config.transport)) {
      await disconnect(config.id);
    }
    final servers = [..._settings.servers];
    final index = servers.indexWhere((server) => server.id == config.id);
    if (index < 0) {
      servers.add(config);
    } else {
      servers[index] = config;
    }
    servers.sort((left, right) => left.name.compareTo(right.name));
    _settings = McpStoredSettings(
      enabled: _settings.enabled,
      servers: servers,
      permissions: _settings.permissions,
    );
    if (clearCredential) {
      await _credentialRepository.deleteToken(config.id);
    } else if (bearerToken != null) {
      await _credentialRepository.writeToken(config.id, bearerToken);
    }
    final current = _snapshots[config.id];
    _snapshots[config.id] =
        (current ?? McpServerSnapshot(config: config)).copyWith(
      config: config,
      status: !_settings.enabled || !config.enabled
          ? McpConnectionStatus.disabled
          : current?.status ?? McpConnectionStatus.disconnected,
      clearError: true,
    );
    await _save();
    await _record(
      config.id,
      McpActivityKind.configured,
      existing == null ? 'Server added.' : 'Server configuration updated.',
    );
    if (!config.enabled) await disconnect(config.id);
    _notify();
  }

  Future<void> setServerEnabled(String serverId, bool value) async {
    await initialize();
    final config = _server(serverId).copyWith(enabled: value);
    await upsertServer(config);
  }

  Future<void> removeServer(String serverId) async {
    await initialize();
    _server(serverId);
    await disconnect(serverId);
    await _credentialRepository.deleteToken(serverId);
    _settings = McpStoredSettings(
      enabled: _settings.enabled,
      servers:
          _settings.servers.where((server) => server.id != serverId).toList(),
      permissions: _settings.permissions
          .where((permission) => permission.serverId != serverId)
          .toList(),
    );
    _snapshots.remove(serverId);
    await _save();
    await _record(serverId, McpActivityKind.configured, 'Server removed.');
    _notify();
  }

  Future<void> connect(String serverId, {bool reconnecting = false}) async {
    await initialize();
    final config = _server(serverId);
    if (!_settings.enabled) {
      throw const McpException(
        'feature_disabled',
        'Enable MCP before connecting a server.',
      );
    }
    if (!config.enabled) {
      throw const McpException(
        'server_disabled',
        'Enable this server before connecting.',
      );
    }
    await _sessions.remove(serverId)?.close();
    _operations.remove(serverId)?.cancel('Superseded by a new connection.');
    final operation = ToolCancellationController();
    _operations[serverId] = operation;
    _snapshots[serverId] = _snapshotFor(config).copyWith(
      status: reconnecting
          ? McpConnectionStatus.reconnecting
          : McpConnectionStatus.connecting,
      clearError: true,
      clearTools: true,
      clearConnectedAt: true,
    );
    _notify();
    try {
      final token = await _credentialRepository.readToken(serverId);
      final session = await _protocolClientFactory.connect(
        config: config,
        bearerToken: token,
        cancellationToken: operation.token,
        onToolsChanged: () => _refreshAfterNotification(serverId),
        onError: (error) => _handleProtocolError(serverId, error),
      );
      operation.token.throwIfCancelled();
      _sessions[serverId] = session;
      final tools = await session.listTools(
        cancellationToken: operation.token,
        timeout: config.requestTimeout,
      );
      operation.token.throwIfCancelled();
      _snapshots[serverId] = _snapshotFor(config).copyWith(
        status: McpConnectionStatus.connected,
        tools: tools,
        serverImplementation: session.serverImplementation,
        serverVersion: session.serverVersion,
        protocolVersion: session.protocolVersion,
        connectedAt: _clock().toUtc(),
        clearError: true,
      );
      await _record(
        serverId,
        McpActivityKind.connected,
        'Connected and discovered ${tools.length} tool(s).',
      );
    } catch (error) {
      await _sessions.remove(serverId)?.close();
      final mapped = _mapError(error);
      _snapshots[serverId] = _snapshotFor(config).copyWith(
        status: mapped.code == 'cancelled'
            ? McpConnectionStatus.disconnected
            : McpConnectionStatus.error,
        clearTools: true,
        errorCode: mapped.code,
        errorMessage: mapped.message,
        clearConnectedAt: true,
      );
      await _record(
        serverId,
        mapped.code == 'cancelled'
            ? McpActivityKind.cancelled
            : McpActivityKind.error,
        mapped.message,
        errorCode: mapped.code,
      );
      rethrow;
    } finally {
      if (identical(_operations[serverId], operation)) {
        _operations.remove(serverId);
      }
      _notify();
    }
  }

  Future<void> reconnect(String serverId) async {
    await disconnect(serverId);
    await connect(serverId, reconnecting: true);
  }

  Future<void> refreshTools(String serverId) async {
    await initialize();
    final config = _server(serverId);
    final session = _sessions[serverId];
    if (session == null) {
      throw const McpException(
        'not_connected',
        'Connect the server before refreshing tools.',
      );
    }
    _operations.remove(serverId)?.cancel('Superseded by tool refresh.');
    final operation = ToolCancellationController();
    _operations[serverId] = operation;
    try {
      final tools = await session.listTools(
        cancellationToken: operation.token,
        timeout: config.requestTimeout,
      );
      _snapshots[serverId] = _snapshotFor(config).copyWith(
        status: McpConnectionStatus.connected,
        tools: tools,
        clearError: true,
      );
      await _record(
        serverId,
        McpActivityKind.discovery,
        'Tool discovery refreshed: ${tools.length} tool(s).',
      );
    } catch (error) {
      final mapped = _mapError(error);
      _snapshots[serverId] = _snapshotFor(config).copyWith(
        status: mapped.code == 'cancelled'
            ? McpConnectionStatus.connected
            : McpConnectionStatus.error,
        errorCode: mapped.code,
        errorMessage: mapped.message,
      );
      await _record(
        serverId,
        mapped.code == 'cancelled'
            ? McpActivityKind.cancelled
            : McpActivityKind.error,
        mapped.message,
        errorCode: mapped.code,
      );
      rethrow;
    } finally {
      if (identical(_operations[serverId], operation)) {
        _operations.remove(serverId);
      }
      _notify();
    }
  }

  void cancelOperation(String serverId, [String reason = 'Cancelled by user']) {
    _operations[serverId]?.cancel(reason);
  }

  Future<void> disconnect(String serverId) async {
    if (!_initialized) return;
    final config =
        _settings.servers.where((server) => server.id == serverId).firstOrNull;
    if (config == null) return;
    _operations.remove(serverId)?.cancel('Server disconnected.');
    final session = _sessions.remove(serverId);
    if (session != null) {
      try {
        await session.close().timeout(const Duration(seconds: 5));
      } catch (_) {
        // Local state is still released even if the remote close fails.
      }
      await _record(
        serverId,
        McpActivityKind.disconnected,
        'Server disconnected.',
      );
    }
    _snapshots[serverId] = _snapshotFor(config).copyWith(
      status: !_settings.enabled || !config.enabled
          ? McpConnectionStatus.disabled
          : McpConnectionStatus.disconnected,
      clearTools: true,
      clearError: true,
      clearConnectedAt: true,
    );
    _notify();
  }

  Future<void> disconnectAll() async {
    for (final serverId in {..._sessions.keys, ..._operations.keys}) {
      await disconnect(serverId);
    }
  }

  Future<void> setToolPermission(
    String serverId,
    String toolName,
    McpToolPermission permission,
  ) async {
    await initialize();
    _server(serverId);
    final permissions = _settings.permissions
        .where((entry) =>
            !(entry.serverId == serverId && entry.toolName == toolName))
        .toList();
    if (permission != McpToolPermission.askEveryTime) {
      permissions.add(McpToolPermissionRecord(
        serverId: serverId,
        toolName: toolName,
        permission: permission,
      ));
    }
    _settings = McpStoredSettings(
      enabled: _settings.enabled,
      servers: _settings.servers,
      permissions: permissions,
    );
    await _save();
    await _record(
      serverId,
      McpActivityKind.permission,
      'Tool permission changed to ${permission.name}.',
      toolName: toolName,
    );
    _notify();
  }

  Future<ToolResultMessage> executeTool({
    required String serverId,
    required ToolCall call,
    required ToolInvocationContext invocationContext,
    McpApprovalHandler? requestApproval,
  }) async {
    await initialize();
    final started = Stopwatch()..start();
    final snapshot = this.snapshot(serverId);
    final tool = snapshot.tools
        .where((candidate) =>
            candidate.name == call.name || candidate.qualifiedName == call.name)
        .firstOrNull;
    if (!snapshot.isConnected || tool == null) {
      return _finishTool(
        call: call,
        tool: tool,
        serverId: serverId,
        started: started,
        source: ToolAuthorizationSource.none,
        outcome: ToolExecutionOutcome.denied,
        status: ToolResultStatus.failed,
        output: const {'error': 'MCP tool is unavailable.'},
        errorCode: 'tool_unavailable',
      );
    }
    if (call.status != ToolCallStatus.ready) {
      return _finishTool(
        call: call,
        tool: tool,
        serverId: serverId,
        started: started,
        source: ToolAuthorizationSource.none,
        outcome: ToolExecutionOutcome.denied,
        status: ToolResultStatus.failed,
        output: const {'error': 'Tool arguments are invalid.'},
        errorCode: 'invalid_arguments',
      );
    }

    var permission = permissionFor(serverId, tool.name);
    var source = ToolAuthorizationSource.none;
    if (permission == McpToolPermission.denied) {
      return _finishTool(
        call: call,
        tool: tool,
        serverId: serverId,
        started: started,
        source: source,
        outcome: ToolExecutionOutcome.denied,
        status: ToolResultStatus.failed,
        output: const {'error': 'User denied this MCP tool.'},
        errorCode: 'permission_denied',
      );
    }
    if (permission == McpToolPermission.alwaysAllow) {
      source = ToolAuthorizationSource.userSettings;
    } else {
      final preview = ToolExecutionPreview(
        callId: call.id,
        toolName: tool.qualifiedName,
        accessLevel: tool.accessLevel,
        target: 'mcp:$serverId/${tool.name}',
        parameters: call.arguments,
        requiredCapabilities: const [CapabilityId.mcp],
        dataScopes: const [ToolDataScope.mcpToolArguments],
        requiresConfirmation: true,
        supportsDryRun: false,
        dryRun: false,
      );
      final decision = requestApproval == null
          ? McpApprovalDecision.deny
          : await requestApproval(preview);
      switch (decision) {
        case McpApprovalDecision.allowOnce:
          source = ToolAuthorizationSource.oneTimeApproval;
        case McpApprovalDecision.alwaysAllow:
          permission = McpToolPermission.alwaysAllow;
          await setToolPermission(serverId, tool.name, permission);
          source = ToolAuthorizationSource.userSettings;
        case McpApprovalDecision.deny:
          return _finishTool(
            call: call,
            tool: tool,
            serverId: serverId,
            started: started,
            source: ToolAuthorizationSource.none,
            outcome: ToolExecutionOutcome.denied,
            status: ToolResultStatus.failed,
            output: const {'error': 'User denied this MCP tool call.'},
            errorCode: 'permission_denied',
          );
        case McpApprovalDecision.cancel:
          return _finishTool(
            call: call,
            tool: tool,
            serverId: serverId,
            started: started,
            source: ToolAuthorizationSource.none,
            outcome: ToolExecutionOutcome.cancelled,
            status: ToolResultStatus.cancelled,
            output: const {'error': 'Tool call cancelled by user.'},
            errorCode: 'cancelled',
          );
      }
    }

    try {
      invocationContext.cancellationToken.throwIfCancelled();
      final output = await _sessions[serverId]!.callTool(
        name: tool.name,
        arguments: call.arguments,
        cancellationToken: invocationContext.cancellationToken,
        timeout: snapshot.config.requestTimeout,
      );
      final isError = output['isError'] == true;
      return _finishTool(
        call: call,
        tool: tool,
        serverId: serverId,
        started: started,
        source: source,
        outcome: isError
            ? ToolExecutionOutcome.failed
            : ToolExecutionOutcome.succeeded,
        status: isError ? ToolResultStatus.failed : ToolResultStatus.succeeded,
        output: output,
        errorCode: isError ? 'remote_tool_error' : null,
      );
    } catch (error) {
      final mapped = _mapError(error);
      final cancelled = mapped.code == 'cancelled' ||
          invocationContext.cancellationToken.isCancelled;
      return _finishTool(
        call: call,
        tool: tool,
        serverId: serverId,
        started: started,
        source: source,
        outcome: cancelled
            ? ToolExecutionOutcome.cancelled
            : ToolExecutionOutcome.failed,
        status:
            cancelled ? ToolResultStatus.cancelled : ToolResultStatus.failed,
        output: {'error': mapped.message},
        errorCode: cancelled ? 'cancelled' : mapped.code,
      );
    }
  }

  Future<List<McpActivityRecord>> readRecentActivity({int limit = 100}) =>
      _activityRepository.readRecent(limit: limit);

  Future<void> close() async {
    if (_closed) return;
    await disconnectAll();
    _closed = true;
    await _changes.close();
  }

  Future<ToolResultMessage> _finishTool({
    required ToolCall call,
    required McpToolDescriptor? tool,
    required String serverId,
    required Stopwatch started,
    required ToolAuthorizationSource source,
    required ToolExecutionOutcome outcome,
    required ToolResultStatus status,
    required Object? output,
    String? errorCode,
  }) async {
    final descriptor = tool;
    await _toolAuditRepository.record(ToolExecutionAuditRecord(
      timestamp: _clock().toUtc(),
      callIdFingerprint: fingerprintToolCallId(call.id),
      toolName: descriptor?.qualifiedName ?? call.name,
      accessLevel:
          descriptor?.accessLevel ?? ToolAccessLevel.externalSideEffect,
      parameterSummary: summarizeToolArguments(call.arguments),
      target: descriptor == null
          ? 'mcp:$serverId/unavailable'
          : 'mcp:$serverId/${descriptor.name}',
      authorizationSource: source,
      result: outcome,
      errorCode: errorCode,
      durationMilliseconds: started.elapsedMilliseconds,
    ));
    return ToolResultMessage(
      callId: call.id,
      toolName: descriptor?.qualifiedName ?? _safeToolName(call.name),
      output: output,
      status: status,
    );
  }

  Future<void> _refreshAfterNotification(String serverId) async {
    if (_closed || !_sessions.containsKey(serverId)) return;
    try {
      await refreshTools(serverId);
    } catch (_) {
      // refreshTools exposes a sanitized error in state and activity logs.
    }
  }

  void _handleProtocolError(String serverId, Object error) {
    if (_closed || !_snapshots.containsKey(serverId)) return;
    final mapped = _mapError(error);
    final current = _snapshots[serverId]!;
    _snapshots[serverId] = current.copyWith(
      status: McpConnectionStatus.error,
      errorCode: mapped.code,
      errorMessage: mapped.message,
    );
    unawaited(_record(
      serverId,
      McpActivityKind.error,
      mapped.message,
      errorCode: mapped.code,
    ));
    _notify();
  }

  McpServerConfig _server(String serverId) {
    return _settings.servers
        .where((server) => server.id == serverId)
        .firstOrNullOrThrow(
          const McpException('server_not_found', 'MCP server not found.'),
        );
  }

  McpServerSnapshot _snapshotFor(McpServerConfig config) {
    return _snapshots[config.id] ??
        McpServerSnapshot(
          config: config,
          status: !_settings.enabled || !config.enabled
              ? McpConnectionStatus.disabled
              : McpConnectionStatus.disconnected,
        );
  }

  Future<void> _save() => _settingsRepository.save(_settings);

  Future<void> _record(
    String serverId,
    McpActivityKind kind,
    String message, {
    String? toolName,
    String? errorCode,
  }) {
    return _activityRepository.record(McpActivityRecord(
      timestamp: _clock().toUtc(),
      serverId: serverId,
      kind: kind,
      message: sanitizeMcpDiagnostic(message),
      toolName: toolName,
      errorCode: errorCode,
    ));
  }

  void _notify() {
    if (!_closed) _changes.add(null);
  }

  void _requireOpen() {
    if (_closed) {
      throw const McpException('manager_closed', 'MCP manager is closed.');
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }

  T firstOrNullOrThrow(Object error) {
    final value = firstOrNull;
    if (value == null) throw error;
    return value;
  }
}

McpException _mapError(Object error) {
  if (error is McpException) return error;
  if (error is ToolProtocolException && error.code == 'cancelled') {
    return const McpException('cancelled', 'Operation cancelled.');
  }
  if (error is TimeoutException) {
    return const McpException('timeout', 'The MCP operation timed out.');
  }
  final text = error.toString().toLowerCase();
  if (text.contains('abort') || text.contains('cancel')) {
    return const McpException('cancelled', 'Operation cancelled.');
  }
  if (text.contains('unauthorized') || text.contains('401')) {
    return const McpException(
      'unauthorized',
      'Authentication failed. Check the server token.',
    );
  }
  if (text.contains('socket') || text.contains('connection refused')) {
    return const McpException(
      'connection_failed',
      'Could not reach the MCP server.',
    );
  }
  return McpException(
    'protocol_error',
    sanitizeMcpDiagnostic(error.toString()),
  );
}

String sanitizeMcpDiagnostic(String source) {
  var result = source
      .replaceAll(RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
          'Bearer [redacted]')
      .replaceAllMapped(
        RegExp(r'https?://[^\s?]+\?[^\s]+', caseSensitive: false),
        (match) => '${match.group(0)!.split('?').first}?[redacted]',
      )
      .replaceAll(
        RegExp(
          r'(token|secret|password|api[_-]?key|authorization)\s*[:=]\s*[^\s,;]+',
          caseSensitive: false,
        ),
        r'$1=[redacted]',
      );
  if (result.length > 500) result = '${result.substring(0, 500)}...';
  return result;
}

String _safeToolName(String source) {
  final normalized = source.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
  final value = normalized.isEmpty ? 'mcp_tool' : normalized;
  return value.length <= 64 ? value : value.substring(0, 64);
}

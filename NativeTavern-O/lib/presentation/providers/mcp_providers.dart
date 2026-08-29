import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:native_tavern/domain/repositories/mcp_repository.dart';
import 'package:native_tavern/domain/services/mcp/mcp_client_manager.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_execution_audit_service.dart';

final mcpSettingsRepositoryProvider = Provider<McpSettingsRepository>((ref) {
  return FileMcpSettingsRepository(dataPath: ref.watch(dataPathProvider));
});

final mcpCredentialRepositoryProvider =
    Provider<McpCredentialRepository>((ref) {
  return const SecureMcpCredentialRepository();
});

final mcpActivityRepositoryProvider = Provider<McpActivityRepository>((ref) {
  return FileMcpActivityRepository(dataPath: ref.watch(dataPathProvider));
});

final toolExecutionAuditRepositoryProvider =
    Provider<ToolExecutionAuditRepository>((ref) {
  return FileToolExecutionAuditRepository(
    dataPath: ref.watch(dataPathProvider),
  );
});

final mcpClientManagerProvider = Provider<McpClientManager>((ref) {
  final manager = McpClientManager(
    settingsRepository: ref.watch(mcpSettingsRepositoryProvider),
    credentialRepository: ref.watch(mcpCredentialRepositoryProvider),
    activityRepository: ref.watch(mcpActivityRepositoryProvider),
    toolAuditRepository: ref.watch(toolExecutionAuditRepositoryProvider),
  );
  ref.onDispose(() => unawaited(manager.close()));
  return manager;
});

final class McpManagementState {
  const McpManagementState({
    this.loading = true,
    this.enabled = false,
    this.servers = const [],
    this.activity = const [],
    this.error,
  });

  final bool loading;
  final bool enabled;
  final List<McpServerSnapshot> servers;
  final List<McpActivityRecord> activity;
  final String? error;

  McpManagementState copyWith({
    bool? loading,
    bool? enabled,
    List<McpServerSnapshot>? servers,
    List<McpActivityRecord>? activity,
    String? error,
    bool clearError = false,
  }) {
    return McpManagementState(
      loading: loading ?? this.loading,
      enabled: enabled ?? this.enabled,
      servers: servers ?? this.servers,
      activity: activity ?? this.activity,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final class McpManagementController extends StateNotifier<McpManagementState> {
  McpManagementController(this._manager) : super(const McpManagementState()) {
    _subscription = _manager.changes.listen((_) => unawaited(_synchronize()));
    unawaited(load());
  }

  final McpClientManager _manager;
  late final StreamSubscription<void> _subscription;
  Future<void>? _loading;

  McpClientManager get manager => _manager;

  Future<void> load() {
    final current = _loading;
    if (current != null) return current;
    final operation = _load();
    _loading = operation;
    return operation.whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      await _manager.initialize();
      await _synchronize();
      state = state.copyWith(loading: false, clearError: true);
    } catch (error) {
      state = state.copyWith(
        loading: false,
        error: sanitizeMcpDiagnostic(error.toString()),
      );
    }
  }

  Future<void> setEnabled(bool enabled) =>
      _run(() => _manager.setEnabled(enabled));

  Future<void> saveServer(
    McpServerConfig config, {
    String? bearerToken,
    bool clearCredential = false,
  }) {
    return _run(() => _manager.upsertServer(
          config,
          bearerToken: bearerToken,
          clearCredential: clearCredential,
        ));
  }

  Future<void> setServerEnabled(String serverId, bool enabled) =>
      _run(() => _manager.setServerEnabled(serverId, enabled));

  Future<void> removeServer(String serverId) =>
      _run(() => _manager.removeServer(serverId));

  Future<void> connect(String serverId) =>
      _run(() => _manager.connect(serverId));

  Future<void> reconnect(String serverId) =>
      _run(() => _manager.reconnect(serverId));

  Future<void> disconnect(String serverId) =>
      _run(() => _manager.disconnect(serverId));

  Future<void> refreshTools(String serverId) =>
      _run(() => _manager.refreshTools(serverId));

  void cancelOperation(String serverId) => _manager.cancelOperation(serverId);

  Future<void> setToolPermission(
    String serverId,
    String toolName,
    McpToolPermission permission,
  ) {
    return _run(
      () => _manager.setToolPermission(serverId, toolName, permission),
    );
  }

  McpToolPermission permissionFor(String serverId, String toolName) =>
      _manager.permissionFor(serverId, toolName);

  bool hasNameCollision(McpToolDescriptor tool) =>
      _manager.hasNameCollision(tool);

  Future<void> refreshActivity() => _synchronize();

  Future<void> _run(Future<void> Function() operation) async {
    state = state.copyWith(clearError: true);
    try {
      await operation();
      await _synchronize();
    } catch (error) {
      await _synchronize();
      state = state.copyWith(error: sanitizeMcpDiagnostic(error.toString()));
      rethrow;
    }
  }

  Future<void> _synchronize() async {
    final activity = await _manager.readRecentActivity(limit: 100);
    if (!mounted) return;
    state = state.copyWith(
      enabled: _manager.enabled,
      servers: _manager.snapshots,
      activity: activity,
    );
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

final mcpManagementProvider =
    StateNotifierProvider<McpManagementController, McpManagementState>((ref) {
  return McpManagementController(ref.watch(mcpClientManagerProvider));
});

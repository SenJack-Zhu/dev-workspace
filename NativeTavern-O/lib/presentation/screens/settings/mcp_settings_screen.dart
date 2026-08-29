import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:native_tavern/domain/services/mcp/mcp_client_manager.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/mcp_providers.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';
import 'package:uuid/uuid.dart';

class McpSettingsScreen extends ConsumerWidget {
  const McpSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(mcpManagementProvider);
    final controller = ref.read(mcpManagementProvider.notifier);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.mcpServers),
          actions: [
            IconButton(
              key: const Key('mcp-add-server'),
              onPressed: () => _editServer(context, controller),
              icon: const Icon(Icons.add),
              tooltip: l10n.mcpAddServer,
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(
                  icon: const Icon(Icons.dns_outlined),
                  text: l10n.mcpServersTab),
              Tab(
                  icon: const Icon(Icons.receipt_long_outlined),
                  text: l10n.mcpActivityTab),
            ],
          ),
        ),
        body: Column(
          children: [
            SwitchListTile(
              key: const Key('mcp-master-toggle'),
              secondary: const Icon(Icons.extension_outlined),
              title: Text(l10n.mcpProtocolName),
              subtitle: Text(state.enabled ? l10n.enabled : l10n.disabled),
              value: state.enabled,
              onChanged: state.loading
                  ? null
                  : (value) => _guard(
                        context,
                        () => controller.setEnabled(value),
                      ),
            ),
            if (state.error != null)
              Container(
                key: const Key('mcp-error-banner'),
                width: double.infinity,
                color: Colors.red.withValues(alpha: 0.12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  state.error!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.red.shade300,
                      ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: state.loading && state.servers.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      children: [
                        _ServerList(
                          state: state,
                          controller: controller,
                        ),
                        _ActivityList(records: state.activity),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editServer(
    BuildContext context,
    McpManagementController controller, [
    McpServerConfig? existing,
  ]) async {
    final result = await showDialog<_McpServerEditResult>(
      context: context,
      builder: (_) => _McpServerEditorDialog(existing: existing),
    );
    if (result == null || !context.mounted) return;
    await _guard(
      context,
      () => controller.saveServer(
        result.config,
        bearerToken: result.bearerToken,
        clearCredential: result.clearCredential,
      ),
    );
  }

  static Future<void> _guard(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(sanitizeMcpDiagnostic(error.toString()))),
      );
    }
  }
}

class _ServerList extends StatelessWidget {
  const _ServerList({required this.state, required this.controller});

  final McpManagementState state;
  final McpManagementController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (state.servers.isEmpty) {
      return _EmptyState(
        icon: Icons.dns_outlined,
        title: l10n.mcpNoServers,
      );
    }
    return RefreshIndicator(
      onRefresh: controller.refreshActivity,
      child: ListView.separated(
        key: const Key('mcp-server-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: state.servers.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          return _ServerTile(
            snapshot: state.servers[index],
            globallyEnabled: state.enabled,
            controller: controller,
          );
        },
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.snapshot,
    required this.globallyEnabled,
    required this.controller,
  });

  final McpServerSnapshot snapshot;
  final bool globallyEnabled;
  final McpManagementController controller;

  bool get _busy =>
      snapshot.status == McpConnectionStatus.connecting ||
      snapshot.status == McpConnectionStatus.reconnecting;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final config = snapshot.config;
    return ExpansionTile(
      key: Key('mcp-server-${config.id}'),
      leading: Icon(
        _statusIcon(snapshot.status),
        color: _statusColor(snapshot.status),
      ),
      title: Text(
        config.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_statusLabel(l10n, snapshot.status)}  ${config.displayEndpoint}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Switch(
        key: Key('mcp-server-toggle-${config.id}'),
        value: config.enabled,
        onChanged: (value) => McpSettingsScreen._guard(
          context,
          () => controller.setServerEnabled(config.id, value),
        ),
      ),
      children: [
        if (snapshot.errorMessage != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.error_outline, color: Colors.red),
            title: Text(snapshot.errorMessage!),
            subtitle: snapshot.errorCode == null
                ? null
                : Text(l10n.mcpErrorCode(snapshot.errorCode!)),
          ),
        if (snapshot.serverImplementation != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.info_outline),
            title: Text(
              '${snapshot.serverImplementation} ${snapshot.serverVersion ?? ''}'
                  .trim(),
            ),
            subtitle: Text(
              l10n.mcpProtocolVersion(
                snapshot.protocolVersion ?? l10n.unknown,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              if (_busy)
                _ActionIcon(
                  key: Key('mcp-cancel-${config.id}'),
                  icon: Icons.stop_circle_outlined,
                  tooltip: l10n.cancel,
                  onPressed: () => controller.cancelOperation(config.id),
                )
              else if (snapshot.isConnected) ...[
                _ActionIcon(
                  key: Key('mcp-disconnect-${config.id}'),
                  icon: Icons.link_off,
                  tooltip: l10n.mcpDisconnect,
                  onPressed: () => McpSettingsScreen._guard(
                    context,
                    () => controller.disconnect(config.id),
                  ),
                ),
                _ActionIcon(
                  key: Key('mcp-refresh-${config.id}'),
                  icon: Icons.refresh,
                  tooltip: l10n.mcpRefreshTools,
                  onPressed: () => McpSettingsScreen._guard(
                    context,
                    () => controller.refreshTools(config.id),
                  ),
                ),
                _ActionIcon(
                  key: Key('mcp-reconnect-${config.id}'),
                  icon: Icons.sync,
                  tooltip: l10n.mcpReconnect,
                  onPressed: () => McpSettingsScreen._guard(
                    context,
                    () => controller.reconnect(config.id),
                  ),
                ),
              ] else
                _ActionIcon(
                  key: Key('mcp-connect-${config.id}'),
                  icon: Icons.link,
                  tooltip: l10n.mcpConnect,
                  onPressed: globallyEnabled && config.enabled
                      ? () => McpSettingsScreen._guard(
                            context,
                            () => controller.connect(config.id),
                          )
                      : null,
                ),
              const Spacer(),
              _ActionIcon(
                key: Key('mcp-edit-${config.id}'),
                icon: Icons.edit_outlined,
                tooltip: l10n.mcpEditServer,
                onPressed: () => _edit(context),
              ),
              _ActionIcon(
                key: Key('mcp-delete-${config.id}'),
                icon: Icons.delete_outline,
                tooltip: l10n.mcpRemoveServer,
                onPressed: () => _remove(context),
              ),
            ],
          ),
        ),
        if (snapshot.isConnected && snapshot.tools.isEmpty)
          ListTile(
            dense: true,
            leading: const Icon(Icons.extension_off_outlined),
            title: Text(l10n.mcpNoToolsDiscovered),
          ),
        ...snapshot.tools.map(
          (tool) => _ToolTile(tool: tool, controller: controller),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context) async {
    final result = await showDialog<_McpServerEditResult>(
      context: context,
      builder: (_) => _McpServerEditorDialog(existing: snapshot.config),
    );
    if (result == null || !context.mounted) return;
    await McpSettingsScreen._guard(
      context,
      () => controller.saveServer(
        result.config,
        bearerToken: result.bearerToken,
        clearCredential: result.clearCredential,
      ),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.mcpRemoveServerQuestion),
        content: Text(snapshot.config.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.mcpRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await McpSettingsScreen._guard(
      context,
      () => controller.removeServer(snapshot.config.id),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.tool, required this.controller});

  final McpToolDescriptor tool;
  final McpManagementController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final permission = controller.permissionFor(tool.serverId, tool.name);
    final collision = controller.hasNameCollision(tool);
    return ListTile(
      key: Key('mcp-tool-${tool.serverId}-${tool.name}'),
      dense: true,
      contentPadding: const EdgeInsets.only(left: 28, right: 8),
      leading: Icon(_accessIcon(tool.accessLevel), size: 20),
      title: Text(
        collision ? '${tool.title} (${tool.qualifiedName})' : tool.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_accessLabel(l10n, tool.accessLevel)}  ${_permissionLabel(l10n, permission)}\n'
        '${tool.description}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<McpToolPermission>(
        key: Key('mcp-permission-${tool.serverId}-${tool.name}'),
        tooltip: l10n.mcpToolPermission,
        initialValue: permission,
        icon: Icon(_permissionIcon(permission)),
        onSelected: (value) => McpSettingsScreen._guard(
          context,
          () => controller.setToolPermission(tool.serverId, tool.name, value),
        ),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: McpToolPermission.askEveryTime,
            child: Row(
              children: [
                const Icon(Icons.help_outline),
                const SizedBox(width: 12),
                Text(l10n.mcpAskEveryTime),
              ],
            ),
          ),
          PopupMenuItem(
            value: McpToolPermission.alwaysAllow,
            child: Row(
              children: [
                const Icon(Icons.verified_user_outlined),
                const SizedBox(width: 12),
                Text(l10n.mcpAlwaysAllow),
              ],
            ),
          ),
          PopupMenuItem(
            value: McpToolPermission.denied,
            child: Row(
              children: [
                const Icon(Icons.block),
                const SizedBox(width: 12),
                Text(l10n.mcpDenied),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.records});

  final List<McpActivityRecord> records;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (records.isEmpty) {
      return _EmptyState(
        icon: Icons.receipt_long_outlined,
        title: l10n.mcpNoActivity,
      );
    }
    return ListView.separated(
      key: const Key('mcp-activity-list'),
      itemCount: records.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final record = records[index];
        return ListTile(
          dense: true,
          leading: Icon(_activityIcon(record.kind), size: 20),
          title: Text(
            record.message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${record.serverId}${record.toolName == null ? '' : '  ${record.toolName}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            _timeLabel(record.timestamp.toLocal()),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textMuted,
                ),
          ),
        );
      },
    );
  }
}

class _McpServerEditorDialog extends StatefulWidget {
  const _McpServerEditorDialog({this.existing});

  final McpServerConfig? existing;

  @override
  State<_McpServerEditorDialog> createState() => _McpServerEditorDialogState();
}

class _McpServerEditorDialogState extends State<_McpServerEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _endpointController;
  late final TextEditingController _tokenController;
  late McpTransportType _transport;
  late bool _enabled;
  late bool _allowInsecure;
  bool _clearCredential = false;
  bool _obscureToken = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _endpointController =
        TextEditingController(text: existing?.endpoint.toString() ?? '');
    _tokenController = TextEditingController();
    _transport = existing?.transport ?? McpTransportType.streamableHttp;
    _enabled = existing?.enabled ?? false;
    _allowInsecure = existing?.allowInsecureHttp ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _endpointController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(
        widget.existing == null ? l10n.mcpAddServer : l10n.mcpEditServer,
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('mcp-server-name'),
                controller: _nameController,
                decoration: InputDecoration(labelText: l10n.name),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('mcp-server-endpoint'),
                controller: _endpointController,
                decoration: InputDecoration(labelText: l10n.mcpEndpoint),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<McpTransportType>(
                key: const Key('mcp-server-transport'),
                initialValue: _transport,
                decoration: InputDecoration(labelText: l10n.mcpTransport),
                items: [
                  DropdownMenuItem(
                    value: McpTransportType.streamableHttp,
                    child: Text(l10n.mcpStreamableHttp),
                  ),
                  DropdownMenuItem(
                    value: McpTransportType.legacySse,
                    child: Text(l10n.mcpLegacyHttpSse),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _transport = value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('mcp-server-token'),
                controller: _tokenController,
                obscureText: _obscureToken,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.mcpBearerToken,
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => _obscureToken = !_obscureToken),
                    icon: Icon(
                      _obscureToken ? Icons.visibility : Icons.visibility_off,
                    ),
                    tooltip:
                        _obscureToken ? l10n.mcpShowToken : l10n.mcpHideToken,
                  ),
                ),
              ),
              if (widget.existing != null)
                CheckboxListTile(
                  key: const Key('mcp-clear-token'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.mcpRemoveStoredToken),
                  value: _clearCredential,
                  onChanged: (value) =>
                      setState(() => _clearCredential = value ?? false),
                ),
              SwitchListTile(
                key: const Key('mcp-allow-insecure'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.mcpAllowInsecureHttp),
                value: _allowInsecure,
                onChanged: (value) => setState(() => _allowInsecure = value),
              ),
              SwitchListTile(
                key: const Key('mcp-server-enabled'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.mcpServerEnabled),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              if (_error != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(color: Colors.red.shade300),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('mcp-save-server'),
          onPressed: _submit,
          child: Text(l10n.save),
        ),
      ],
    );
  }

  void _submit() {
    try {
      final config = McpServerConfig(
        id: widget.existing?.id ?? const Uuid().v4(),
        name: _nameController.text,
        endpoint: Uri.parse(_endpointController.text.trim()),
        transport: _transport,
        enabled: _enabled,
        allowInsecureHttp: _allowInsecure,
        connectTimeout:
            widget.existing?.connectTimeout ?? const Duration(seconds: 15),
        requestTimeout:
            widget.existing?.requestTimeout ?? const Duration(seconds: 30),
      );
      Navigator.pop(
        context,
        _McpServerEditResult(
          config: config,
          bearerToken: _tokenController.text.trim().isEmpty
              ? null
              : _tokenController.text,
          clearCredential: _clearCredential,
        ),
      );
    } catch (error) {
      setState(() => _error = sanitizeMcpDiagnostic(error.toString()));
    }
  }
}

final class _McpServerEditResult {
  const _McpServerEditResult({
    required this.config,
    required this.bearerToken,
    required this.clearCredential,
  });

  final McpServerConfig config;
  final String? bearerToken;
  final bool clearCredential;
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 42,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon),
        tooltip: tooltip,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

IconData _statusIcon(McpConnectionStatus status) => switch (status) {
      McpConnectionStatus.disabled => Icons.pause_circle_outline,
      McpConnectionStatus.disconnected => Icons.link_off,
      McpConnectionStatus.connecting => Icons.pending_outlined,
      McpConnectionStatus.connected => Icons.check_circle_outline,
      McpConnectionStatus.reconnecting => Icons.sync,
      McpConnectionStatus.error => Icons.error_outline,
    };

Color _statusColor(McpConnectionStatus status) => switch (status) {
      McpConnectionStatus.connected => Colors.green,
      McpConnectionStatus.error => Colors.red,
      McpConnectionStatus.connecting ||
      McpConnectionStatus.reconnecting =>
        Colors.orange,
      _ => AppTheme.textMuted,
    };

String _statusLabel(AppLocalizations l10n, McpConnectionStatus status) =>
    switch (status) {
      McpConnectionStatus.disabled => l10n.disabled,
      McpConnectionStatus.disconnected => l10n.mcpDisconnected,
      McpConnectionStatus.connecting => l10n.mcpConnecting,
      McpConnectionStatus.connected => l10n.mcpConnected,
      McpConnectionStatus.reconnecting => l10n.mcpReconnecting,
      McpConnectionStatus.error => l10n.error,
    };

IconData _accessIcon(ToolAccessLevel access) => switch (access) {
      ToolAccessLevel.readOnly => Icons.visibility_outlined,
      ToolAccessLevel.write => Icons.edit_note_outlined,
      ToolAccessLevel.externalSideEffect => Icons.public_outlined,
    };

String _accessLabel(AppLocalizations l10n, ToolAccessLevel access) =>
    switch (access) {
      ToolAccessLevel.readOnly => l10n.mcpReadOnlyHint,
      ToolAccessLevel.write => l10n.mcpWriteCapable,
      ToolAccessLevel.externalSideEffect => l10n.mcpExternalSideEffect,
    };

IconData _permissionIcon(McpToolPermission permission) => switch (permission) {
      McpToolPermission.askEveryTime => Icons.help_outline,
      McpToolPermission.alwaysAllow => Icons.verified_user_outlined,
      McpToolPermission.denied => Icons.block,
    };

String _permissionLabel(AppLocalizations l10n, McpToolPermission permission) =>
    switch (permission) {
      McpToolPermission.askEveryTime => l10n.mcpAskEveryTime,
      McpToolPermission.alwaysAllow => l10n.mcpAlwaysAllow,
      McpToolPermission.denied => l10n.mcpDenied,
    };

IconData _activityIcon(McpActivityKind kind) => switch (kind) {
      McpActivityKind.configured => Icons.settings_outlined,
      McpActivityKind.connected => Icons.link,
      McpActivityKind.disconnected => Icons.link_off,
      McpActivityKind.discovery => Icons.manage_search,
      McpActivityKind.permission => Icons.shield_outlined,
      McpActivityKind.error => Icons.error_outline,
      McpActivityKind.cancelled => Icons.cancel_outlined,
    };

String _timeLabel(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.month)}/${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

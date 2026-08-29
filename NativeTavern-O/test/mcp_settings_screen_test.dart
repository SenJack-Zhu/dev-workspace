import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/repositories/mcp_repository.dart';
import 'package:native_tavern/domain/services/mcp/mcp_client_manager.dart';
import 'package:native_tavern/domain/services/mcp/mcp_protocol_client.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_execution_audit_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/mcp_providers.dart';
import 'package:native_tavern/presentation/screens/settings/mcp_settings_screen.dart';

void main() {
  testWidgets('manages a server, connection, permissions, and activity',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final credentials = MemoryMcpCredentialRepository();
    final factory = _WidgetProtocolFactory();
    final manager = McpClientManager(
      settingsRepository: MemoryMcpSettingsRepository(),
      credentialRepository: credentials,
      activityRepository: MemoryMcpActivityRepository(),
      toolAuditRepository: MemoryToolExecutionAuditRepository(),
      protocolClientFactory: factory,
    );
    addTearDown(manager.close);

    await tester.pumpWidget(ProviderScope(
      overrides: [mcpClientManagerProvider.overrideWithValue(manager)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: McpSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(factory.connectCount, 0);
    expect(find.text('No MCP servers'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'initial layout');
    await tester.tap(find.byKey(const Key('mcp-master-toggle')));
    await tester.pumpAndSettle();
    expect(manager.enabled, isTrue);
    expect(tester.takeException(), isNull, reason: 'master toggle');

    await tester.tap(find.byKey(const Key('mcp-add-server')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'editor dialog');
    await tester.enterText(
      find.byKey(const Key('mcp-server-name')),
      'Test MCP',
    );
    await tester.enterText(
      find.byKey(const Key('mcp-server-endpoint')),
      'http://localhost:7777/mcp',
    );
    await tester.enterText(
      find.byKey(const Key('mcp-server-token')),
      'widget-secret',
    );
    await tester.tap(find.byKey(const Key('mcp-server-enabled')));
    expect(tester.takeException(), isNull, reason: 'editor values');
    await tester.tap(find.byKey(const Key('mcp-save-server')));
    await tester.pumpAndSettle();

    final serverId = manager.servers.single.id;
    expect(find.text('Test MCP'), findsOneWidget);
    expect(await credentials.readToken(serverId), 'widget-secret');
    expect(find.text('widget-secret'), findsNothing);
    expect(tester.takeException(), isNull, reason: 'server list');
    await tester.tap(find.text('Test MCP'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'expanded server');

    await tester.tap(find.byKey(Key('mcp-connect-$serverId')));
    await tester.pumpAndSettle();

    expect(factory.connectCount, 1);
    expect(factory.lastToken, 'widget-secret');
    expect(find.textContaining('Connected'), findsWidgets);
    expect(find.text('Echo'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'connected tools');
    final permissionButton = find.byKey(Key('mcp-permission-$serverId-echo'));
    await tester.tap(permissionButton);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'permission menu');
    await tester.tap(find.text('Always allow').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'always permission');
    expect(
      manager.permissionFor(serverId, 'echo'),
      McpToolPermission.alwaysAllow,
    );

    await tester.tap(permissionButton);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'permission menu second');
    await tester.tap(find.text('Denied').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'denied permission');
    expect(
      manager.permissionFor(serverId, 'echo'),
      McpToolPermission.denied,
    );

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mcp-activity-list')), findsOneWidget);
    expect(find.textContaining('Connected and discovered'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows and cancels an in-flight connection', (tester) async {
    final settings = MemoryMcpSettingsRepository(McpStoredSettings(
      enabled: true,
      servers: [_config('blocked')],
    ));
    final factory = _WidgetProtocolFactory(blockConnection: true);
    final manager = McpClientManager(
      settingsRepository: settings,
      credentialRepository: MemoryMcpCredentialRepository(),
      activityRepository: MemoryMcpActivityRepository(),
      toolAuditRepository: MemoryToolExecutionAuditRepository(),
      protocolClientFactory: factory,
    );
    addTearDown(manager.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [mcpClientManagerProvider.overrideWithValue(manager)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: McpSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Server blocked'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mcp-connect-blocked')));
    await factory.started.future;
    await tester.pump();
    expect(find.byKey(const Key('mcp-cancel-blocked')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mcp-cancel-blocked')));
    await tester.pumpAndSettle();

    expect(
      manager.snapshot('blocked').status,
      McpConnectionStatus.disconnected,
    );
    expect(tester.takeException(), isNull);
  });
}

McpServerConfig _config(String id) => McpServerConfig(
      id: id,
      name: 'Server $id',
      endpoint: Uri.parse('http://localhost:7777/mcp'),
      enabled: true,
    );

final class _WidgetProtocolFactory implements McpProtocolClientFactory {
  _WidgetProtocolFactory({this.blockConnection = false});

  final bool blockConnection;
  final Completer<void> started = Completer<void>();
  int connectCount = 0;
  String? lastToken;

  @override
  Future<McpProtocolSession> connect({
    required McpServerConfig config,
    required String? bearerToken,
    required ToolCancellationToken cancellationToken,
    required McpToolsChangedCallback onToolsChanged,
    required McpProtocolErrorCallback onError,
  }) async {
    connectCount++;
    lastToken = bearerToken;
    if (blockConnection) {
      if (!started.isCompleted) started.complete();
      final cancelled = Completer<void>();
      cancellationToken.whenCancelled((_) {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      await cancelled.future;
      throw const McpException('cancelled', 'Connection cancelled.');
    }
    return _WidgetProtocolSession(config.id);
  }
}

final class _WidgetProtocolSession implements McpProtocolSession {
  _WidgetProtocolSession(this.serverId);

  final String serverId;

  @override
  String get protocolVersion => '2026-07-28';

  @override
  String get serverImplementation => 'Widget MCP';

  @override
  String get serverVersion => '1.0.0';

  @override
  Future<List<McpToolDescriptor>> listTools({
    required ToolCancellationToken cancellationToken,
    required Duration timeout,
  }) async {
    return [
      McpToolDescriptor(
        serverId: serverId,
        name: 'echo',
        title: 'Echo',
        description: 'Echo test tool',
        inputSchema: const {'type': 'object'},
        accessLevel: ToolAccessLevel.readOnly,
        destructiveHint: false,
        openWorldHint: false,
      ),
    ];
  }

  @override
  Future<Map<String, dynamic>> callTool({
    required String name,
    required Map<String, dynamic> arguments,
    required ToolCancellationToken cancellationToken,
    required Duration timeout,
  }) async {
    return const {
      'content': [
        {'type': 'text', 'text': 'ok'},
      ],
    };
  }

  @override
  Future<void> close() async {}
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/repositories/mcp_repository.dart';
import 'package:native_tavern/domain/services/mcp/mcp_client_manager.dart';
import 'package:native_tavern/domain/services/mcp/mcp_protocol_client.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_execution_audit_service.dart';

void main() {
  group('MCP configuration', () {
    test('rejects credentials in URLs and requires explicit insecure approval',
        () {
      expect(
        () => McpServerConfig(
          id: 'server',
          name: 'Server',
          endpoint: Uri.parse('https://token@example.com/mcp'),
        ),
        throwsA(isA<McpException>()),
      );
      expect(
        () => McpServerConfig(
          id: 'server',
          name: 'Server',
          endpoint: Uri.parse('https://example.com/mcp?token=secret'),
        ),
        throwsA(isA<McpException>()),
      );
      expect(
        () => McpServerConfig(
          id: 'server',
          name: 'Server',
          endpoint: Uri.parse('http://192.168.1.4/mcp'),
        ),
        throwsA(
          isA<McpException>().having(
            (error) => error.code,
            'code',
            'insecure_endpoint',
          ),
        ),
      );
      expect(
        McpServerConfig(
          id: 'server',
          name: 'Server',
          endpoint: Uri.parse('http://192.168.1.4/mcp'),
          allowInsecureHttp: true,
        ).displayEndpoint,
        'http://192.168.1.4/mcp',
      );
      expect(
        McpServerConfig(
          id: 'server',
          name: 'Server',
          endpoint: Uri.parse('https://example.com/mcp?tenant=private'),
        ).displayEndpoint,
        'https://example.com/mcp',
      );
      expect(
        () => McpServerConfig(
          id: 'server',
          name: 'Server',
          endpoint: Uri.parse('https://example.com/mcp'),
          requestTimeout: Duration.zero,
        ),
        throwsA(
          isA<McpException>().having(
            (error) => error.code,
            'code',
            'invalid_request_timeout',
          ),
        ),
      );
    });

    test('persists settings atomically without storing credentials', () async {
      final directory = await Directory.systemTemp.createTemp('mcp-settings-');
      addTearDown(() => directory.delete(recursive: true));
      final repository = FileMcpSettingsRepository(dataPath: directory.path);
      final credentialRepository = MemoryMcpCredentialRepository();
      final config = _config('one');

      await repository.save(McpStoredSettings(
        enabled: true,
        servers: [config],
        permissions: const [
          McpToolPermissionRecord(
            serverId: 'one',
            toolName: 'search',
            permission: McpToolPermission.alwaysAllow,
          ),
        ],
      ));
      await credentialRepository.writeToken('one', 'super-secret-token');

      final file = File('${directory.path}/mcp/settings.json');
      final source = await file.readAsString();
      expect(source, isNot(contains('super-secret-token')));
      final restored = await repository.load();
      expect(restored.enabled, isTrue);
      expect(restored.servers.single.id, 'one');
      expect(
        restored.permissions.single.permission,
        McpToolPermission.alwaysAllow,
      );
    });
  });

  group('McpClientManager', () {
    late MemoryMcpSettingsRepository settings;
    late MemoryMcpCredentialRepository credentials;
    late MemoryMcpActivityRepository activity;
    late MemoryToolExecutionAuditRepository toolAudit;
    late _FakeProtocolFactory factory;
    late McpClientManager manager;

    setUp(() {
      settings = MemoryMcpSettingsRepository();
      credentials = MemoryMcpCredentialRepository();
      activity = MemoryMcpActivityRepository();
      toolAudit = MemoryToolExecutionAuditRepository();
      factory = _FakeProtocolFactory();
      manager = McpClientManager(
        settingsRepository: settings,
        credentialRepository: credentials,
        activityRepository: activity,
        toolAuditRepository: toolAudit,
        protocolClientFactory: factory,
      );
      addTearDown(manager.close);
    });

    test('never connects in the background after loading enabled settings',
        () async {
      settings.value = McpStoredSettings(
        enabled: true,
        servers: [_config('one')],
      );

      await manager.initialize();

      expect(factory.connectCount, 0);
      expect(manager.snapshot('one').status, McpConnectionStatus.disconnected);
    });

    test(
        'connects explicitly, discovers tools, refreshes changes, and reconnects',
        () async {
      final first = _FakeProtocolSession(tools: [_tool('one', 'search')]);
      final second = _FakeProtocolSession(
        tools: [_tool('one', 'search'), _tool('one', 'write_note')],
      );
      factory.sessions.addAll([first, second]);
      await manager.upsertServer(_config('one'), bearerToken: 'secret-token');
      await manager.setEnabled(true);

      await manager.connect('one');

      expect(factory.connectCount, 1);
      expect(factory.tokens.single, 'secret-token');
      expect(manager.snapshot('one').isConnected, isTrue);
      expect(
          manager.snapshot('one').tools.map((tool) => tool.name), ['search']);
      first.tools = [_tool('one', 'search'), _tool('one', 'new_tool')];
      await factory.triggerToolsChanged('one');
      expect(
        manager.snapshot('one').tools.map((tool) => tool.name),
        ['search', 'new_tool'],
      );

      await manager.reconnect('one');

      expect(first.closed, isTrue);
      expect(factory.connectCount, 2);
      expect(manager.snapshot('one').tools, hasLength(2));
      expect(
        activity.records.map((record) => record.message).join(' '),
        isNot(contains('secret-token')),
      );
    });

    test('detects tool name collisions across connected servers', () async {
      factory.sessions.addAll([
        _FakeProtocolSession(tools: [_tool('one', 'search')]),
        _FakeProtocolSession(tools: [_tool('two', 'search')]),
      ]);
      await manager.upsertServer(_config('one'));
      await manager.upsertServer(_config('two'));
      await manager.setEnabled(true);
      await manager.connect('one');
      await manager.connect('two');

      final tools = manager.discoveredTools;
      expect(tools, hasLength(2));
      expect(tools.every(manager.hasNameCollision), isTrue);
      expect(tools.map((tool) => tool.qualifiedName).toSet(), hasLength(2));
      expect(tools.every((tool) => tool.qualifiedName.length <= 64), isTrue);
      final punctuationNames = [
        _tool('one', 'read.value'),
        _tool('one', 'read/value'),
      ];
      expect(
        punctuationNames.map((tool) => tool.qualifiedName).toSet(),
        hasLength(2),
      );
    });

    test('cancels an in-flight connection and releases session state',
        () async {
      factory.blockConnections = true;
      await manager.upsertServer(_config('one'));
      await manager.setEnabled(true);
      final connecting = manager.connect('one');
      await factory.connectStarted.future;

      manager.cancelOperation('one');

      await expectLater(connecting, throwsA(isA<McpException>()));
      expect(manager.snapshot('one').status, McpConnectionStatus.disconnected);
      expect(manager.snapshot('one').tools, isEmpty);
      expect(activity.records.last.kind, McpActivityKind.cancelled);
    });

    test('supports one-time, permanent, revoked, and cancelled tool access',
        () async {
      final session = _FakeProtocolSession(tools: [_tool('one', 'search')]);
      factory.sessions.add(session);
      await manager.upsertServer(_config('one'));
      await manager.setEnabled(true);
      await manager.connect('one');
      final call = ToolCall.ready(
        id: 'call-1',
        name: session.tools.single.qualifiedName,
        arguments: const {'query': 'private text'},
        rawArguments: '{"query":"private text"}',
      );

      var result = await manager.executeTool(
        serverId: 'one',
        call: call,
        invocationContext: _context(),
      );
      expect(result.status, ToolResultStatus.failed);
      expect(session.callCount, 0);

      result = await manager.executeTool(
        serverId: 'one',
        call: call,
        invocationContext: _context(),
        requestApproval: (_) async => McpApprovalDecision.cancel,
      );
      expect(result.status, ToolResultStatus.cancelled);
      expect(session.callCount, 0);

      result = await manager.executeTool(
        serverId: 'one',
        call: call,
        invocationContext: _context(),
        requestApproval: (_) async => McpApprovalDecision.allowOnce,
      );
      expect(result.status, ToolResultStatus.succeeded);
      expect(session.callCount, 1);
      expect(
        manager.permissionFor('one', 'search'),
        McpToolPermission.askEveryTime,
      );

      result = await manager.executeTool(
        serverId: 'one',
        call: call,
        invocationContext: _context(),
        requestApproval: (_) async => McpApprovalDecision.alwaysAllow,
      );
      expect(result.status, ToolResultStatus.succeeded);
      expect(
        manager.permissionFor('one', 'search'),
        McpToolPermission.alwaysAllow,
      );
      await manager.executeTool(
        serverId: 'one',
        call: call,
        invocationContext: _context(),
      );
      expect(session.callCount, 3);

      await manager.setToolPermission(
        'one',
        'search',
        McpToolPermission.askEveryTime,
      );
      result = await manager.executeTool(
        serverId: 'one',
        call: call,
        invocationContext: _context(),
      );
      expect(result.status, ToolResultStatus.failed);
      expect(session.callCount, 3);

      await manager.setToolPermission(
        'one',
        'search',
        McpToolPermission.denied,
      );
      result = await manager.executeTool(
        serverId: 'one',
        call: call,
        invocationContext: _context(),
      );
      expect(result.status, ToolResultStatus.failed);
      expect(session.callCount, 3);
      final audits = await toolAudit.readRecent(limit: 10);
      expect(audits, hasLength(7));
      expect(
        audits[4].parameterSummary['query'],
        isNot('private text'),
      );
    });

    test('propagates cancellation into an in-flight remote tool call',
        () async {
      final session = _FakeProtocolSession(
        tools: [_tool('one', 'search')],
        blockCalls: true,
      );
      factory.sessions.add(session);
      await manager.upsertServer(_config('one'));
      await manager.setEnabled(true);
      await manager.connect('one');
      await manager.setToolPermission(
        'one',
        'search',
        McpToolPermission.alwaysAllow,
      );
      final cancellation = ToolCancellationController();
      final execution = manager.executeTool(
        serverId: 'one',
        call: ToolCall.ready(
          id: 'call-cancel',
          name: 'search',
          arguments: const {},
          rawArguments: '{}',
        ),
        invocationContext: ToolInvocationContext(
          maxDepth: 2,
          cancellationToken: cancellation.token,
        ),
      );
      await session.callStarted.future;

      cancellation.cancel('Stop');
      final result = await execution;

      expect(result.status, ToolResultStatus.cancelled);
      expect(
        (await toolAudit.readRecent(limit: 1)).single.result,
        ToolExecutionOutcome.cancelled,
      );
    });

    test(
        'disabling MCP closes sessions and removing a server deletes its token',
        () async {
      final session = _FakeProtocolSession(tools: [_tool('one', 'search')]);
      factory.sessions.add(session);
      await manager.upsertServer(_config('one'), bearerToken: 'secret');
      await manager.setEnabled(true);
      await manager.connect('one');

      await manager.setEnabled(false);
      expect(session.closed, isTrue);
      expect(manager.snapshot('one').status, McpConnectionStatus.disabled);

      await manager.removeServer('one');
      expect(await credentials.readToken('one'), isNull);
      expect(manager.servers, isEmpty);
    });
  });
}

McpServerConfig _config(String id) => McpServerConfig(
      id: id,
      name: 'Server $id',
      endpoint: Uri.parse('http://localhost:9000/mcp'),
      enabled: true,
    );

McpToolDescriptor _tool(String serverId, String name) => McpToolDescriptor(
      serverId: serverId,
      name: name,
      title: name,
      description: 'Test tool',
      inputSchema: const {'type': 'object'},
      accessLevel: ToolAccessLevel.externalSideEffect,
      destructiveHint: true,
      openWorldHint: true,
    );

ToolInvocationContext _context() => ToolInvocationContext(
      maxDepth: 2,
      cancellationToken: ToolCancellationController().token,
    );

final class _FakeProtocolFactory implements McpProtocolClientFactory {
  final List<_FakeProtocolSession> sessions = [];
  final List<String?> tokens = [];
  final Map<String, McpToolsChangedCallback> changedCallbacks = {};
  final Completer<void> connectStarted = Completer<void>();
  int connectCount = 0;
  bool blockConnections = false;

  @override
  Future<McpProtocolSession> connect({
    required McpServerConfig config,
    required String? bearerToken,
    required ToolCancellationToken cancellationToken,
    required McpToolsChangedCallback onToolsChanged,
    required McpProtocolErrorCallback onError,
  }) async {
    connectCount++;
    tokens.add(bearerToken);
    changedCallbacks[config.id] = onToolsChanged;
    if (blockConnections) {
      if (!connectStarted.isCompleted) connectStarted.complete();
      final cancelled = Completer<void>();
      cancellationToken.whenCancelled((_) {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      await cancelled.future;
      throw const McpException('cancelled', 'Connection cancelled.');
    }
    if (sessions.isEmpty) {
      throw StateError('No fake session queued.');
    }
    return sessions.removeAt(0);
  }

  Future<void> triggerToolsChanged(String serverId) async {
    await changedCallbacks[serverId]!();
  }
}

final class _FakeProtocolSession implements McpProtocolSession {
  _FakeProtocolSession({
    required this.tools,
    this.blockCalls = false,
  });

  List<McpToolDescriptor> tools;
  final bool blockCalls;
  final Completer<void> callStarted = Completer<void>();
  bool closed = false;
  int callCount = 0;

  @override
  String get protocolVersion => '2026-07-28';

  @override
  String get serverImplementation => 'Fake MCP';

  @override
  String get serverVersion => '1.0.0';

  @override
  Future<List<McpToolDescriptor>> listTools({
    required ToolCancellationToken cancellationToken,
    required Duration timeout,
  }) async {
    cancellationToken.throwIfCancelled();
    return List.unmodifiable(tools);
  }

  @override
  Future<Map<String, dynamic>> callTool({
    required String name,
    required Map<String, dynamic> arguments,
    required ToolCancellationToken cancellationToken,
    required Duration timeout,
  }) async {
    callCount++;
    if (blockCalls) {
      if (!callStarted.isCompleted) callStarted.complete();
      final cancelled = Completer<void>();
      cancellationToken.whenCancelled((_) {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      await cancelled.future;
      throw const McpException('cancelled', 'Tool call cancelled.');
    }
    return {
      'content': [
        {'type': 'text', 'text': 'ok'},
      ],
    };
  }

  @override
  Future<void> close() async => closed = true;
}

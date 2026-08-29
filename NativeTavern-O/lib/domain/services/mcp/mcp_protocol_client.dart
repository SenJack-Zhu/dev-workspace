import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart' as sdk;
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';

typedef McpToolsChangedCallback = FutureOr<void> Function();
typedef McpProtocolErrorCallback = void Function(Object error);

abstract interface class McpProtocolSession {
  String? get serverImplementation;
  String? get serverVersion;
  String? get protocolVersion;

  Future<List<McpToolDescriptor>> listTools({
    required ToolCancellationToken cancellationToken,
    required Duration timeout,
  });

  Future<Map<String, dynamic>> callTool({
    required String name,
    required Map<String, dynamic> arguments,
    required ToolCancellationToken cancellationToken,
    required Duration timeout,
  });

  Future<void> close();
}

abstract interface class McpProtocolClientFactory {
  Future<McpProtocolSession> connect({
    required McpServerConfig config,
    required String? bearerToken,
    required ToolCancellationToken cancellationToken,
    required McpToolsChangedCallback onToolsChanged,
    required McpProtocolErrorCallback onError,
  });
}

final class McpDartProtocolClientFactory implements McpProtocolClientFactory {
  const McpDartProtocolClientFactory();

  @override
  Future<McpProtocolSession> connect({
    required McpServerConfig config,
    required String? bearerToken,
    required ToolCancellationToken cancellationToken,
    required McpToolsChangedCallback onToolsChanged,
    required McpProtocolErrorCallback onError,
  }) async {
    cancellationToken.throwIfCancelled();
    final client = sdk.McpClient(
      const sdk.Implementation(
        name: 'NativeTavern',
        version: '0.1.9',
      ),
      options: sdk.McpClientOptions(
        protocol: config.transport == McpTransportType.legacySse
            ? sdk.McpProtocol.legacy
            : sdk.McpProtocol.stable,
      ),
    );
    client.onerror = onError;
    client.setNotificationHandler<sdk.JsonRpcToolListChangedNotification>(
      sdk.Method.notificationsToolsListChanged,
      (_) async => onToolsChanged(),
      (params, meta) => sdk.JsonRpcToolListChangedNotification.fromJson({
        'jsonrpc': sdk.jsonRpcVersion,
        'method': sdk.Method.notificationsToolsListChanged,
        if (params != null) 'params': params,
        if (meta != null) '_meta': meta,
      }),
    );

    final headers = <String, dynamic>{
      if (bearerToken?.trim().isNotEmpty == true)
        'Authorization': 'Bearer ${bearerToken!.trim()}',
    };
    final sdk.Transport transport;
    if (config.transport == McpTransportType.legacySse) {
      // ignore: deprecated_member_use
      transport = sdk.SseClientTransport(
        config.endpoint,
        // ignore: deprecated_member_use
        opts: sdk.SseClientTransportOptions(
          headers: headers.map((key, value) => MapEntry(key, '$value')),
        ),
      );
    } else {
      transport = sdk.StreamableHttpClientTransport(
        config.endpoint,
        opts: sdk.StreamableHttpClientTransportOptions(
          requestInit: headers.isEmpty ? null : {'headers': headers},
          reconnectionOptions: const sdk.StreamableHttpReconnectionOptions(
            initialReconnectionDelay: 500,
            maxReconnectionDelay: 10000,
            reconnectionDelayGrowFactor: 1.8,
            maxRetries: 4,
          ),
        ),
      );
    }

    var cancelled = false;
    cancellationToken.whenCancelled((reason) {
      cancelled = true;
      unawaited(client.close());
    });
    try {
      await client.connect(transport).timeout(config.connectTimeout);
      if (cancelled) {
        throw McpException(
          'cancelled',
          cancellationToken.reason?.toString() ?? 'Connection cancelled.',
        );
      }
      return _McpDartProtocolSession(config.id, client);
    } on TimeoutException {
      await client.close();
      if (cancelled || cancellationToken.isCancelled) {
        throw McpException(
          'cancelled',
          cancellationToken.reason?.toString() ?? 'Connection cancelled.',
        );
      }
      throw McpException(
        'connection_timeout',
        'Connection timed out after ${config.connectTimeout.inSeconds} seconds.',
      );
    } catch (_) {
      await client.close();
      if (cancelled || cancellationToken.isCancelled) {
        throw McpException(
          'cancelled',
          cancellationToken.reason?.toString() ?? 'Connection cancelled.',
        );
      }
      rethrow;
    }
  }
}

final class _McpDartProtocolSession implements McpProtocolSession {
  _McpDartProtocolSession(this.serverId, this._client);

  final String serverId;
  final sdk.McpClient _client;
  bool _closed = false;

  @override
  String? get serverImplementation => _client.getServerVersion()?.name;

  @override
  String? get serverVersion => _client.getServerVersion()?.version;

  @override
  String? get protocolVersion => _client.getProtocolVersion();

  @override
  Future<List<McpToolDescriptor>> listTools({
    required ToolCancellationToken cancellationToken,
    required Duration timeout,
  }) async {
    _requireOpen();
    final abort = _abortFor(cancellationToken);
    final tools = <McpToolDescriptor>[];
    final cursors = <String>{};
    String? cursor;
    for (var page = 0; page < 100; page++) {
      final result = await _client.listTools(
        params: cursor == null ? null : sdk.ListToolsRequest(cursor: cursor),
        options: sdk.RequestOptions(
          signal: abort.signal,
          timeout: timeout,
          maxTotalTimeout: timeout,
        ),
      );
      tools.addAll(result.tools.map(_mapTool));
      final next = result.nextCursor;
      if (next == null) return List.unmodifiable(tools);
      if (!cursors.add(next)) {
        throw const McpException(
          'repeated_cursor',
          'The server repeated a tools/list cursor.',
        );
      }
      cursor = next;
    }
    throw const McpException(
      'pagination_limit',
      'Tool discovery exceeded 100 pages.',
    );
  }

  @override
  Future<Map<String, dynamic>> callTool({
    required String name,
    required Map<String, dynamic> arguments,
    required ToolCancellationToken cancellationToken,
    required Duration timeout,
  }) async {
    _requireOpen();
    final abort = _abortFor(cancellationToken);
    final result = await _client.callTool(
      sdk.CallToolRequest(name: name, arguments: arguments),
      options: sdk.RequestOptions(
        signal: abort.signal,
        timeout: timeout,
        maxTotalTimeout: timeout,
      ),
    );
    return Map<String, dynamic>.from(result.toJson());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _client.close();
  }

  void _requireOpen() {
    if (_closed || !_client.isConnected) {
      throw const McpException(
        'not_connected',
        'The MCP server is not connected.',
      );
    }
  }

  sdk.BasicAbortController _abortFor(ToolCancellationToken token) {
    token.throwIfCancelled();
    final controller = sdk.BasicAbortController();
    token.whenCancelled(controller.abort);
    return controller;
  }

  McpToolDescriptor _mapTool(sdk.Tool tool) {
    final annotations = tool.annotations;
    final readOnly = annotations?.readOnlyHint == true;
    final openWorld = annotations?.openWorldHint ?? true;
    final accessLevel = readOnly
        ? ToolAccessLevel.readOnly
        : openWorld
            ? ToolAccessLevel.externalSideEffect
            : ToolAccessLevel.write;
    return McpToolDescriptor(
      serverId: serverId,
      name: tool.name,
      title: tool.title ?? annotations?.title ?? tool.name,
      description: tool.description?.trim().isNotEmpty == true
          ? tool.description!.trim()
          : 'No description provided by the server.',
      inputSchema: tool.inputSchema.toJson(),
      accessLevel: accessLevel,
      destructiveHint: annotations?.destructiveHint ?? true,
      openWorldHint: openWorld,
    );
  }
}

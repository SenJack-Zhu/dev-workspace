import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/mcp/mcp_protocol_client.dart';

void main() {
  test('real Streamable HTTP handshake, discovery, call, cancel, and reconnect',
      () async {
    const bearerToken = 'test-bearer-token';
    final slowStarted = Completer<void>();
    var authenticatedRequests = 0;
    final server = sdk.StreamableMcpServer(
      host: 'localhost',
      port: 0,
      authenticator: (request) {
        final accepted =
            request.headers.value(HttpHeaders.authorizationHeader) ==
                'Bearer $bearerToken';
        if (accepted) authenticatedRequests++;
        return accepted;
      },
      serverFactory: (_) {
        final mcp = sdk.McpServer(
          const sdk.Implementation(
            name: 'NativeTavern MCP Test',
            version: '1.2.3',
          ),
          options: const sdk.McpServerOptions(protocol: sdk.McpProtocol.stable),
        );
        mcp.registerTool(
          'echo',
          title: 'Echo',
          description: 'Returns the supplied text.',
          inputSchema: sdk.JsonSchema.object(
            properties: {'text': sdk.JsonSchema.string()},
            required: ['text'],
          ),
          annotations: const sdk.ToolAnnotations(
            readOnlyHint: true,
            destructiveHint: false,
            openWorldHint: false,
          ),
          callback: (arguments, _) async => sdk.CallToolResult.fromContent([
            sdk.TextContent(text: arguments['text'] as String),
          ]),
        );
        mcp.registerTool(
          'slow',
          description: 'Waits until the client cancels.',
          callback: (_, extra) async {
            if (!slowStarted.isCompleted) slowStarted.complete();
            await extra.signal.onAbort.first
                .timeout(const Duration(seconds: 5));
            return const sdk.CallToolResult(content: []);
          },
        );
        return mcp;
      },
    );
    await server.start();
    addTearDown(server.stop);
    final config = McpServerConfig(
      id: 'real',
      name: 'Real test server',
      endpoint: Uri.parse(
        'http://localhost:${server.boundPort}${server.path}',
      ),
      enabled: true,
      connectTimeout: const Duration(seconds: 5),
      requestTimeout: const Duration(seconds: 5),
    );
    const factory = McpDartProtocolClientFactory();
    final connectionCancellation = ToolCancellationController();
    final errors = <Object>[];
    var toolsChanged = 0;
    final session = await factory.connect(
      config: config,
      bearerToken: bearerToken,
      cancellationToken: connectionCancellation.token,
      onToolsChanged: () => toolsChanged++,
      onError: errors.add,
    );
    addTearDown(session.close);

    final tools = await session.listTools(
      cancellationToken: ToolCancellationController().token,
      timeout: const Duration(seconds: 5),
    );
    expect(session.serverImplementation, 'NativeTavern MCP Test');
    expect(session.serverVersion, '1.2.3');
    expect(session.protocolVersion, isNotEmpty);
    expect(tools.map((tool) => tool.name).toSet(), {'echo', 'slow'});
    expect(
      tools.singleWhere((tool) => tool.name == 'echo').accessLevel,
      ToolAccessLevel.readOnly,
    );

    final output = await session.callTool(
      name: 'echo',
      arguments: const {'text': 'hello'},
      cancellationToken: ToolCancellationController().token,
      timeout: const Duration(seconds: 5),
    );
    expect(output['content'], isA<List<dynamic>>());
    expect('$output', contains('hello'));

    final callCancellation = ToolCancellationController();
    final slowCall = session.callTool(
      name: 'slow',
      arguments: const {},
      cancellationToken: callCancellation.token,
      timeout: const Duration(seconds: 5),
    );
    await slowStarted.future.timeout(const Duration(seconds: 5));
    callCancellation.cancel('test cancellation');
    await expectLater(slowCall, throwsA(anything));

    await session.close();
    final reconnected = await factory.connect(
      config: config,
      bearerToken: bearerToken,
      cancellationToken: ToolCancellationController().token,
      onToolsChanged: () => toolsChanged++,
      onError: errors.add,
    );
    final reconnectedTools = await reconnected.listTools(
      cancellationToken: ToolCancellationController().token,
      timeout: const Duration(seconds: 5),
    );
    expect(reconnectedTools, hasLength(2));
    expect(authenticatedRequests, greaterThan(3));
    expect(errors, isEmpty);
    await reconnected.close();
  }, timeout: const Timeout(Duration(seconds: 30)));
}

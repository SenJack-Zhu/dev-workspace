import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:native_tavern/domain/models/tool_generation.dart';
import 'package:native_tavern/domain/services/tool_calling/built_in_tool_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/tool_calling_providers.dart';
import 'package:native_tavern/presentation/screens/settings/tool_calling_settings_screen.dart';
import 'package:native_tavern/presentation/widgets/chat/tool_activity_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('tool settings persist explicit enablement and hard limits',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final registry = BuiltInToolRegistry([
      RollDiceToolExecutor(),
    ]);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          builtInToolRegistryProvider.overrideWithValue(registry),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ToolCallingSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tool calling'), findsOneWidget);
    expect(find.text('roll_dice'), findsOneWidget);
    var master = tester.widget<SwitchListTile>(
      find.byKey(const Key('tool-calling-master-toggle')),
    );
    expect(master.value, isFalse);

    await tester.tap(find.byKey(const Key('tool-calling-master-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('built-in-tool-roll_dice')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('tool-call-limit')));
    await tester.pumpAndSettle();
    final callLimit = find.byKey(const Key('tool-call-limit'));
    await tester.tap(
      find.descendant(
          of: callLimit,
          matching: find.byTooltip('Increase Calls per response')),
    );
    await tester.pumpAndSettle();

    final stored = jsonDecode(
      preferences.getString('tool_calling_settings')!,
    ) as Map<String, dynamic>;
    expect(stored['enabled'], isTrue);
    expect(stored['enabledBuiltInTools'], ['roll_dice']);
    expect(
      (stored['limits'] as Map<String, dynamic>)['maxCalls'],
      9,
    );
    master = tester.widget<SwitchListTile>(
      find.byKey(const Key('tool-calling-master-toggle')),
    );
    expect(master.value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('activity panel exposes every state and user-only approval',
      (tester) async {
    final runtime = ToolRuntimeController();
    runtime.beginGeneration('chat');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [toolRuntimeProvider.overrideWith((ref) => runtime)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ToolActivityPanel(chatId: 'chat')),
        ),
      ),
    );

    const statuses = <ToolCallProgressStatus, String>{
      ToolCallProgressStatus.waitingApproval: 'Waiting for approval',
      ToolCallProgressStatus.running: 'Running',
      ToolCallProgressStatus.succeeded: 'Succeeded',
      ToolCallProgressStatus.failed: 'Failed',
      ToolCallProgressStatus.denied: 'Denied',
      ToolCallProgressStatus.cancelled: 'Cancelled',
    };
    for (final entry in statuses.entries) {
      runtime.report(
        const ToolCallProgress(
          chatId: 'chat',
          callId: 'call',
          toolName: 'generate_image',
          accessLevel: ToolAccessLevel.externalSideEffect,
          target: 'image:generation',
          status: ToolCallProgressStatus.running,
        ).copyWith(status: entry.key),
      );
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget);
    }

    final approval = runtime.requestBuiltIn(
      'chat',
      ToolExecutionPreview(
        callId: 'approval',
        toolName: 'generate_image',
        accessLevel: ToolAccessLevel.externalSideEffect,
        target: 'image:generation',
        parameters: const {'prompt': 'visible preview'},
        requiredCapabilities: const [],
        dataScopes: const [ToolDataScope.imagePrompt],
        requiresConfirmation: true,
        supportsDryRun: false,
        dryRun: false,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('tool-approval-prompt')), findsOneWidget);
    expect(find.textContaining('visible preview'), findsOneWidget);
    expect(find.byKey(const Key('tool-always-allow')), findsNothing);
    await tester.tap(find.byKey(const Key('tool-allow-once')));
    await tester.pump();
    expect(await approval, ToolApprovalDecision.approveOnce);
    expect(find.byKey(const Key('tool-approval-prompt')), findsNothing);
  });

  test('cancelling runtime cancels both approval and generation token',
      () async {
    final runtime = ToolRuntimeController();
    addTearDown(runtime.dispose);
    final handle = runtime.beginGeneration('chat');
    final approval = runtime.requestMcp(
      'chat',
      ToolExecutionPreview(
        callId: 'mcp-call',
        toolName: 'mcp_server_tool',
        accessLevel: ToolAccessLevel.write,
        target: 'mcp:server/tool',
        parameters: const {},
        requiredCapabilities: const [],
        dataScopes: const [ToolDataScope.mcpToolArguments],
        requiresConfirmation: true,
        supportsDryRun: false,
        dryRun: false,
      ),
    );

    runtime.cancelGeneration('test cancellation');

    expect(handle.token.isCancelled, isTrue);
    expect(await approval, McpApprovalDecision.cancel);
    expect(runtime.state.pendingApproval, isNull);
  });
}

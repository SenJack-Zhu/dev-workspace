import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/domain/services/capability_registry.dart';
import 'package:native_tavern/domain/services/external_call_audit_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/capability_providers.dart';
import 'package:native_tavern/presentation/providers/external_call_audit_providers.dart';
import 'package:native_tavern/presentation/screens/settings/capability_diagnostics_screen.dart';

void main() {
  testWidgets('diagnoses configuration and opens the repair destination',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final audit = MemoryExternalCallAuditRepository();
    await audit.record(ExternalCallAuditRecord.forRequest(
      requestUri: Uri.parse('https://api.example.com/v1/chat?key=hidden'),
      capabilityId: 'llm',
      dataTypes: const {ExternalDataType.chatText},
      outcome: ExternalCallOutcome.failed,
      costAttribution: ExternalCostAttribution.userServiceAccount,
      statusCode: 401,
    ));
    final router = GoRouter(
      initialLocation: '/capability-diagnostics',
      routes: [
        GoRoute(
          path: '/capability-diagnostics',
          builder: (_, __) => const CapabilityDiagnosticsScreen(),
        ),
        GoRoute(
          path: '/ai-config',
          builder: (_, __) => const Scaffold(
            body: Center(child: Text('AI repair destination')),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          externalCallAuditRepositoryProvider.overrideWithValue(audit),
          capabilityDiagnosticInputsProvider.overrideWithValue(const [
            CapabilityDiagnosticInput(
              id: CapabilityId.llm,
              configured: false,
              configurationIssue: 'Complete the current AI connection',
            ),
            CapabilityDiagnosticInput(id: CapabilityId.systemTts),
            CapabilityDiagnosticInput(
              id: CapabilityId.systemStt,
              enabled: false,
            ),
            CapabilityDiagnosticInput(
              id: CapabilityId.embedding,
              enabled: false,
            ),
            CapabilityDiagnosticInput(
              id: CapabilityId.imageGeneration,
              enabled: false,
            ),
            CapabilityDiagnosticInput(
              id: CapabilityId.mcp,
              configured: false,
              supported: false,
            ),
            CapabilityDiagnosticInput(id: CapabilityId.live2d),
          ]),
          capabilityRuntimeSignalsProvider.overrideWith(
            (ref) async => const CapabilityRuntimeSignals(
              network: CapabilityNetworkState.online,
            ),
          ),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Capability check'), findsOneWidget);
    expect(find.text('Complete the current AI connection'), findsOneWidget);

    expect(find.text('api.example.com'), findsOneWidget);
    expect(find.textContaining('hidden'), findsNothing);

    await tester.tap(find.byTooltip('Open settings').first);
    await tester.pumpAndSettle();

    expect(find.text('AI repair destination'), findsOneWidget);
  });
}

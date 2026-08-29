import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/ai_data_sharing_consent_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/ai_data_sharing_consent_providers.dart';
import 'package:native_tavern/presentation/widgets/privacy/ai_data_sharing_consent_gate.dart';

void main() {
  Widget buildApp(AiDataSharingConsentRepository repository) {
    return ProviderScope(
      overrides: [
        aiDataSharingConsentRepositoryProvider.overrideWithValue(repository),
      ],
      child: const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: AiDataSharingConsentGate(
          child: Scaffold(body: Text('Main app')),
        ),
      ),
    );
  }

  testWidgets('local-only choice dismisses the first-run disclosure',
      (tester) async {
    final repository = MemoryAiDataSharingConsentRepository();
    await tester.pumpWidget(buildApp(repository));

    expect(find.byKey(const Key('ai-data-sharing-consent-screen')), findsOne);
    expect(find.text('Main app'), findsNothing);

    await tester.tap(find.byKey(const Key('use-local-ai-only-button')));
    await tester.pumpAndSettle();

    expect(repository.current.choice, AiDataSharingChoice.localOnly);
    expect(find.text('Main app'), findsOne);
  });

  testWidgets('allow choice is saved without another provider prompt',
      (tester) async {
    final repository = MemoryAiDataSharingConsentRepository();
    await tester.pumpWidget(buildApp(repository));

    await tester.tap(find.byKey(const Key('allow-remote-ai-button')));
    await tester.pumpAndSettle();

    expect(repository.current.choice, AiDataSharingChoice.allowed);
    expect(repository.current.allowsRemoteAi, isTrue);
    expect(find.text('Main app'), findsOne);
  });
}

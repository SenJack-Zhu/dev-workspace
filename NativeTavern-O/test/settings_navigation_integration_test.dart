import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/persona_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/router/app_router.dart';
import 'package:native_tavern/presentation/screens/settings/settings_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase database;
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
  });

  tearDown(() => database.close());

  test('production router registers every integrated feature path', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final router = container.read(appRouterProvider);
    addTearDown(router.dispose);
    final registeredPaths = _routePaths(router.configuration.routes).toSet();

    expect(
      registeredPaths,
      containsAll(const {
        AppRoutes.memoryInbox,
        AppRoutes.dataBank,
        AppRoutes.rpgScenarioEditor,
        AppRoutes.capabilityDiagnostics,
        AppRoutes.mcpSettings,
        AppRoutes.toolCallingSettings,
        AppRoutes.storageManagement,
      }),
    );
  });

  test('integrated entry and storage keys resolve for every locale', () async {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = await AppLocalizations.delegate.load(locale);
      final values = [
        l10n.localFeatures,
        l10n.memoryInbox,
        l10n.memoryInboxSubtitle,
        l10n.dataBank,
        l10n.dataBankSubtitle,
        l10n.rpgScenarioEditor,
        l10n.rpgScenarioEditorSubtitle,
        l10n.capabilityCheck,
        l10n.capabilityCheckSubtitle,
        l10n.mcpServers,
        l10n.mcpServersSubtitle,
        l10n.toolCalling,
        l10n.toolCallingSubtitle,
        l10n.toolCallingAllow,
        l10n.toolCallingAllowSubtitle,
        l10n.toolBuiltInTools,
        l10n.toolMcpTools,
        l10n.toolMcpPermissionsSubtitle,
        l10n.toolSafetyLimits,
        l10n.toolRounds,
        l10n.toolCallsPerResponse,
        l10n.toolTimeLimit,
        l10n.toolTokenBudget,
        l10n.toolSeconds,
        l10n.toolTokens,
        l10n.toolDecrease('limit'),
        l10n.toolIncrease('limit'),
        l10n.toolActivity,
        l10n.toolApprovalRequired,
        l10n.toolAllowOnce,
        l10n.toolAlwaysAllow,
        l10n.toolDeny,
        l10n.toolCancelCall,
        l10n.toolStatusWaitingApproval,
        l10n.toolStatusRunning,
        l10n.toolStatusSucceeded,
        l10n.toolStatusFailed,
        l10n.toolStatusDenied,
        l10n.toolStatusCancelled,
        l10n.storageManagement,
        l10n.storageManagementSubtitle,
        l10n.storageCleanupReviewTitle,
        l10n.storageCleanupReviewBody(1, 1, '1 B'),
        l10n.storageCleanupFailed('failure'),
      ];
      expect(
        values,
        everyElement(
          isA<String>()
              .having((value) => value.trim(), 'non-empty value', isNotEmpty)
              .having(
                (value) => value.contains(RegExp(r'\{\w+\}')),
                'resolved placeholders',
                isFalse,
              ),
        ),
        reason: 'Missing integrated localization for $locale',
      );
    }
  });

  testWidgets('settings entries navigate to every integrated feature',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const destinations = <({Key key, String path})>[
      (
        key: Key('memory-inbox-settings-tile'),
        path: AppRoutes.memoryInbox,
      ),
      (
        key: Key('capability-diagnostics-settings-tile'),
        path: AppRoutes.capabilityDiagnostics,
      ),
      (key: Key('mcp-settings-tile'), path: AppRoutes.mcpSettings),
      (
        key: Key('tool-calling-settings-tile'),
        path: AppRoutes.toolCallingSettings,
      ),
      (
        key: Key('storage-management-settings-tile'),
        path: AppRoutes.storageManagement,
      ),
    ];
    final router = GoRouter(
      initialLocation: AppRoutes.settings,
      routes: [
        GoRoute(
          path: AppRoutes.settings,
          builder: (_, __) => const SettingsScreen(),
        ),
        for (final destination in destinations)
          GoRoute(
            path: destination.path,
            builder: (_, __) =>
                Scaffold(body: Text('destination:${destination.path}')),
          ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          sharedPreferencesProvider.overrideWithValue(preferences),
          activePersonaProvider.overrideWith((ref) => null),
          packageInfoProvider.overrideWith(
            (ref) => PackageInfo(
              appName: 'NativeTavern',
              packageName: 'native_tavern',
              version: '0.1.9',
              buildNumber: '23',
            ),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final destination in destinations) {
      final tile = find.byKey(destination.key);
      await tester.scrollUntilVisible(tile, 240);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.text('destination:${destination.path}'), findsOneWidget);
      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();
    }

    expect(find.byKey(const Key('data-bank-settings-tile')), findsNothing);
    final momentsSwitch = find.byKey(const Key('moments-enabled-switch'));
    await tester.scrollUntilVisible(momentsSwitch, -240);
    expect(tester.widget<SwitchListTile>(momentsSwitch).value, isFalse);
    final storySwitch = find.byKey(const Key('story-enabled-switch'));
    await tester.scrollUntilVisible(storySwitch, 240);
    expect(tester.widget<SwitchListTile>(storySwitch).value, isFalse);
  });
}

Iterable<String> _routePaths(List<RouteBase> routes) sync* {
  for (final route in routes) {
    if (route is GoRoute) yield route.path;
    yield* _routePaths(route.routes);
  }
}

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/drift_moment_repository.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/data/models/operation_log.dart';
import 'package:native_tavern/data/repositories/operation_log_repository.dart';
import 'package:native_tavern/domain/services/moment_service.dart';
import 'package:native_tavern/domain/services/world_runtime.dart';
import 'package:native_tavern/presentation/providers/moment_providers.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/world_info_repository.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/router/app_router.dart';
import 'package:native_tavern/presentation/screens/play/moments_screen.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dataDirectory;
  late CharacterRepository characters;
  late DriftMomentRepository moments;
  late DateTime now;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dataDirectory = Directory.systemTemp.createTempSync('nt_world');
    characters = CharacterRepository(database, dataDirectory.path);
    moments = DriftMomentRepository(database);
    now = DateTime.utc(2026, 8, 23, 12);
    await characters.createCharacter(
      models.Character(
        id: 'character-1',
        name: 'Ava',
        description: 'Keeps the garden.',
        createdAt: now,
        modifiedAt: now,
      ),
    );
  });

  tearDown(() async {
    await database.close();
    dataDirectory.deleteSync(recursive: true);
  });

  MomentService service({
    required Future<String> Function(
      List<Map<String, dynamic>>,
      LLMConfig,
    ) transport,
  }) {
    return MomentService(
      momentRepository: moments,
      dataPath: dataDirectory.path,
      minInterval: Duration.zero,
      now: () => now,
      transport: transport,
    );
  }

  test('a due character can post when the world clock wakes them', () async {
    var asks = 0;
    final store = MemoryWorldWakeStore();
    final runtime = WorldRuntime(
      momentService: service(
        transport: (messages, config) async {
          asks++;
          return '{"kind":"text","body":"Rain on the gate."}';
        },
      ),
      characterRepository: characters,
      store: store,
      enabled: () => true,
      config: () => _configuredLlm,
      now: () => now,
      firstWake: (character, clock) => clock,
      intervalFor: (character, {required posted}) => const Duration(hours: 4),
    );

    final published = await runtime.tick();
    expect(asks, 1);
    expect(published.single.publicBody, 'Rain on the gate.');
    expect(published.single.origin, MomentPostOrigin.character);
    expect(store.state.nextWakeAt['character-1'],
        now.add(const Duration(hours: 4)));

    asks = 0;
    expect(await runtime.tick(), isEmpty);
    expect(asks, 0);
  });

  test('one global budget prevents due characters from posting in a burst',
      () async {
    await characters.createCharacter(
      models.Character(
        id: 'character-2',
        name: 'Bea',
        description: 'Keeps the orchard.',
        createdAt: now,
        modifiedAt: now,
      ),
    );
    var asks = 0;
    final runtime = WorldRuntime(
      momentService: service(
        transport: (messages, config) async {
          asks++;
          return '{"action":"post","kind":"text",'
              '"body":"Post number $asks."}';
        },
      ),
      characterRepository: characters,
      store: MemoryWorldWakeStore(),
      enabled: () => true,
      config: () => _configuredLlm,
      now: () => now,
      firstWake: (character, clock) => clock,
      maxPostsPerTick: 2,
    );

    final published = await runtime.tick();
    expect(asks, 2);
    expect(published, hasLength(1));
    expect(await moments.listAll(), hasLength(1));
  });

  test('global budget enforces hourly and daily character post limits',
      () async {
    final momentService = service(
      transport: (messages, config) async => '{"action":"skip"}',
    );
    for (var index = 0; index < 2; index++) {
      await momentService.createPost(
        authorId: 'character-1',
        authorName: 'Ava',
        origin: MomentPostOrigin.character,
        body: 'Hourly $index',
      );
      now = now.add(const Duration(minutes: 21));
    }
    expect(await momentService.canPublishCharacterPost(now: now), isFalse);

    now = DateTime.utc(2026, 8, 24, 12);
    for (var index = 0; index < 16; index++) {
      await momentService.createPost(
        authorId: 'character-1',
        authorName: 'Ava',
        origin: MomentPostOrigin.character,
        body: 'Daily $index',
      );
      now = now.add(const Duration(minutes: 61));
    }
    expect(await momentService.canPublishCharacterPost(now: now), isFalse);
  });

  test('a character like refreshes the feed without creating a post', () async {
    final playerPost = await service(
      transport: (messages, config) async => '{"action":"skip"}',
    ).publishPlayerPost(body: 'The garden is open.');
    var revisions = 0;
    final runtime = WorldRuntime(
      momentService: service(
        transport: (messages, config) async =>
            '{"action":"like","post_id":"${playerPost.id}"}',
      ),
      characterRepository: characters,
      store: MemoryWorldWakeStore(),
      enabled: () => true,
      config: () => _configuredLlm,
      now: () => now,
      firstWake: (character, clock) => clock,
      onPublished: (count) => revisions += count,
    );

    expect(await runtime.tick(), isEmpty);
    expect(await moments.likeCount(playerPost.id), 1);
    expect(revisions, 1);
  });

  test('a due character does not call AI when moments are off', () async {
    var asks = 0;
    final store = MemoryWorldWakeStore();
    final runtime = WorldRuntime(
      momentService: service(
        transport: (messages, config) async {
          asks++;
          return '{"kind":"text","body":"should not post"}';
        },
      ),
      characterRepository: characters,
      store: store,
      enabled: () => false,
      storyEnabled: () => false,
      config: () => _configuredLlm,
      now: () => now,
      firstWake: (character, clock) => clock,
    );

    expect(await runtime.tick(), isEmpty);
    expect(asks, 0);
    expect(await moments.listAll(), isEmpty);
    expect(store.state.nextWakeAt, isEmpty);
  });

  test('a character whose wake is still in the future is left alone', () async {
    var asks = 0;
    final runtime = WorldRuntime(
      momentService: service(
        transport: (messages, config) async {
          asks++;
          return '{"kind":"text","body":"should not post"}';
        },
      ),
      characterRepository: characters,
      store: MemoryWorldWakeStore(),
      enabled: () => true,
      config: () => _configuredLlm,
      now: () => now,
      firstWake: (character, clock) => clock.add(const Duration(hours: 2)),
    );

    expect(await runtime.tick(), isEmpty);
    expect(asks, 0);
  });

  test('a failed wake stays due and is retried', () async {
    var asks = 0;
    final store = MemoryWorldWakeStore();
    final operations = OperationLogRepository(database);
    final runtime = WorldRuntime(
      momentService: service(
        transport: (messages, config) async {
          asks++;
          if (asks == 1) throw Exception('timeout');
          return '{"kind":"text","body":"Back online."}';
        },
      ),
      characterRepository: characters,
      operations: operations,
      store: store,
      enabled: () => true,
      config: () => _configuredLlm,
      now: () => now,
      firstWake: (character, clock) => clock,
      intervalFor: (character, {required posted}) => const Duration(hours: 4),
    );

    expect(await runtime.tick(), isEmpty);
    expect(asks, 1);
    final open = await operations.findOpen(
      kind: OperationKind.momentWake,
      subjectId: 'character-1',
    );
    expect(open?.status, OperationStatus.incomplete);
    now = open!.dueAt;

    final published = await runtime.tick();
    expect(asks, 2);
    expect(published.single.publicBody, 'Back online.');
    expect(
      store.state.nextWakeAt['character-1'],
      now.add(const Duration(hours: 4)),
    );
    expect(
      await operations.findOpen(
        kind: OperationKind.momentWake,
        subjectId: 'character-1',
      ),
      isNull,
    );
  });

  test('a failed moments photo is logged and retried', () async {
    var images = 0;
    final operations = OperationLogRepository(database);
    final service = MomentService(
      momentRepository: moments,
      dataPath: dataDirectory.path,
      operations: operations,
      minInterval: Duration.zero,
      transport: (messages, config) async {
        return '{"kind":"text_image","body":"Look.","image_prompt":"a rusted gate"}';
      },
      imageGenerator: (prompt) async {
        images++;
        if (images == 1) return null;
        return [1, 2, 3, 4];
      },
    );
    final runtime = WorldRuntime(
      momentService: service,
      characterRepository: characters,
      operations: operations,
      store: MemoryWorldWakeStore(),
      enabled: () => true,
      config: () => _configuredLlm,
      now: () => now,
      firstWake: (character, clock) => clock,
    );

    expect(await runtime.tick(), isEmpty);
    final open = await operations.findOpen(
      kind: OperationKind.momentImage,
      subjectId: 'character-1',
    );
    expect(open?.status, OperationStatus.incomplete);
    now = open!.dueAt;

    final published = await runtime.tick();
    expect(published.single.hasPhoto, isTrue);
    expect(
      await operations.findOpen(
        kind: OperationKind.momentImage,
        subjectId: 'character-1',
      ),
      isNull,
    );
  });

  test('an exhausted image job is closed without another generation', () async {
    var images = 0;
    final operations = OperationLogRepository(database);
    OperationLog? job;
    for (var attempt = 0; attempt < WorldRuntime.maxWakeAttempts; attempt++) {
      job = await operations.begin(
        kind: OperationKind.momentImage,
        subjectId: 'character-1',
        payload: const {
          'characterId': 'character-1',
          'authorName': 'Ava',
          'prompt': 'a rusted gate',
          'body': 'Look.',
        },
        now: now,
      );
      await operations.markIncomplete(job, dueAt: now, now: now);
    }
    expect(job?.attempts, WorldRuntime.maxWakeAttempts);
    final runtime = WorldRuntime(
      momentService: MomentService(
        momentRepository: moments,
        dataPath: dataDirectory.path,
        operations: operations,
        transport: (messages, config) async => '{"action":"skip"}',
        imageGenerator: (prompt) async {
          images++;
          return const [1, 2, 3, 4];
        },
      ),
      characterRepository: characters,
      operations: operations,
      store: MemoryWorldWakeStore(),
      enabled: () => true,
      config: () => _configuredLlm,
      now: () => now,
      firstWake: (character, clock) => clock.add(const Duration(hours: 1)),
    );

    expect(await runtime.tick(), isEmpty);
    expect(images, 0);
    expect(
      await operations.findOpen(
        kind: OperationKind.momentImage,
        subjectId: 'character-1',
      ),
      isNull,
    );
  });

  testWidgets('opening moments only browses; it does not wake characters',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var asks = 0;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characters),
        chatRepositoryProvider.overrideWithValue(ChatRepository(database)),
        worldInfoRepositoryProvider.overrideWithValue(
          WorldInfoRepository(database),
        ),
        sharedPreferencesProvider.overrideWithValue(preferences),
        momentServiceProvider.overrideWithValue(
          service(
            transport: (messages, config) async {
              asks++;
              return '{"kind":"text","body":"should not post"}';
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(appSettingsProvider);
    container.read(appSettingsProvider.notifier).updateMomentsEnabled(true);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: AppRoutes.playMoments,
                builder: (_, __) => const MomentsScreen(),
              ),
            ],
            initialLocation: AppRoutes.playMoments,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Nobody has posted yet'), findsOneWidget);
    expect(asks, 0);
    expect(await moments.listAll(), isEmpty);
  });
}

const _configuredLlm = LLMConfig(
  provider: LLMProvider.openai,
  model: 'chat-model',
  apiKey: 'secret',
  apiUrl: 'https://example.com/v1',
  streamEnabled: false,
);

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/data/models/story/story_chapter.dart';
import 'package:native_tavern/presentation/providers/story_timeline_providers.dart';
import 'package:native_tavern/presentation/router/app_router.dart';
import 'package:native_tavern/presentation/screens/play/story_models.dart';
import 'package:native_tavern/presentation/screens/play/story_screen.dart';
import 'package:native_tavern/presentation/screens/play/story_timeline_source.dart';

void main() {
  Future<AppLocalizations> loadEn() {
    return AppLocalizations.delegate.load(const Locale('en'));
  }

  testWidgets('empty story page is a timeline empty state, not inbox or editor',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final l10n = await loadEn();
    final router = GoRouter(
      initialLocation: AppRoutes.playStory,
      routes: [
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => const Scaffold(body: Text('chat-home')),
        ),
        GoRoute(
          path: AppRoutes.playStory,
          builder: (_, __) => const StoryScreen(),
        ),
        GoRoute(
          path: AppRoutes.memoryInbox,
          builder: (_, __) => const Scaffold(body: Text('memory-inbox')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyTimelineSourceProvider.overrideWithValue(
            const EmptyStoryTimelineSource(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.storyEmptyHint), findsOneWidget);
    expect(find.text(l10n.memoryInbox), findsNothing);
    expect(find.text(l10n.settings), findsNothing);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byKey(const Key('story-go-to-chat')));
    await tester.pumpAndSettle();
    expect(find.text('chat-home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chapter tap jumps back to the original chat message',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final chapter = StoryChapterTimelineItem(
      id: 'chapter-1',
      chatId: 'chat-42',
      title: 'Harbor dawn',
      summary: 'They left before the tide turned.',
      narrative: const StoryChapterNarrative(
        keyEvents: ['The crew left the harbor.'],
        stateChanges: ['The lighthouse is now unattended.'],
        openThreads: ['Who changed the tide chart?'],
        nextSteps: ['Return to the lighthouse.'],
      ),
      jumpMessageId: 'msg-7',
      createdAt: DateTime.utc(2026, 8, 23, 10),
      chatTitle: 'Harbor story',
      rootChatId: 'chat-42',
      branchTitle: 'Harbor story',
    );
    String? openedLocation;
    final router = GoRouter(
      initialLocation: AppRoutes.playStory,
      routes: [
        GoRoute(
          path: AppRoutes.playStory,
          builder: (_, __) => const StoryScreen(),
        ),
        GoRoute(
          path: '/chat/:id',
          builder: (context, state) {
            openedLocation = state.uri.toString();
            return Scaffold(
              body: Text('chat:${state.pathParameters['id']}'),
            );
          },
        ),
        GoRoute(
          path: AppRoutes.memoryInbox,
          builder: (_, __) => const Scaffold(body: Text('memory-inbox')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyTimelineSourceProvider.overrideWithValue(
            FakeStoryTimelineSource([chapter]),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('story-chapter-timeline')), findsOneWidget);
    expect(find.text('Harbor dawn'), findsOneWidget);
    expect(find.textContaining('They left before the tide turned.'),
        findsOneWidget);
    expect(
      find.textContaining('The crew left the harbor.', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'The lighthouse is now unattended.',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Who changed the tide chart?', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.textContaining('Return to the lighthouse.', skipOffstage: false),
      findsOneWidget,
    );

    await tester.tap(find.text('Harbor dawn'));
    await tester.pumpAndSettle();
    expect(find.text('chat:chat-42'), findsOneWidget);
    expect(openedLocation, '/chat/chat-42?message=msg-7');
    expect(tester.takeException(), isNull);
  });

  testWidgets('continue story opens chat with an editable direction draft',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final l10n = await loadEn();
    final chapter = StoryChapterTimelineItem(
      id: 'chapter-continue',
      chatId: 'chat-continue',
      title: 'The sealed letter',
      summary: 'A letter arrived without a sender.',
      narrative: const StoryChapterNarrative(
        openThreads: ['Find out who sent the letter.'],
      ),
      jumpMessageId: 'message-1',
      createdAt: DateTime.utc(2026, 8, 23),
      chatTitle: 'Letter story',
      rootChatId: 'chat-continue',
    );
    String? openedLocation;
    final router = GoRouter(
      initialLocation: AppRoutes.playStory,
      routes: [
        GoRoute(
          path: AppRoutes.playStory,
          builder: (_, __) => const StoryScreen(),
        ),
        GoRoute(
          path: '/chat/:id',
          builder: (_, state) {
            openedLocation = state.uri.toString();
            return const Scaffold(body: Text('continued-chat'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyTimelineSourceProvider.overrideWithValue(
            FakeStoryTimelineSource([chapter]),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.storyContinue));
    await tester.pumpAndSettle();

    expect(find.text('continued-chat'), findsOneWidget);
    final uri = Uri.parse(openedLocation!);
    expect(uri.path, '/chat/chat-continue');
    expect(
      uri.queryParameters['draft'],
      l10n.storyContinueDraft(
        'The sealed letter',
        'Find out who sent the letter.',
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat-scoped story shows every line from the same root',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final items = [
      StoryChapterTimelineItem(
        id: 'root-chapter',
        chatId: 'root-chat',
        title: 'Shared opening',
        summary: 'The shared history.',
        jumpMessageId: 'root-message',
        createdAt: DateTime.utc(2026, 8, 23),
        chatTitle: 'Shared story',
        rootChatId: 'root-chat',
        branchTitle: 'Shared story',
      ),
      StoryChapterTimelineItem(
        id: 'branch-chapter',
        chatId: 'branch-chat',
        title: 'River consequence',
        summary: 'The branch reached the river.',
        jumpMessageId: 'branch-message',
        createdAt: DateTime.utc(2026, 8, 24),
        chatTitle: 'Shared story - River route',
        rootChatId: 'root-chat',
        parentChatId: 'root-chat',
        branchTitle: 'River route',
        forkOrdinal: 1,
      ),
      StoryChapterTimelineItem(
        id: 'other-chapter',
        chatId: 'other-chat',
        title: 'Unrelated story',
        summary: 'This belongs to another root.',
        jumpMessageId: 'other-message',
        createdAt: DateTime.utc(2026, 8, 25),
      ),
    ];
    final router = GoRouter(
      initialLocation: AppRoutes.playStory,
      routes: [
        GoRoute(
          path: AppRoutes.playStory,
          builder: (_, __) => const StoryScreen(initialChatId: 'branch-chat'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyTimelineSourceProvider.overrideWithValue(
            FakeStoryTimelineSource(items),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Shared story'), findsOneWidget);
    expect(
      find.text('Shared opening', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.text('River consequence', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Unrelated story', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inbox is a secondary destination and jot note stays on story',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final l10n = await loadEn();
    final router = GoRouter(
      initialLocation: AppRoutes.playStory,
      routes: [
        GoRoute(
          path: AppRoutes.playStory,
          builder: (_, __) => const StoryScreen(),
        ),
        GoRoute(
          path: AppRoutes.memoryInbox,
          builder: (_, __) => const Scaffold(body: Text('memory-inbox')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyTimelineSourceProvider.overrideWithValue(
            const EmptyStoryTimelineSource(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('story-jot-note')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('story-jot-note-field')), findsOneWidget);
    expect(find.text(l10n.storyJotNoteHint), findsOneWidget);
    await tester.tap(find.byKey(const Key('story-jot-note-save')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.storyEmptyHint), findsOneWidget);

    await tester.tap(find.byKey(const Key('story-open-inbox')));
    await tester.pumpAndSettle();
    expect(find.text('memory-inbox'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

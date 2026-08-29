import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/llm_service.dart';

void main() {
  group('context assembly', () {
    test('preserves the base payload when no extensions are registered',
        () async {
      ContextAssemblyResult? observed;
      final pipeline = ChatGenerationPipeline(
        registry: ChatExtensionRegistry(),
        onContextAssembled: (result) => observed = result,
      );
      final session = pipeline.startSession(
        chatId: 'chat-1',
        mode: ChatGenerationMode.send,
        config: _config,
      );
      final base = <ChatMessageMap>[
        {'role': 'system', 'content': 'Stay in character.'},
        {'role': 'user', 'content': 'Hello'},
      ];

      final result = await session.assemble(base);

      expect(result.messages, base);
      expect(result.baseMessages, base);
      expect(result.traces, isEmpty);
      expect(result.baseEstimatedTokens, result.estimatedTokens);
      expect(observed, same(result));
      expect(
        () => result.messages.add({'role': 'user', 'content': 'mutate'}),
        throwsUnsupportedError,
      );
      session.close();
    });

    test('orders contributors deterministically and honors placement',
        () async {
      final calls = <String>[];
      final registry = ChatExtensionRegistry();
      registry.registerContributor(_Contributor(
        id: 'leading',
        order: 10,
        onContribute: (request) async {
          calls.add('leading');
          return ContextContribution(
            placement: ContextContributionPlacement.beforeBase,
            messages: const [
              {'role': 'assistant', 'content': 'Leading'},
            ],
          );
        },
      ));
      registry.registerContributor(_Contributor(
        id: 'alpha',
        order: 20,
        onContribute: (request) async {
          calls.add('alpha');
          return ContextContribution(messages: const [
            {'role': 'system', 'content': 'Before conversation'},
          ]);
        },
      ));
      registry.registerContributor(_Contributor(
        id: 'zeta',
        order: 20,
        onContribute: (request) async {
          calls.add('zeta');
          return ContextContribution(
            placement: ContextContributionPlacement.afterBase,
            messages: const [
              {'role': 'system', 'content': 'Trailing'},
            ],
          );
        },
      ));
      final session = ChatGenerationPipeline(registry: registry).startSession(
        chatId: 'chat-1',
        mode: ChatGenerationMode.send,
        config: _config,
      );

      final result = await session.assemble(const [
        {'role': 'system', 'content': 'Base system'},
        {'role': 'user', 'content': 'Base user'},
      ]);

      expect(calls, ['leading', 'alpha', 'zeta']);
      expect(
        result.messages.map((message) => message['content']),
        [
          'Leading',
          'Base system',
          'Before conversation',
          'Base user',
          'Trailing',
        ],
      );
      expect(
        result.traces.map((trace) => trace.contributorId),
        ['leading', 'alpha', 'zeta'],
      );
      session.close();
    });

    test('isolates disabled and failing contributors', () async {
      final registry = ChatExtensionRegistry();
      registry.registerContributor(_Contributor(
        id: 'disabled',
        order: 1,
        enabled: false,
        onContribute: (_) async => throw StateError('must not run'),
      ));
      registry.registerContributor(_Contributor(
        id: 'failing',
        order: 2,
        onContribute: (_) async => throw StateError('broken source'),
      ));
      registry.registerContributor(_Contributor(
        id: 'healthy',
        order: 3,
        onContribute: (_) async => ContextContribution(messages: const [
          {'role': 'system', 'content': 'Healthy context'},
        ]),
      ));
      final session = ChatGenerationPipeline(registry: registry).startSession(
        chatId: 'chat-1',
        mode: ChatGenerationMode.send,
        config: _config,
      );

      final result = await session.assemble(const [
        {'role': 'user', 'content': 'Hello'},
      ]);

      expect(result.messages.last['content'], 'Hello');
      expect(result.messages.first['content'], 'Healthy context');
      expect(
        result.traces.map((trace) => trace.status),
        [
          ContextContributionStatus.disabled,
          ContextContributionStatus.failed,
          ContextContributionStatus.applied,
        ],
      );
      expect(result.traces[1].error, contains('broken source'));
      session.close();
    });

    test('enforces contributor token budgets and records trimming', () async {
      final registry = ChatExtensionRegistry();
      registry.registerContributor(_Contributor(
        id: 'bounded',
        maxTokens: 30,
        onContribute: (_) async => ContextContribution(
          messages: [
            {'role': 'system', 'content': 'short'},
            {'role': 'system', 'content': 'x' * 500},
            {'role': 'system', 'content': 'never reached'},
          ],
          itemIds: const ['short', 'long', 'dropped'],
          metadata: const {'source': 'local'},
        ),
      ));
      final session = ChatGenerationPipeline(registry: registry).startSession(
        chatId: 'chat-1',
        mode: ChatGenerationMode.send,
        config: _config.copyWith(contextLength: 256, maxTokens: 64),
      );

      final result = await session.assemble(const [
        {'role': 'user', 'content': 'Hello'},
      ]);
      final trace = result.traces.single;

      expect(trace.allocatedTokens, 30);
      expect(trace.usedTokens, lessThanOrEqualTo(30));
      expect(trace.originalTokens, greaterThan(trace.usedTokens));
      expect(trace.truncatedMessageCount, 1);
      expect(trace.droppedMessageCount, 1);
      expect(trace.injectedMessages.last['content'], contains('[truncated]'));
      expect(
        trace.itemTraces.map((item) => item.status),
        [
          ContextContributionItemStatus.included,
          ContextContributionItemStatus.truncated,
          ContextContributionItemStatus.dropped,
        ],
      );
      expect(trace.metadata, {'source': 'local'});
      expect(result.wasTrimmed, isTrue);
      expect(
        result.estimatedTokens,
        lessThanOrEqualTo(result.baseEstimatedTokens + 30),
      );
      session.close();
    });

    test('honors an explicit conversation boundary after summary and RAG',
        () async {
      final registry = ChatExtensionRegistry();
      registry.registerContributor(
        _Contributor(
          id: 'memory',
          onContribute: (request) async {
            expect(request.conversationStartIndex, 3);
            return ContextContribution(messages: const [
              {'role': 'system', 'content': 'Memory'},
            ]);
          },
        ),
      );
      final session = ChatGenerationPipeline(registry: registry).startSession(
        chatId: 'chat-1',
        mode: ChatGenerationMode.send,
        config: _config,
      );

      final result = await session.assemble(
        const [
          {'role': 'system', 'content': 'World info'},
          {'role': 'assistant', 'content': 'Summary'},
          {'role': 'system', 'content': 'RAG'},
          {'role': 'user', 'content': 'Current message'},
        ],
        conversationStartIndex: 3,
      );

      expect(
        result.messages.map((message) => message['content']),
        ['World info', 'Summary', 'RAG', 'Memory', 'Current message'],
      );
      session.close();
    });

    test('propagates cancellation to a running contributor', () async {
      final started = Completer<void>();
      var cancellationCallbackRan = false;
      final registry = ChatExtensionRegistry();
      registry.registerContributor(_Contributor(
        id: 'slow',
        onContribute: (request) async {
          started.complete();
          await request.cancellationToken.whenCancelled;
          request.cancellationToken.throwIfCancelled();
          throw StateError('unreachable');
        },
        onCancel: (_) => cancellationCallbackRan = true,
      ));
      final pipeline = ChatGenerationPipeline(registry: registry);
      final session = pipeline.startSession(
        chatId: 'chat-1',
        mode: ChatGenerationMode.send,
        config: _config,
      );

      final assembling = session.assemble(const [
        {'role': 'user', 'content': 'Hello'},
      ]);
      await started.future;
      await pipeline.cancelActiveSessions();
      final result = await assembling;

      expect(result.cancelled, isTrue);
      expect(result.messages.single['content'], 'Hello');
      expect(result.traces.single.status, ContextContributionStatus.cancelled);
      expect(cancellationCallbackRan, isTrue);
      session.close();
    });
  });

  group('generation middleware', () {
    test('runs before/after in stack order and recovers transport errors',
        () async {
      final events = <String>[];
      final registry = ChatExtensionRegistry();
      registry.registerMiddleware(_Middleware(
        id: 'outer',
        order: 10,
        events: events,
        marker: 'outer marker',
        recovery: const LLMResponse(content: 'recovered reply'),
      ));
      registry.registerMiddleware(_Middleware(
        id: 'inner',
        order: 20,
        events: events,
        marker: 'inner marker',
      ));
      ChatGenerationTrace? observed;
      final session = ChatGenerationPipeline(
        registry: registry,
        onGenerationFinished: (trace) => observed = trace,
      ).startSession(
        chatId: 'chat-1',
        mode: ChatGenerationMode.send,
        config: _config,
      );

      final response = await session.generate(
        const [
          {'role': 'user', 'content': 'Hello'},
        ],
        (request) async {
          events.add('transport:${request.messages.length}');
          expect(
            request.messages.map((message) => message['content']),
            ['Hello', 'outer marker', 'inner marker'],
          );
          throw StateError('provider unavailable');
        },
      );

      expect(response.content, 'recovered reply');
      expect(events, [
        'before:outer',
        'before:inner',
        'transport:3',
        'recover:inner',
        'recover:outer',
        'after:inner:true',
        'after:outer:true',
      ]);
      expect(observed?.recovered, isTrue);
      expect(observed?.error, isNull);
      session.close();
    });

    test('stops a stream and notifies middleware on cancellation', () async {
      final events = <String>[];
      final registry = ChatExtensionRegistry();
      registry.registerMiddleware(_Middleware(
        id: 'observer',
        order: 1,
        events: events,
      ));
      ChatGenerationTrace? observed;
      final pipeline = ChatGenerationPipeline(
        registry: registry,
        onGenerationFinished: (trace) => observed = trace,
      );
      final session = pipeline.startSession(
        chatId: 'chat-1',
        mode: ChatGenerationMode.continueResponse,
        config: _config,
      );
      final firstChunk = Completer<void>();
      final done = Completer<void>();
      final chunks = <String>[];

      session.generateStream(
        const [
          {'role': 'user', 'content': 'Continue'},
        ],
        (request) async* {
          yield const LLMStreamChunk(content: 'first');
          await request.cancellationToken.whenCancelled;
          yield const LLMStreamChunk(content: 'second');
        },
      ).listen(
        (chunk) {
          chunks.add(chunk.content!);
          firstChunk.complete();
        },
        onDone: done.complete,
        onError: done.completeError,
      );

      await firstChunk.future;
      await pipeline.cancelActiveSessions();
      await done.future;

      expect(chunks, ['first']);
      expect(events, contains('cancel:observer'));
      expect(observed?.cancelled, isTrue);
      expect(observed?.streaming, isTrue);
      session.close();
    });

    test('isolates a middleware that attempts to replace session scope',
        () async {
      final registry = ChatExtensionRegistry();
      registry.registerMiddleware(_ScopeReplacingMiddleware());
      final session = ChatGenerationPipeline(registry: registry).startSession(
        chatId: 'chat-1',
        mode: ChatGenerationMode.send,
        config: _config,
      );
      ChatGenerationRequest? transported;

      await session.generate(
        const [
          {'role': 'user', 'content': 'Hello'},
        ],
        (request) async {
          transported = request;
          return const LLMResponse(content: 'ok');
        },
      );

      expect(transported?.chatId, 'chat-1');
      expect(transported?.messages.single['content'], 'Hello');
      session.close();
    });
  });

  test('registry rejects duplicate extension IDs and supports disposal', () {
    final registry = ChatExtensionRegistry();
    final registration = registry.registerContributor(_Contributor(
      id: 'memory',
      onContribute: (_) async => ContextContribution(messages: const []),
    ));

    expect(
      () => registry.registerContributor(_Contributor(
        id: 'memory',
        onContribute: (_) async => ContextContribution(messages: const []),
      )),
      throwsStateError,
    );

    registration.dispose();
    expect(registry.contributors, isEmpty);
  });
}

const LLMConfig _config = LLMConfig(
  provider: LLMProvider.openAICompatible,
  model: 'test-model',
  apiKey: '',
  apiUrl: 'http://localhost',
  contextLength: 4096,
  maxTokens: 512,
  streamEnabled: false,
  autoSummarizeEnabled: false,
);

class _Contributor extends ContextContributor {
  _Contributor({
    required this.id,
    required this.onContribute,
    this.order = 0,
    this.maxTokens,
    this.enabled = true,
    this.onCancel,
  });

  @override
  final String id;
  @override
  final int order;
  @override
  final int? maxTokens;
  final bool enabled;
  final Future<ContextContribution> Function(ChatContextRequest request)
      onContribute;
  final void Function(ChatContextRequest request)? onCancel;

  @override
  bool isEnabled(ChatContextRequest request) => enabled;

  @override
  Future<ContextContribution> contribute(ChatContextRequest request) =>
      onContribute(request);

  @override
  void onCancelled(ChatContextRequest request) => onCancel?.call(request);
}

class _Middleware extends ChatGenerationMiddleware {
  _Middleware({
    required this.id,
    required this.order,
    required this.events,
    this.marker,
    this.recovery,
  });

  @override
  final String id;
  @override
  final int order;
  final List<String> events;
  final String? marker;
  final LLMResponse? recovery;

  @override
  ChatGenerationRequest beforeGeneration(ChatGenerationRequest request) {
    events.add('before:$id');
    if (marker == null) return request;
    return request.copyWith(messages: [
      ...request.messages,
      {'role': 'system', 'content': marker},
    ]);
  }

  @override
  void afterGeneration(
    ChatGenerationRequest request,
    ChatGenerationOutcome outcome,
  ) {
    events.add('after:$id:${outcome.recovered}');
  }

  @override
  LLMResponse? recoverFromError(
    ChatGenerationRequest request,
    Object error,
    StackTrace stackTrace,
  ) {
    events.add('recover:$id');
    return recovery;
  }

  @override
  void onCancelled(ChatGenerationRequest request) {
    events.add('cancel:$id');
  }
}

class _ScopeReplacingMiddleware extends ChatGenerationMiddleware {
  @override
  String get id => 'scope-replacer';

  @override
  ChatGenerationRequest beforeGeneration(ChatGenerationRequest request) {
    return ChatGenerationRequest(
      sessionId: request.sessionId,
      chatId: 'different-chat',
      mode: request.mode,
      messages: const [
        {'role': 'system', 'content': 'malicious replacement'},
      ],
      config: request.config,
      cancellationToken: request.cancellationToken,
    );
  }
}

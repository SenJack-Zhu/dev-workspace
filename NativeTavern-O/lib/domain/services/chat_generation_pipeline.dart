import 'dart:async';
import 'dart:math';

import 'package:native_tavern/domain/services/context_window_service.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/tokenizer_service.dart';

typedef ChatMessageMap = Map<String, dynamic>;
typedef ChatGenerationTransport = Future<LLMResponse> Function(
  ChatGenerationRequest request,
);
typedef ChatGenerationStreamTransport = Stream<LLMStreamChunk> Function(
  ChatGenerationRequest request,
);

enum ChatGenerationMode {
  send,
  regenerate,
  continueResponse,
  impersonate,
  groupResponse,
}

enum ContextContributionPlacement {
  beforeBase,
  beforeConversation,
  afterBase,
}

enum ContextContributionStatus {
  applied,
  disabled,
  failed,
  cancelled,
  skippedNoBudget,
}

enum ContextContributionItemStatus { included, truncated, dropped }

enum GenerationMiddlewarePhase {
  before,
  transform,
  after,
  error,
  cancelled,
}

class ChatGenerationCancelledException implements Exception {
  const ChatGenerationCancelledException([this.reason = 'Cancelled']);

  final String reason;

  @override
  String toString() => 'ChatGenerationCancelledException: $reason';
}

class ChatCancellationToken {
  final Completer<void> _cancelled = Completer<void>();
  String? _reason;

  bool get isCancelled => _cancelled.isCompleted;
  String? get reason => _reason;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel([String reason = 'Cancelled']) {
    if (isCancelled) return;
    _reason = reason;
    _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw ChatGenerationCancelledException(_reason ?? 'Cancelled');
    }
  }
}

class ChatContextRequest {
  ChatContextRequest({
    required this.sessionId,
    required this.chatId,
    required this.mode,
    required List<ChatMessageMap> baseMessages,
    required this.inputTokenBudget,
    required this.availableContributionTokens,
    required this.cancellationToken,
    int? conversationStartIndex,
    this.characterId,
    this.groupId,
    Map<String, Object?> metadata = const {},
  })  : conversationStartIndex = conversationStartIndex ??
            _defaultConversationStartIndex(baseMessages),
        baseMessages = _immutableMessages(baseMessages),
        metadata = Map<String, Object?>.unmodifiable(metadata);

  final String sessionId;
  final String chatId;
  final String? characterId;
  final String? groupId;
  final ChatGenerationMode mode;
  final List<ChatMessageMap> baseMessages;
  final int inputTokenBudget;
  final int availableContributionTokens;
  final int conversationStartIndex;
  final ChatCancellationToken cancellationToken;
  final Map<String, Object?> metadata;

  ChatContextRequest copyWith({
    List<ChatMessageMap>? baseMessages,
    int? availableContributionTokens,
  }) {
    return ChatContextRequest(
      sessionId: sessionId,
      chatId: chatId,
      characterId: characterId,
      groupId: groupId,
      mode: mode,
      baseMessages: baseMessages ?? this.baseMessages,
      inputTokenBudget: inputTokenBudget,
      availableContributionTokens:
          availableContributionTokens ?? this.availableContributionTokens,
      conversationStartIndex: conversationStartIndex,
      cancellationToken: cancellationToken,
      metadata: metadata,
    );
  }
}

class ContextContribution {
  ContextContribution({
    required List<ChatMessageMap> messages,
    this.placement = ContextContributionPlacement.beforeConversation,
    List<String> itemIds = const [],
    Map<String, Object?> metadata = const {},
  })  : assert(
          itemIds.isEmpty || itemIds.length == messages.length,
          'itemIds must be empty or align one-to-one with messages.',
        ),
        messages = _immutableMessages(messages),
        itemIds = List<String>.unmodifiable(itemIds),
        metadata = _immutableMetadata(metadata);

  final List<ChatMessageMap> messages;
  final ContextContributionPlacement placement;
  final List<String> itemIds;
  final Map<String, Object?> metadata;
}

abstract class ContextContributor {
  String get id;
  int get order => 0;
  int? get maxTokens => null;

  FutureOr<bool> isEnabled(ChatContextRequest request) => true;

  Future<ContextContribution> contribute(ChatContextRequest request);

  FutureOr<void> onCancelled(ChatContextRequest request) {}
}

class ContextContributionItemTrace {
  const ContextContributionItemTrace({
    required this.itemId,
    required this.status,
    required this.originalTokens,
    required this.usedTokens,
  });

  final String itemId;
  final ContextContributionItemStatus status;
  final int originalTokens;
  final int usedTokens;
}

class ContextContributionTrace {
  ContextContributionTrace({
    required this.contributorId,
    required this.order,
    required this.status,
    required this.allocatedTokens,
    required this.originalTokens,
    required this.usedTokens,
    required this.originalMessageCount,
    required this.truncatedMessageCount,
    required this.droppedMessageCount,
    required this.elapsed,
    required List<ChatMessageMap> injectedMessages,
    List<ContextContributionItemTrace> itemTraces = const [],
    Map<String, Object?> metadata = const {},
    this.placement,
    this.error,
  })  : injectedMessages = _immutableMessages(injectedMessages),
        itemTraces =
            List<ContextContributionItemTrace>.unmodifiable(itemTraces),
        metadata = _immutableMetadata(metadata);

  final String contributorId;
  final int order;
  final ContextContributionStatus status;
  final ContextContributionPlacement? placement;
  final int allocatedTokens;
  final int originalTokens;
  final int usedTokens;
  final int originalMessageCount;
  final int truncatedMessageCount;
  final int droppedMessageCount;
  final Duration elapsed;
  final List<ChatMessageMap> injectedMessages;
  final List<ContextContributionItemTrace> itemTraces;
  final Map<String, Object?> metadata;
  final String? error;
}

class ContextAssemblyResult {
  ContextAssemblyResult({
    required this.sessionId,
    required this.chatId,
    required this.mode,
    required List<ChatMessageMap> baseMessages,
    required List<ChatMessageMap> messages,
    required this.inputTokenBudget,
    required this.baseEstimatedTokens,
    required this.estimatedTokens,
    required List<ContextContributionTrace> traces,
    required this.startedAt,
    required this.completedAt,
    required this.cancelled,
    this.characterId,
    this.groupId,
  })  : baseMessages = _immutableMessages(baseMessages),
        messages = _immutableMessages(messages),
        traces = List<ContextContributionTrace>.unmodifiable(traces);

  final String sessionId;
  final String chatId;
  final String? characterId;
  final String? groupId;
  final ChatGenerationMode mode;
  final List<ChatMessageMap> baseMessages;
  final List<ChatMessageMap> messages;
  final int inputTokenBudget;
  final int baseEstimatedTokens;
  final int estimatedTokens;
  final List<ContextContributionTrace> traces;
  final DateTime startedAt;
  final DateTime completedAt;
  final bool cancelled;

  int get contributedTokens => max(0, estimatedTokens - baseEstimatedTokens);
  bool get wasTrimmed => traces.any(
        (trace) =>
            trace.truncatedMessageCount > 0 || trace.droppedMessageCount > 0,
      );
}

class ChatGenerationRequest {
  ChatGenerationRequest({
    required this.sessionId,
    required this.chatId,
    required this.mode,
    required List<ChatMessageMap> messages,
    required this.config,
    required this.cancellationToken,
    this.characterId,
    this.groupId,
    Map<String, Object?> metadata = const {},
  })  : messages = _immutableMessages(messages),
        metadata = Map<String, Object?>.unmodifiable(metadata);

  final String sessionId;
  final String chatId;
  final String? characterId;
  final String? groupId;
  final ChatGenerationMode mode;
  final List<ChatMessageMap> messages;
  final LLMConfig config;
  final ChatCancellationToken cancellationToken;
  final Map<String, Object?> metadata;

  ChatGenerationRequest copyWith({
    List<ChatMessageMap>? messages,
    LLMConfig? config,
    Map<String, Object?>? metadata,
  }) {
    return ChatGenerationRequest(
      sessionId: sessionId,
      chatId: chatId,
      characterId: characterId,
      groupId: groupId,
      mode: mode,
      messages: messages ?? this.messages,
      config: config ?? this.config,
      cancellationToken: cancellationToken,
      metadata: metadata ?? this.metadata,
    );
  }
}

class ChatGenerationOutcome {
  const ChatGenerationOutcome({
    required this.response,
    required this.streaming,
    required this.cancelled,
    required this.recovered,
    required this.elapsed,
  });

  final LLMResponse response;
  final bool streaming;
  final bool cancelled;
  final bool recovered;
  final Duration elapsed;
}

abstract class ChatGenerationMiddleware {
  String get id;
  int get order => 0;

  FutureOr<bool> isEnabled(ChatGenerationRequest request) => true;

  FutureOr<ChatGenerationRequest> beforeGeneration(
    ChatGenerationRequest request,
  ) =>
      request;

  FutureOr<void> afterGeneration(
    ChatGenerationRequest request,
    ChatGenerationOutcome outcome,
  ) {}

  FutureOr<LLMResponse?> recoverFromError(
    ChatGenerationRequest request,
    Object error,
    StackTrace stackTrace,
  ) =>
      null;

  FutureOr<void> onCancelled(ChatGenerationRequest request) {}
}

/// Optional middleware capability for consumers that need to validate or
/// replace a complete model response before chat persistence.
///
/// Streaming is buffered whenever an enabled middleware implements this
/// interface, preventing structured control payloads from being exposed as
/// partial assistant text before they have been validated.
abstract interface class ChatGenerationResponseTransformer {
  FutureOr<LLMResponse> transformResponse(
    ChatGenerationRequest request,
    LLMResponse response,
  );
}

class GenerationMiddlewareTrace {
  const GenerationMiddlewareTrace({
    required this.middlewareId,
    required this.order,
    required this.phase,
    required this.elapsed,
    this.error,
    this.recovered = false,
  });

  final String middlewareId;
  final int order;
  final GenerationMiddlewarePhase phase;
  final Duration elapsed;
  final String? error;
  final bool recovered;
}

class ChatGenerationTrace {
  ChatGenerationTrace({
    required this.sessionId,
    required this.mode,
    required this.streaming,
    required this.cancelled,
    required this.recovered,
    required List<GenerationMiddlewareTrace> middlewareTraces,
    required this.startedAt,
    required this.completedAt,
    this.error,
  }) : middlewareTraces =
            List<GenerationMiddlewareTrace>.unmodifiable(middlewareTraces);

  final String sessionId;
  final ChatGenerationMode mode;
  final bool streaming;
  final bool cancelled;
  final bool recovered;
  final List<GenerationMiddlewareTrace> middlewareTraces;
  final DateTime startedAt;
  final DateTime completedAt;
  final String? error;
}

class ChatExtensionRegistration {
  ChatExtensionRegistration(this._dispose);

  final void Function() _dispose;
  bool _isDisposed = false;

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _dispose();
  }
}

class ChatExtensionRegistry {
  final Map<String, ContextContributor> _contributors = {};
  final Map<String, ChatGenerationMiddleware> _middlewares = {};

  List<ContextContributor> get contributors => _sorted(_contributors.values);
  List<ChatGenerationMiddleware> get middlewares =>
      _sorted(_middlewares.values);

  ChatExtensionRegistration registerContributor(
    ContextContributor contributor,
  ) {
    _register(_contributors, contributor.id, contributor);
    return ChatExtensionRegistration(() {
      if (identical(_contributors[contributor.id], contributor)) {
        _contributors.remove(contributor.id);
      }
    });
  }

  ChatExtensionRegistration registerMiddleware(
    ChatGenerationMiddleware middleware,
  ) {
    _register(_middlewares, middleware.id, middleware);
    return ChatExtensionRegistration(() {
      if (identical(_middlewares[middleware.id], middleware)) {
        _middlewares.remove(middleware.id);
      }
    });
  }

  void clear() {
    _contributors.clear();
    _middlewares.clear();
  }

  static void _register<T>(Map<String, T> values, String id, T value) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Extension ID cannot be empty.');
    }
    if (values.containsKey(id)) {
      throw StateError('A chat extension with ID "$id" is already registered.');
    }
    values[id] = value;
  }

  static List<T> _sorted<T>(Iterable<T> values) {
    final result = values.toList();
    result.sort((left, right) {
      final leftOrder = left is ContextContributor
          ? left.order
          : (left as ChatGenerationMiddleware).order;
      final rightOrder = right is ContextContributor
          ? right.order
          : (right as ChatGenerationMiddleware).order;
      final byOrder = leftOrder.compareTo(rightOrder);
      if (byOrder != 0) return byOrder;
      final leftId = left is ContextContributor
          ? left.id
          : (left as ChatGenerationMiddleware).id;
      final rightId = right is ContextContributor
          ? right.id
          : (right as ChatGenerationMiddleware).id;
      return leftId.compareTo(rightId);
    });
    return List<T>.unmodifiable(result);
  }
}

class ChatGenerationPipeline {
  ChatGenerationPipeline({
    required this.registry,
    TokenizerService? tokenizer,
    ContextWindowService? contextWindowService,
    this.onContextAssembled,
    this.onGenerationFinished,
  })  : _tokenizer = tokenizer ?? TokenizerService(),
        _contextWindowService = contextWindowService ?? ContextWindowService();

  final ChatExtensionRegistry registry;
  final TokenizerService _tokenizer;
  final ContextWindowService _contextWindowService;
  final void Function(ContextAssemblyResult result)? onContextAssembled;
  final void Function(ChatGenerationTrace trace)? onGenerationFinished;
  final Set<ChatGenerationSession> _activeSessions = {};
  int _nextSessionId = 0;

  ChatGenerationSession startSession({
    required String chatId,
    required ChatGenerationMode mode,
    required LLMConfig config,
    String? characterId,
    String? groupId,
    Map<String, Object?> metadata = const {},
  }) {
    final session = ChatGenerationSession._(
      pipeline: this,
      sessionId: '${DateTime.now().microsecondsSinceEpoch}-${_nextSessionId++}',
      chatId: chatId,
      characterId: characterId,
      groupId: groupId,
      mode: mode,
      config: config,
      metadata: metadata,
    );
    _activeSessions.add(session);
    return session;
  }

  Future<void> cancelActiveSessions([
    String reason = 'Cancelled by user',
  ]) async {
    final sessions = _activeSessions.toList(growable: false);
    await Future.wait(sessions.map((session) => session.cancel(reason)));
  }

  Future<void> dispose() async {
    await cancelActiveSessions('Pipeline disposed');
    for (final session in _activeSessions.toList(growable: false)) {
      session.close();
    }
  }

  void _remove(ChatGenerationSession session) {
    _activeSessions.remove(session);
  }

  int _inputBudget(LLMConfig config) {
    if (config.contextLength <= 0) return 1 << 30;
    final responseTokens = _contextWindowService.effectiveResponseTokenLimit(
      contextLength: config.contextLength,
      requestedTokens: config.maxTokens,
    );
    final availableForInput = max(1, config.contextLength - responseTokens);
    final safetyMargin = min(
      max(32, (config.contextLength * 0.05).ceil()),
      max(0, availableForInput - 1),
    );
    return max(1, availableForInput - safetyMargin);
  }

  int _estimateMessages(List<ChatMessageMap> messages) => messages.fold(
        0,
        (total, message) => total + _estimateMessage(message),
      );

  int _estimateMessage(ChatMessageMap message) {
    final content = message['content'];
    var tokens = 4;
    if (content is String) {
      tokens += _tokenizer.estimateTokenCount(content);
    } else if (content is List) {
      for (final part in content) {
        if (part is Map && part['text'] is String) {
          tokens += _tokenizer.estimateTokenCount(part['text'] as String);
        } else {
          tokens += 1024;
        }
      }
    } else if (content != null) {
      tokens += _tokenizer.estimateTokenCount(content.toString());
    }
    return tokens;
  }

  _FittedContribution _fitContribution(
    List<ChatMessageMap> messages,
    int tokenBudget,
    List<String> itemIds,
  ) {
    final fitted = <ChatMessageMap>[];
    final itemTraces = <ContextContributionItemTrace>[];
    var remaining = max(0, tokenBudget);
    var truncated = 0;
    var dropped = 0;

    void recordItem(
      int index,
      ContextContributionItemStatus status,
      int originalTokens,
      int usedTokens,
    ) {
      if (itemIds.isEmpty) return;
      itemTraces.add(
        ContextContributionItemTrace(
          itemId: itemIds[index],
          status: status,
          originalTokens: originalTokens,
          usedTokens: usedTokens,
        ),
      );
    }

    for (var index = 0; index < messages.length; index++) {
      final message = Map<String, dynamic>.from(messages[index]);
      final tokens = _estimateMessage(message);
      if (tokens <= remaining) {
        fitted.add(message);
        remaining -= tokens;
        recordItem(
          index,
          ContextContributionItemStatus.included,
          tokens,
          tokens,
        );
        continue;
      }

      final content = message['content'];
      if (content is String && remaining > 12) {
        final availableContentTokens = max(1, remaining - 4);
        final maximumCharacters = max(
          1,
          (availableContentTokens * TokenizerService.charsPerTokenRatio)
              .floor(),
        );
        const marker = '\n[truncated]';
        var candidateLength = max(
          1,
          min(content.length, maximumCharacters - marker.length),
        );
        message['content'] = '${content.substring(0, candidateLength)}$marker';
        while (_estimateMessage(message) > remaining && candidateLength > 1) {
          candidateLength = max(1, candidateLength - 4);
          message['content'] =
              '${content.substring(0, candidateLength)}$marker';
        }
        if (_estimateMessage(message) <= remaining) {
          final usedTokens = _estimateMessage(message);
          fitted.add(message);
          remaining -= usedTokens;
          truncated++;
          recordItem(
            index,
            ContextContributionItemStatus.truncated,
            tokens,
            usedTokens,
          );
        } else {
          dropped++;
          recordItem(index, ContextContributionItemStatus.dropped, tokens, 0);
        }
      } else {
        dropped++;
        recordItem(index, ContextContributionItemStatus.dropped, tokens, 0);
      }
      for (var droppedIndex = index + 1;
          droppedIndex < messages.length;
          droppedIndex++) {
        recordItem(
          droppedIndex,
          ContextContributionItemStatus.dropped,
          _estimateMessage(messages[droppedIndex]),
          0,
        );
      }
      dropped += messages.length - index - 1;
      break;
    }

    return _FittedContribution(
      messages: fitted,
      tokens: tokenBudget - remaining,
      truncatedMessages: truncated,
      droppedMessages: dropped,
      itemTraces: itemTraces,
    );
  }
}

class ChatGenerationSession {
  ChatGenerationSession._({
    required ChatGenerationPipeline pipeline,
    required this.sessionId,
    required this.chatId,
    required this.characterId,
    required this.groupId,
    required this.mode,
    required this.config,
    required Map<String, Object?> metadata,
  })  : _pipeline = pipeline,
        metadata = Map<String, Object?>.unmodifiable(metadata);

  final ChatGenerationPipeline _pipeline;
  final String sessionId;
  final String chatId;
  final String? characterId;
  final String? groupId;
  final ChatGenerationMode mode;
  final LLMConfig config;
  final Map<String, Object?> metadata;
  final ChatCancellationToken cancellationToken = ChatCancellationToken();

  ChatContextRequest? _lastContextRequest;
  ChatGenerationRequest? _lastGenerationRequest;
  bool _closed = false;
  bool _cancellationNotified = false;

  Future<ContextAssemblyResult> assemble(
    List<ChatMessageMap> baseMessages, {
    int? conversationStartIndex,
  }) async {
    final startedAt = DateTime.now();
    final inputBudget = _pipeline._inputBudget(config);
    final immutableBase = _immutableMessages(baseMessages);
    final resolvedConversationStartIndex = conversationStartIndex == null
        ? immutableBase.indexWhere((message) => message['role'] != 'system')
        : conversationStartIndex.clamp(0, immutableBase.length).toInt();
    final baseTokens = _pipeline._estimateMessages(immutableBase);
    var remaining = max(0, inputBudget - baseTokens);
    final traces = <ContextContributionTrace>[];
    final beforeBase = <ChatMessageMap>[];
    final beforeConversation = <ChatMessageMap>[];
    final afterBase = <ChatMessageMap>[];

    var request = ChatContextRequest(
      sessionId: sessionId,
      chatId: chatId,
      characterId: characterId,
      groupId: groupId,
      mode: mode,
      baseMessages: immutableBase,
      inputTokenBudget: inputBudget,
      availableContributionTokens: remaining,
      conversationStartIndex: resolvedConversationStartIndex < 0
          ? immutableBase.length
          : resolvedConversationStartIndex,
      cancellationToken: cancellationToken,
      metadata: metadata,
    );
    _lastContextRequest = request;

    for (final contributor in _pipeline.registry.contributors) {
      final stopwatch = Stopwatch()..start();
      if (cancellationToken.isCancelled) {
        traces.add(_emptyContributionTrace(
          contributor,
          ContextContributionStatus.cancelled,
          stopwatch.elapsed,
        ));
        break;
      }

      bool enabled;
      try {
        enabled = await contributor.isEnabled(request);
      } catch (error) {
        traces.add(_emptyContributionTrace(
          contributor,
          ContextContributionStatus.failed,
          stopwatch.elapsed,
          error: error.toString(),
        ));
        continue;
      }
      if (!enabled) {
        traces.add(_emptyContributionTrace(
          contributor,
          ContextContributionStatus.disabled,
          stopwatch.elapsed,
        ));
        continue;
      }

      final allocation = min(remaining, contributor.maxTokens ?? remaining);
      if (allocation <= 0) {
        traces.add(_emptyContributionTrace(
          contributor,
          ContextContributionStatus.skippedNoBudget,
          stopwatch.elapsed,
        ));
        continue;
      }

      try {
        request = request.copyWith(availableContributionTokens: remaining);
        _lastContextRequest = request;
        final contribution = await contributor.contribute(request);
        if (cancellationToken.isCancelled) {
          traces.add(_emptyContributionTrace(
            contributor,
            ContextContributionStatus.cancelled,
            stopwatch.elapsed,
          ));
          break;
        }

        final originalTokens =
            _pipeline._estimateMessages(contribution.messages);
        final fitted = _pipeline._fitContribution(
          contribution.messages,
          allocation,
          contribution.itemIds,
        );
        remaining -= fitted.tokens;
        switch (contribution.placement) {
          case ContextContributionPlacement.beforeBase:
            beforeBase.addAll(fitted.messages);
          case ContextContributionPlacement.beforeConversation:
            beforeConversation.addAll(fitted.messages);
          case ContextContributionPlacement.afterBase:
            afterBase.addAll(fitted.messages);
        }
        traces.add(ContextContributionTrace(
          contributorId: contributor.id,
          order: contributor.order,
          status: ContextContributionStatus.applied,
          placement: contribution.placement,
          allocatedTokens: allocation,
          originalTokens: originalTokens,
          usedTokens: fitted.tokens,
          originalMessageCount: contribution.messages.length,
          truncatedMessageCount: fitted.truncatedMessages,
          droppedMessageCount: fitted.droppedMessages,
          elapsed: stopwatch.elapsed,
          injectedMessages: fitted.messages,
          itemTraces: fitted.itemTraces,
          metadata: contribution.metadata,
        ));
      } catch (error) {
        traces.add(_emptyContributionTrace(
          contributor,
          cancellationToken.isCancelled
              ? ContextContributionStatus.cancelled
              : ContextContributionStatus.failed,
          stopwatch.elapsed,
          error: cancellationToken.isCancelled ? null : error.toString(),
        ));
        if (cancellationToken.isCancelled) break;
      }
    }

    final assembled = <ChatMessageMap>[
      ...beforeBase,
      ...immutableBase.map(_copyMessage),
    ];
    assembled.insertAll(
      beforeBase.length + request.conversationStartIndex,
      beforeConversation,
    );
    assembled.addAll(afterBase);

    final result = ContextAssemblyResult(
      sessionId: sessionId,
      chatId: chatId,
      characterId: characterId,
      groupId: groupId,
      mode: mode,
      baseMessages: immutableBase,
      messages: assembled,
      inputTokenBudget: inputBudget,
      baseEstimatedTokens: baseTokens,
      estimatedTokens: _pipeline._estimateMessages(assembled),
      traces: traces,
      startedAt: startedAt,
      completedAt: DateTime.now(),
      cancelled: cancellationToken.isCancelled,
    );
    try {
      _pipeline.onContextAssembled?.call(result);
    } catch (_) {
      // Diagnostics must never break chat generation.
    }
    return result;
  }

  Future<LLMResponse> generate(
    List<ChatMessageMap> messages,
    ChatGenerationTransport transport,
  ) async {
    final startedAt = DateTime.now();
    final middlewareTraces = <GenerationMiddlewareTrace>[];
    var request = _request(messages);
    _lastGenerationRequest = request;
    final active = await _runBefore(request, middlewareTraces);
    request = active.request;
    _lastGenerationRequest = request;
    LLMResponse response = const LLMResponse(content: '');
    var recovered = false;
    Object? terminalError;
    StackTrace? terminalStackTrace;

    try {
      if (!cancellationToken.isCancelled) {
        response = await transport(request);
      }
    } catch (error, stackTrace) {
      if (!cancellationToken.isCancelled) {
        final recovery = await _recover(
          active.middlewares,
          request,
          error,
          stackTrace,
          middlewareTraces,
        );
        if (recovery != null) {
          response = recovery;
          recovered = true;
        } else {
          terminalError = error;
          terminalStackTrace = stackTrace;
        }
      }
    }

    if (terminalError == null && !cancellationToken.isCancelled) {
      response = await _runTransforms(
        active.middlewares,
        request,
        response,
        middlewareTraces,
      );
    }

    final outcome = ChatGenerationOutcome(
      response: response,
      streaming: false,
      cancelled: cancellationToken.isCancelled,
      recovered: recovered,
      elapsed: DateTime.now().difference(startedAt),
    );
    await _runAfter(
      active.middlewares,
      request,
      outcome,
      middlewareTraces,
    );
    _finishTrace(
      startedAt: startedAt,
      streaming: false,
      recovered: recovered,
      middlewareTraces: middlewareTraces,
      error: terminalError,
    );
    if (terminalError != null) {
      Error.throwWithStackTrace(terminalError, terminalStackTrace!);
    }
    if (cancellationToken.isCancelled) {
      throw ChatGenerationCancelledException(
        cancellationToken.reason ?? 'Cancelled',
      );
    }
    return response;
  }

  Stream<LLMStreamChunk> generateStream(
    List<ChatMessageMap> messages,
    ChatGenerationStreamTransport transport,
  ) async* {
    final startedAt = DateTime.now();
    final middlewareTraces = <GenerationMiddlewareTrace>[];
    var request = _request(messages);
    _lastGenerationRequest = request;
    final active = await _runBefore(request, middlewareTraces);
    request = active.request;
    _lastGenerationRequest = request;
    final content = StringBuffer();
    final reasoning = StringBuffer();
    final buffersResponse = active.middlewares
        .any((middleware) => middleware is ChatGenerationResponseTransformer);
    var recovered = false;
    Object? terminalError;
    StackTrace? terminalStackTrace;

    try {
      if (!cancellationToken.isCancelled) {
        await for (final chunk in transport(request)) {
          if (cancellationToken.isCancelled) break;
          if (chunk.content != null) content.write(chunk.content);
          if (chunk.reasoning != null) reasoning.write(chunk.reasoning);
          if (!buffersResponse) yield chunk;
        }
      }
    } catch (error, stackTrace) {
      if (!cancellationToken.isCancelled) {
        final recovery = await _recover(
          active.middlewares,
          request,
          error,
          stackTrace,
          middlewareTraces,
        );
        if (recovery != null) {
          recovered = true;
          if (recovery.reasoning?.isNotEmpty == true) {
            reasoning.write(recovery.reasoning);
            if (!buffersResponse) {
              yield LLMStreamChunk(
                reasoning: recovery.reasoning,
                isReasoningChunk: true,
              );
            }
          }
          if (recovery.content.isNotEmpty) {
            content.write(recovery.content);
            if (!buffersResponse) {
              yield LLMStreamChunk(content: recovery.content);
            }
          }
        } else {
          terminalError = error;
          terminalStackTrace = stackTrace;
        }
      }
    }

    var response = LLMResponse(
      content: content.toString(),
      reasoning: reasoning.isEmpty ? null : reasoning.toString(),
    );
    if (terminalError == null && !cancellationToken.isCancelled) {
      response = await _runTransforms(
        active.middlewares,
        request,
        response,
        middlewareTraces,
      );
    }
    final outcome = ChatGenerationOutcome(
      response: response,
      streaming: true,
      cancelled: cancellationToken.isCancelled,
      recovered: recovered,
      elapsed: DateTime.now().difference(startedAt),
    );
    await _runAfter(
      active.middlewares,
      request,
      outcome,
      middlewareTraces,
    );
    _finishTrace(
      startedAt: startedAt,
      streaming: true,
      recovered: recovered,
      middlewareTraces: middlewareTraces,
      error: terminalError,
    );
    if (terminalError != null) {
      Error.throwWithStackTrace(terminalError, terminalStackTrace!);
    }
    if (cancellationToken.isCancelled &&
        (buffersResponse || (content.isEmpty && reasoning.isEmpty))) {
      throw ChatGenerationCancelledException(
        cancellationToken.reason ?? 'Cancelled',
      );
    }
    if (buffersResponse) {
      if (response.reasoning?.isNotEmpty == true) {
        yield LLMStreamChunk(
          reasoning: response.reasoning,
          isReasoningChunk: true,
        );
      }
      if (response.content.isNotEmpty) {
        yield LLMStreamChunk(content: response.content);
      }
    }
  }

  Future<void> cancel([String reason = 'Cancelled by user']) async {
    cancellationToken.cancel(reason);
    if (_cancellationNotified) return;
    _cancellationNotified = true;

    final contextRequest = _lastContextRequest;
    final generationRequest = _lastGenerationRequest;
    final callbacks = <Future<void>>[];
    if (contextRequest != null) {
      for (final contributor in _pipeline.registry.contributors) {
        callbacks.add(Future.sync(() => contributor.onCancelled(contextRequest))
            .catchError((_) {}));
      }
    }
    if (generationRequest != null) {
      for (final middleware in _pipeline.registry.middlewares) {
        callbacks.add(Future.sync(
          () => middleware.onCancelled(generationRequest),
        ).catchError((_) {}));
      }
    }
    await Future.wait(callbacks);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _pipeline._remove(this);
  }

  ChatGenerationRequest _request(List<ChatMessageMap> messages) {
    return ChatGenerationRequest(
      sessionId: sessionId,
      chatId: chatId,
      characterId: characterId,
      groupId: groupId,
      mode: mode,
      messages: messages,
      config: config,
      cancellationToken: cancellationToken,
      metadata: metadata,
    );
  }

  Future<_ActiveMiddlewares> _runBefore(
    ChatGenerationRequest initialRequest,
    List<GenerationMiddlewareTrace> traces,
  ) async {
    var request = initialRequest;
    final active = <ChatGenerationMiddleware>[];
    for (final middleware in _pipeline.registry.middlewares) {
      final enabledWatch = Stopwatch()..start();
      try {
        if (!await middleware.isEnabled(request)) continue;
      } catch (error) {
        traces.add(GenerationMiddlewareTrace(
          middlewareId: middleware.id,
          order: middleware.order,
          phase: GenerationMiddlewarePhase.before,
          elapsed: enabledWatch.elapsed,
          error: error.toString(),
        ));
        continue;
      }
      if (cancellationToken.isCancelled) break;
      final stopwatch = Stopwatch()..start();
      try {
        final updatedRequest = await middleware.beforeGeneration(request);
        if (updatedRequest.sessionId != sessionId ||
            updatedRequest.chatId != chatId ||
            updatedRequest.characterId != characterId ||
            updatedRequest.groupId != groupId ||
            updatedRequest.mode != mode ||
            !identical(updatedRequest.cancellationToken, cancellationToken)) {
          throw StateError(
            'Middleware ${middleware.id} cannot replace generation scope.',
          );
        }
        request = updatedRequest;
        active.add(middleware);
        traces.add(GenerationMiddlewareTrace(
          middlewareId: middleware.id,
          order: middleware.order,
          phase: GenerationMiddlewarePhase.before,
          elapsed: stopwatch.elapsed,
        ));
      } catch (error) {
        traces.add(GenerationMiddlewareTrace(
          middlewareId: middleware.id,
          order: middleware.order,
          phase: GenerationMiddlewarePhase.before,
          elapsed: stopwatch.elapsed,
          error: error.toString(),
        ));
      }
    }
    return _ActiveMiddlewares(request, active);
  }

  Future<void> _runAfter(
    List<ChatGenerationMiddleware> middlewares,
    ChatGenerationRequest request,
    ChatGenerationOutcome outcome,
    List<GenerationMiddlewareTrace> traces,
  ) async {
    for (final middleware in middlewares.reversed) {
      final stopwatch = Stopwatch()..start();
      try {
        await middleware.afterGeneration(request, outcome);
        traces.add(GenerationMiddlewareTrace(
          middlewareId: middleware.id,
          order: middleware.order,
          phase: GenerationMiddlewarePhase.after,
          elapsed: stopwatch.elapsed,
        ));
      } catch (error) {
        traces.add(GenerationMiddlewareTrace(
          middlewareId: middleware.id,
          order: middleware.order,
          phase: GenerationMiddlewarePhase.after,
          elapsed: stopwatch.elapsed,
          error: error.toString(),
        ));
      }
    }
  }

  Future<LLMResponse> _runTransforms(
    List<ChatGenerationMiddleware> middlewares,
    ChatGenerationRequest request,
    LLMResponse initialResponse,
    List<GenerationMiddlewareTrace> traces,
  ) async {
    var response = initialResponse;
    for (final middleware in middlewares.reversed) {
      if (middleware is! ChatGenerationResponseTransformer) continue;
      final transformer = middleware as ChatGenerationResponseTransformer;
      final stopwatch = Stopwatch()..start();
      try {
        response = await transformer.transformResponse(request, response);
        traces.add(GenerationMiddlewareTrace(
          middlewareId: middleware.id,
          order: middleware.order,
          phase: GenerationMiddlewarePhase.transform,
          elapsed: stopwatch.elapsed,
        ));
      } catch (error) {
        traces.add(GenerationMiddlewareTrace(
          middlewareId: middleware.id,
          order: middleware.order,
          phase: GenerationMiddlewarePhase.transform,
          elapsed: stopwatch.elapsed,
          error: error.toString(),
        ));
      }
    }
    return response;
  }

  Future<LLMResponse?> _recover(
    List<ChatGenerationMiddleware> middlewares,
    ChatGenerationRequest request,
    Object error,
    StackTrace stackTrace,
    List<GenerationMiddlewareTrace> traces,
  ) async {
    for (final middleware in middlewares.reversed) {
      final stopwatch = Stopwatch()..start();
      try {
        final response =
            await middleware.recoverFromError(request, error, stackTrace);
        traces.add(GenerationMiddlewareTrace(
          middlewareId: middleware.id,
          order: middleware.order,
          phase: GenerationMiddlewarePhase.error,
          elapsed: stopwatch.elapsed,
          recovered: response != null,
        ));
        if (response != null) return response;
      } catch (recoveryError) {
        traces.add(GenerationMiddlewareTrace(
          middlewareId: middleware.id,
          order: middleware.order,
          phase: GenerationMiddlewarePhase.error,
          elapsed: stopwatch.elapsed,
          error: recoveryError.toString(),
        ));
      }
    }
    return null;
  }

  void _finishTrace({
    required DateTime startedAt,
    required bool streaming,
    required bool recovered,
    required List<GenerationMiddlewareTrace> middlewareTraces,
    Object? error,
  }) {
    try {
      _pipeline.onGenerationFinished?.call(ChatGenerationTrace(
        sessionId: sessionId,
        mode: mode,
        streaming: streaming,
        cancelled: cancellationToken.isCancelled,
        recovered: recovered,
        middlewareTraces: middlewareTraces,
        startedAt: startedAt,
        completedAt: DateTime.now(),
        error: error?.toString(),
      ));
    } catch (_) {
      // Diagnostics must never break chat generation.
    }
  }

  ContextContributionTrace _emptyContributionTrace(
    ContextContributor contributor,
    ContextContributionStatus status,
    Duration elapsed, {
    String? error,
  }) {
    return ContextContributionTrace(
      contributorId: contributor.id,
      order: contributor.order,
      status: status,
      allocatedTokens: 0,
      originalTokens: 0,
      usedTokens: 0,
      originalMessageCount: 0,
      truncatedMessageCount: 0,
      droppedMessageCount: 0,
      elapsed: elapsed,
      injectedMessages: const [],
      error: error,
    );
  }
}

class _FittedContribution {
  const _FittedContribution({
    required this.messages,
    required this.tokens,
    required this.truncatedMessages,
    required this.droppedMessages,
    required this.itemTraces,
  });

  final List<ChatMessageMap> messages;
  final int tokens;
  final int truncatedMessages;
  final int droppedMessages;
  final List<ContextContributionItemTrace> itemTraces;
}

class _ActiveMiddlewares {
  const _ActiveMiddlewares(this.request, this.middlewares);

  final ChatGenerationRequest request;
  final List<ChatGenerationMiddleware> middlewares;
}

List<ChatMessageMap> _immutableMessages(Iterable<ChatMessageMap> messages) =>
    List<ChatMessageMap>.unmodifiable(messages.map(_copyMessage));

int _defaultConversationStartIndex(List<ChatMessageMap> messages) {
  final index = messages.indexWhere((message) => message['role'] != 'system');
  return index < 0 ? messages.length : index;
}

Map<String, Object?> _immutableMetadata(Map<String, Object?> metadata) =>
    Map<String, Object?>.unmodifiable(
      metadata.map((key, value) => MapEntry(key, _copyValue(value))),
    );

ChatMessageMap _copyMessage(ChatMessageMap message) =>
    Map<String, dynamic>.unmodifiable(
      message.map((key, value) => MapEntry(key, _copyValue(value))),
    );

dynamic _copyValue(dynamic value) {
  if (value is Map) {
    return Map<dynamic, dynamic>.unmodifiable(
      value.map((key, nestedValue) => MapEntry(key, _copyValue(nestedValue))),
    );
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(value.map(_copyValue));
  }
  return value;
}

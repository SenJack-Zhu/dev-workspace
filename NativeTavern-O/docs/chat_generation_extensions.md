# Chat generation extensions

`ChatGenerationPipeline` is the shared boundary for features that add chat
context or wrap an LLM generation. Feature modules register extensions through
`chatExtensionRegistryProvider`; they do not modify `chat_providers.dart`.

## Context contributors

A contributor declares a stable ID, deterministic order, and optional token
limit. Registration returns a handle that must be disposed with the feature
provider.

```dart
final registration = ref
    .read(chatExtensionRegistryProvider)
    .registerContributor(MemoryContextContributor(repository));
ref.onDispose(registration.dispose);
```

Implement `ContextContributor.contribute` to return one or more provider-ready
message maps. The available global budget and cancellation token are included
in `ChatContextRequest`.

- Lower `order` values run first. Equal values are ordered by extension ID.
- `maxTokens` limits one contributor. The pipeline also enforces the remaining
  request budget across all contributors.
- Oversized string messages are truncated deterministically; later messages
  are dropped when the allocation is exhausted.
- `beforeBase` is for instructions that must lead the request.
- `beforeConversation` is the default for retrieved context and inserts after
  the base system preamble but before the first conversational message.
- `afterBase` is for post-history instructions.
- Disabled, failed, and cancelled contributors do not block ordinary chat.

`lastContextAssemblyProvider` exposes the base and final messages, token totals,
injected messages, contributor order, trimming, elapsed time, and isolated
errors. It is in-memory diagnostic state and is not persisted or logged.

## Generation middleware

Register `ChatGenerationMiddleware` through the same registry. Pre-generation
hooks run in ascending order; post-generation and error hooks run in reverse
order. A pre-generation hook may return `request.copyWith` to change messages,
the LLM configuration, or metadata. It cannot replace the session ID, chat
scope, generation mode, or cancellation token.

`recoverFromError` may return an `LLMResponse` to recover a provider failure.
Returning `null` lets the next outer middleware inspect the error; an
unrecovered error returns to the existing chat error path. Hook failures are
recorded and isolated. `lastChatGenerationTraceProvider` exposes the latest
middleware phases, recovery, cancellation, and terminal error.

## Cancellation and lifecycle

Each generation owns a `ChatCancellationToken`. Contributors and middleware
should check `isCancelled`, await `whenCancelled` for interruptible work, or
call `throwIfCancelled` between expensive steps. User cancellation propagates
to that token, registered cancellation hooks, and the active LLM HTTP request.

Keep registration ownership inside the feature provider and dispose the
returned handle. Registry snapshots are taken for each phase, so registering or
unregistering an extension does not mutate an in-flight iteration.

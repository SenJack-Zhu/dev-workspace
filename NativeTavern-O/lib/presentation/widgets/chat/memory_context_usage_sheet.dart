import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/long_term_memory_context_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/memory_context_providers.dart';

class MemoryContextUsageSheet extends ConsumerWidget {
  const MemoryContextUsageSheet({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final usage = ref.watch(memoryContextUsageProvider(chatId));
    final maximumHeight = MediaQuery.sizeOf(context).height * 0.72;
    return SafeArea(
      child: SizedBox(
        key: const Key('memory-usage-sheet'),
        height: maximumHeight,
        child: usage.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => const Center(child: Icon(Icons.error_outline)),
          data: (value) {
            if (value == null) {
              return const Center(
                child: Icon(Icons.psychology_outlined, size: 48),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.psychology_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.memoryUsed,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              '${_memoryModeLabel(l10n, value.mode)} | '
                              '${l10n.memoryTokenUsage(value.usedTokens, value.allocatedTokens)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Text('${value.includedCount}/${value.items.length}'),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (value.items.isEmpty)
                  Expanded(
                    child: Center(
                      child: Icon(
                        value.status == ContextContributionStatus.disabled
                            ? Icons.visibility_off_outlined
                            : Icons.manage_search,
                        size: 48,
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      itemCount: value.items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = value.items[index];
                        final memory = item.memory;
                        final source = memory.source;
                        final canOpenSource = source.sourceChatId != null &&
                            source.sourceMessageIds.isNotEmpty;
                        return Padding(
                          key: Key('memory-usage-item-${memory.id}'),
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(_statusIcon(item.status), size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(memory.content),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 4,
                                      children: [
                                        Text(
                                          l10n.memoryRelevancePercent(
                                            (item.score * 100).round(),
                                          ),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                        Text(
                                          _memoryStatusLabel(l10n, item.status),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                        Text(
                                          source.origin ==
                                                  MemoryOrigin.generated
                                              ? '${source.providerId} / ${source.modelId}'
                                              : l10n.manual,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              if (canOpenSource)
                                IconButton(
                                  key: Key('memory-usage-source-${memory.id}'),
                                  tooltip: l10n.memoryOpenSource,
                                  onPressed: () {
                                    final router = GoRouter.of(context);
                                    Navigator.of(context).pop();
                                    router.push(
                                      '/chat/${source.sourceChatId}'
                                      '?message=${source.sourceMessageIds.first}',
                                    );
                                  },
                                  icon: const Icon(Icons.open_in_new),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _memoryModeLabel(AppLocalizations l10n, MemoryRetrievalMode mode) =>
    switch (mode) {
      MemoryRetrievalMode.fts => l10n.memoryModeLocalFts,
      MemoryRetrievalMode.hybrid => l10n.memoryModeHybrid,
      MemoryRetrievalMode.ftsFallback => l10n.memoryModeLocalFallback,
    };

IconData _statusIcon(ContextContributionItemStatus status) => switch (status) {
      ContextContributionItemStatus.included => Icons.check_circle_outline,
      ContextContributionItemStatus.truncated => Icons.content_cut,
      ContextContributionItemStatus.dropped => Icons.block_outlined,
    };

String _memoryStatusLabel(
        AppLocalizations l10n, ContextContributionItemStatus status) =>
    switch (status) {
      ContextContributionItemStatus.included => l10n.memoryIncluded,
      ContextContributionItemStatus.truncated => l10n.memoryTrimmed,
      ContextContributionItemStatus.dropped => l10n.memoryExcluded,
    };

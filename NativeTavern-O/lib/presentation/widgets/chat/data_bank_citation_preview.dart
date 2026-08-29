import 'package:flutter/material.dart';
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/models/data_bank_context.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';

class DataBankCitationPreview extends StatelessWidget {
  final ChatMessage message;

  const DataBankCitationPreview({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final snapshot = dataBankContextForSwipe(
      message.metadata,
      message.currentSwipeIndex,
    );
    if (snapshot == null || snapshot.sources.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: TextButton.icon(
        key: ValueKey('data-bank-citations-${message.id}'),
        onPressed: () => showDataBankCitationSheet(context, snapshot),
        icon: const Icon(Icons.menu_book_outlined, size: 17),
        label: Text(
          l10n.dataBankCitationSourcesCount(snapshot.sources.length),
        ),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
      ),
    );
  }
}

Future<void> showDataBankCitationSheet(
  BuildContext context,
  DataBankContextSnapshot snapshot,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DataBankCitationSheet(snapshot: snapshot),
  );
}

class DataBankCitationSheet extends StatelessWidget {
  final DataBankContextSnapshot snapshot;
  final String? title;

  const DataBankCitationSheet({
    super.key,
    required this.snapshot,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title ?? l10n.dataBankCitationSources,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.close,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: _RetrievalSummary(snapshot: snapshot),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                key: const Key('data-bank-citation-list'),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                itemCount: snapshot.sources.length,
                separatorBuilder: (_, __) => const Divider(height: 28),
                itemBuilder: (context, index) =>
                    _CitationSource(source: snapshot.sources[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RetrievalSummary extends StatelessWidget {
  final DataBankContextSnapshot snapshot;

  const _RetrievalSummary({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mode = switch (snapshot.mode) {
      DataBankRetrievalMode.localFts => l10n.dataBankModeLocalFts,
      DataBankRetrievalMode.semanticReranked => l10n.dataBankModeSemantic,
      DataBankRetrievalMode.semanticFallback => l10n.dataBankModeFallback,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          snapshot.originalQuery,
          key: const Key('data-bank-citation-query'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(mode, style: Theme.of(context).textTheme.bodySmall),
        if (snapshot.queries.length > 1)
          Text(
            l10n.dataBankLocalQueriesFused(snapshot.queries.length),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (snapshot.fallbackReason != null)
          Text(
            snapshot.fallbackReason!,
            key: const Key('data-bank-semantic-fallback'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
          ),
      ],
    );
  }
}

class _CitationSource extends StatelessWidget {
  final DataBankContextSource source;

  const _CitationSource({required this.source});

  @override
  Widget build(BuildContext context) {
    return Column(
      key: ValueKey('data-bank-citation-${source.citation.chunkId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.description_outlined, size: 19),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '[${source.label}] ${source.documentName}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ],
        ),
        if (source.locationLabel.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            source.locationLabel,
            key: ValueKey('data-bank-location-${source.citation.chunkId}'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 8),
        SelectableText(source.injectedText),
      ],
    );
  }
}

// File selection is user-triggered and intentionally asynchronous.
// ignore_for_file: avoid_slow_async_io

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/models/data_bank_context.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/data_bank_library_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/controllers/data_bank_library_controller.dart';
import 'package:native_tavern/presentation/providers/data_bank_providers.dart';
import 'package:native_tavern/presentation/widgets/chat/data_bank_citation_preview.dart';

abstract interface class DataBankFileGateway {
  Future<File?> pickDocument();
}

final class PlatformDataBankFileGateway implements DataBankFileGateway {
  const PlatformDataBankFileGateway();

  @override
  Future<File?> pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'txt',
        'md',
        'markdown',
        'html',
        'htm',
        'pdf',
        'epub',
      ],
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final selectedPath = result.files.single.path;
    if (selectedPath == null) {
      throw const FileSystemException(
        'The selected document could not be read.',
      );
    }
    return File(selectedPath);
  }
}

final class DataBankBindingTarget {
  final String id;
  final String label;

  const DataBankBindingTarget({required this.id, required this.label});
}

abstract interface class DataBankBindingTargetGateway {
  Future<List<DataBankBindingTarget>> listCharacters();

  Future<List<DataBankBindingTarget>> listChats();
}

final class RepositoryDataBankBindingTargetGateway
    implements DataBankBindingTargetGateway {
  final CharacterRepository _characters;
  final ChatRepository _chats;

  const RepositoryDataBankBindingTargetGateway(this._characters, this._chats);

  @override
  Future<List<DataBankBindingTarget>> listCharacters() async {
    final targets = (await _characters.getAllCharacters())
        .map(
          (character) =>
              DataBankBindingTarget(id: character.id, label: character.name),
        )
        .toList();
    targets.sort((left, right) => left.label.compareTo(right.label));
    return targets;
  }

  @override
  Future<List<DataBankBindingTarget>> listChats() async {
    return (await _chats.getAllChats())
        .map((chat) => DataBankBindingTarget(id: chat.id, label: chat.title))
        .toList(growable: false);
  }
}

class DataBankScreen extends ConsumerStatefulWidget {
  final DataBankLibraryController? controller;
  final DataBankFileGateway fileGateway;
  final DataBankBindingTargetGateway? bindingTargetGateway;

  const DataBankScreen({
    super.key,
    this.controller,
    this.fileGateway = const PlatformDataBankFileGateway(),
    this.bindingTargetGateway,
  });

  @override
  ConsumerState<DataBankScreen> createState() => _DataBankScreenState();
}

class _DataBankScreenState extends ConsumerState<DataBankScreen> {
  late final DataBankLibraryController _controller;
  late final bool _ownsController;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ??
        DataBankLibraryController(ref.read(dataBankLibraryServiceProvider));
    _controller.addListener(_refresh);
    _controller.initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _controller.removeListener(_refresh);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dataBank),
        actions: [
          IconButton(
            key: const Key('data-bank-context-settings'),
            tooltip: l10n.dataBankChatRetrievalSettings,
            onPressed: _showContextSettings,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            key: const Key('data-bank-rebuild-index'),
            tooltip: l10n.dataBankRebuildSearchIndex,
            onPressed: _controller.working ? null : _rebuildIndex,
            icon: const Icon(Icons.manage_search_outlined),
          ),
          IconButton(
            key: const Key('data-bank-import'),
            tooltip: l10n.dataBankImportDocument,
            onPressed: _controller.working ? null : _importDocument,
            icon: const Icon(Icons.note_add_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SearchBar(
              key: const Key('data-bank-search'),
              controller: _searchController,
              hintText: l10n.dataBankSearchDocuments,
              leading: const Icon(Icons.search),
              trailing: [
                if (_controller.showingSearch)
                  IconButton(
                    tooltip: l10n.dataBankClearSearch,
                    onPressed: () {
                      _searchController.clear();
                      _controller.search('');
                    },
                    icon: const Icon(Icons.close),
                  ),
              ],
              onSubmitted: _controller.search,
            ),
          ),
          if (_controller.overallProgress case final progress?)
            LinearProgressIndicator(
              key: const Key('data-bank-import-progress'),
              value: progress,
            ),
          if (_controller.error case final error?)
            _ErrorBanner(
              message: _friendlyError(l10n, error),
              onDismiss: _controller.clearError,
            ),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_controller.loading && _controller.documents.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_controller.showingSearch) {
      if (_controller.searchResults.isEmpty) {
        return _EmptyState(
          key: const Key('data-bank-no-results'),
          icon: Icons.search_off_outlined,
          title: AppLocalizations.of(context).dataBankNoMatches,
        );
      }
      return RefreshIndicator(
        onRefresh: () => _controller.search(_searchController.text),
        child: ListView.separated(
          key: const Key('data-bank-search-results'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: _controller.searchResults.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) =>
              _SearchResultTile(result: _controller.searchResults[index]),
        ),
      );
    }
    if (_controller.documents.isEmpty) {
      return _EmptyState(
        key: const Key('data-bank-empty'),
        icon: Icons.library_books_outlined,
        title: AppLocalizations.of(context).dataBankNoDocuments,
        action: FilledButton.icon(
          onPressed: _controller.working ? null : _importDocument,
          icon: const Icon(Icons.note_add_outlined),
          label: Text(AppLocalizations.of(context).import_action),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _controller.reload,
      child: ListView.separated(
        key: const Key('data-bank-document-list'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _controller.documents.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final entry = _controller.documents[index];
          return _DocumentCard(
            key: ValueKey(entry.document.id),
            entry: entry,
            busy: _controller.working,
            onToggle: (enabled) => _run(
              () => _controller.setDocumentEnabled(entry.document.id, enabled),
            ),
            onPreview: () => _showPreview(entry.document.id),
            onBindings: () => _showBindings(entry),
            onRetry: () =>
                _run(() => _controller.retryDocument(entry.document.id)),
            onDelete: () => _confirmDelete(entry.document.id),
          );
        },
      ),
    );
  }

  Future<void> _importDocument() async {
    await _run(() async {
      final file = await widget.fileGateway.pickDocument();
      if (file != null) await _controller.importDocument(file);
    });
  }

  Future<void> _showContextSettings() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _DataBankContextSettingsSheet(),
    );
  }

  Future<void> _rebuildIndex() async {
    final successMessage =
        AppLocalizations.of(context).dataBankSearchIndexRebuilt;
    await _run(() async {
      await _controller.rebuildSearchIndex();
      _showMessage(successMessage);
    });
  }

  Future<void> _showPreview(String documentId) async {
    await _run(() async {
      final preview = await _controller.previewDocument(documentId);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _PreviewSheet(preview: preview),
      );
    });
  }

  Future<void> _showBindings(DataBankLibraryEntry entry) async {
    await _run(() async {
      final gateway = widget.bindingTargetGateway ??
          RepositoryDataBankBindingTargetGateway(
            ref.read(characterRepositoryProvider),
            ref.read(chatRepositoryProvider),
          );
      final targets = await Future.wait([
        gateway.listCharacters(),
        gateway.listChats(),
      ]);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _BindingsDialog(
          entry: entry,
          characterTargets: targets[0],
          chatTargets: targets[1],
          onSave: ({required scope, targetId}) async {
            await _controller.saveBinding(
              documentId: entry.document.id,
              scope: scope,
              targetId: targetId,
            );
          },
          onDelete: _controller.removeBinding,
        ),
      );
    });
  }

  Future<void> _confirmDelete(String documentId) async {
    await _run(() async {
      final preview = await _controller.previewDeletion(documentId);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          final l10n = AppLocalizations.of(context);
          return AlertDialog(
            title:
                Text(l10n.dataBankDeleteDocumentQuestion(preview.documentName)),
            content: Text(l10n.dataBankDeleteDocumentBody(
              preview.versionCount,
              preview.chunkCount,
              preview.bindingCount,
              preview.managedPaths.length,
            )),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                key: const Key('data-bank-confirm-delete'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.delete),
              ),
            ],
          );
        },
      );
      if (confirmed == true) await _controller.deleteDocument(documentId);
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error) {
      if (!mounted) return;
      _showMessage(_friendlyError(AppLocalizations.of(context), error));
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DataBankContextSettingsSheet extends ConsumerWidget {
  const _DataBankContextSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(dataBankContextSettingsProvider);
    final notifier = ref.read(dataBankContextSettingsProvider.notifier);
    final diagnostics = ref.watch(lastDataBankContextProvider);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.88,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.dataBankChatRetrieval,
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
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                children: [
                  SwitchListTile(
                    key: const Key('data-bank-context-enabled'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.dataBankUseInChat),
                    value: settings.enabled,
                    onChanged: notifier.setEnabled,
                  ),
                  SwitchListTile(
                    key: const Key('data-bank-query-rewrite'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.dataBankQueryExpansion),
                    value: settings.queryRewriteEnabled,
                    onChanged: settings.enabled
                        ? notifier.setQueryRewriteEnabled
                        : null,
                  ),
                  SwitchListTile(
                    key: const Key('data-bank-semantic-reranking'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.dataBankSemanticReranking),
                    subtitle: Text(l10n.dataBankUsesEmbeddingProvider),
                    value: settings.semanticRerankingEnabled,
                    onChanged: settings.enabled
                        ? notifier.setSemanticRerankingEnabled
                        : null,
                  ),
                  const Divider(height: 28),
                  _SettingsSlider(
                    key: const Key('data-bank-top-k'),
                    title: l10n.dataBankSourcesPerResponse,
                    valueLabel: '${settings.topK}',
                    value: settings.topK.toDouble(),
                    min: 1,
                    max: 20,
                    divisions: 19,
                    enabled: settings.enabled,
                    onChanged: (value) => notifier.setTopK(value.round()),
                  ),
                  _SettingsSlider(
                    key: const Key('data-bank-token-budget'),
                    title: l10n.dataBankTokenBudget,
                    valueLabel: '${settings.maxTokens}',
                    value: settings.maxTokens.clamp(256, 4096).toDouble(),
                    min: 256,
                    max: 4096,
                    divisions: 30,
                    enabled: settings.enabled,
                    onChanged: (value) =>
                        notifier.setMaxTokens((value / 128).round() * 128),
                  ),
                  _SettingsSlider(
                    key: const Key('data-bank-source-diversity'),
                    title: l10n.dataBankChunksPerDocument,
                    valueLabel: '${settings.maxChunksPerDocument}',
                    value: settings.maxChunksPerDocument.clamp(1, 5).toDouble(),
                    min: 1,
                    max: 5,
                    divisions: 4,
                    enabled: settings.enabled,
                    onChanged: (value) =>
                        notifier.setMaxChunksPerDocument(value.round()),
                  ),
                  const Divider(height: 32),
                  Text(
                    l10n.dataBankLastRetrieval,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  if (diagnostics == null)
                    Text(l10n.dataBankNoRetrievalYet)
                  else
                    _DataBankDiagnostics(snapshot: diagnostics),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSlider extends StatelessWidget {
  final String title;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final bool enabled;
  final ValueChanged<double> onChanged;

  const _SettingsSlider({
    super.key,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title)),
            Text(valueLabel, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }
}

class _DataBankDiagnostics extends StatelessWidget {
  final DataBankContextSnapshot snapshot;

  const _DataBankDiagnostics({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mode = switch (snapshot.mode) {
      DataBankRetrievalMode.localFts => l10n.dataBankModeLocalFts,
      DataBankRetrievalMode.semanticReranked => l10n.dataBankModeSemantic,
      DataBankRetrievalMode.semanticFallback => l10n.dataBankModeFallback,
    };
    return Column(
      key: const Key('data-bank-retrieval-diagnostics'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          snapshot.originalQuery,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text('$mode | ${l10n.dataBankSourcesCount(snapshot.sources.length)}'),
        if (snapshot.fallbackReason != null)
          Text(
            snapshot.fallbackReason!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        for (final source in snapshot.sources.take(3)) ...[
          const SizedBox(height: 12),
          Text(
            '[${source.label}] ${source.documentName}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (source.locationLabel.isNotEmpty)
            Text(
              source.locationLabel,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Text(
            source.snippet.isEmpty ? source.injectedText : source.snippet,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (snapshot.sources.isNotEmpty) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('data-bank-open-diagnostics'),
              onPressed: () => showDataBankCitationSheet(context, snapshot),
              icon: const Icon(Icons.fact_check_outlined),
              label: Text(l10n.dataBankInspectAllSources),
            ),
          ),
        ],
      ],
    );
  }
}

class _DocumentCard extends StatelessWidget {
  final DataBankLibraryEntry entry;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPreview;
  final VoidCallback onBindings;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  const _DocumentCard({
    super.key,
    required this.entry,
    required this.busy,
    required this.onToggle,
    required this.onPreview,
    required this.onBindings,
    required this.onRetry,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final document = entry.document;
    final processing =
        document.processingState == DataBankProcessingState.pending ||
            document.processingState == DataBankProcessingState.processing;
    final failed = document.processingState == DataBankProcessingState.failed;
    final disabled =
        document.processingState == DataBankProcessingState.disabled;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Icon(Icons.description_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.version.originalFileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_formatBytes(entry.version.byteSize)}  |  '
                        '${l10n.dataBankChunksCount(entry.chunkCount)}  |  '
                        '${l10n.dataBankBindingsCount(entry.bindings.length)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(state: document.processingState),
                Switch(
                  key: ValueKey('data-bank-toggle-${document.id}'),
                  value: document.isEnabled,
                  onChanged: busy || processing ? null : onToggle,
                ),
              ],
            ),
            if (processing) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            if (failed) ...[
              const SizedBox(height: 8),
              Text(
                document.failure?.message ?? l10n.dataBankProcessingFailed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (entry.bindings.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: entry.bindings
                    .map(
                      (binding) => Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(_bindingIcon(binding.scope), size: 16),
                        label: Text(_bindingLabel(l10n, binding)),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: l10n.preview,
                  onPressed: busy || entry.chunkCount == 0 ? null : onPreview,
                  icon: const Icon(Icons.visibility_outlined),
                ),
                IconButton(
                  tooltip: l10n.dataBankManageBindings,
                  onPressed: busy ? null : onBindings,
                  icon: const Icon(Icons.link_outlined),
                ),
                IconButton(
                  key: ValueKey('data-bank-retry-${document.id}'),
                  tooltip: failed ? l10n.retry : l10n.dataBankRebuildDocument,
                  onPressed: busy || disabled || processing ? null : onRetry,
                  icon: Icon(failed ? Icons.refresh : Icons.replay_outlined),
                ),
                IconButton(
                  key: ValueKey('data-bank-delete-${document.id}'),
                  tooltip: l10n.delete,
                  onPressed: busy ? null : onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  final DataBankSearchResult result;

  const _SearchResultTile({required this.result});

  @override
  Widget build(BuildContext context) {
    final locator = result.citation.locator;
    final source = [
      result.documentName,
      if (locator.chapter != null) locator.chapter!,
      if (locator.pageStart != null)
        locator.pageEnd == null || locator.pageEnd == locator.pageStart
            ? 'p. ${locator.pageStart}'
            : 'pp. ${locator.pageStart}-${locator.pageEnd}',
    ].join('  |  ');
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.find_in_page_outlined),
        title: Text(
          result.snippet,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(source, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _PreviewSheet extends StatelessWidget {
  final DataBankDocumentPreview preview;

  const _PreviewSheet({required this.preview});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      preview.version.originalFileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                key: const Key('data-bank-preview-chunks'),
                padding: const EdgeInsets.all(16),
                itemCount: preview.chunks.length,
                separatorBuilder: (_, __) => const Divider(height: 24),
                itemBuilder: (context, index) {
                  final chunk = preview.chunks[index];
                  final locator = chunk.locator;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _locatorLabel(locator, index),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 6),
                      SelectableText(chunk.text),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _SaveBinding = Future<void> Function({
  required DataBankBindingScope scope,
  String? targetId,
});

class _BindingsDialog extends StatefulWidget {
  final DataBankLibraryEntry entry;
  final List<DataBankBindingTarget> characterTargets;
  final List<DataBankBindingTarget> chatTargets;
  final _SaveBinding onSave;
  final Future<void> Function(String bindingId) onDelete;

  const _BindingsDialog({
    required this.entry,
    required this.characterTargets,
    required this.chatTargets,
    required this.onSave,
    required this.onDelete,
  });

  @override
  State<_BindingsDialog> createState() => _BindingsDialogState();
}

class _BindingsDialogState extends State<_BindingsDialog> {
  late List<DataBankBinding> _bindings;
  DataBankBindingScope _scope = DataBankBindingScope.global;
  String? _targetId;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _bindings = List.of(widget.entry.bindings);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final needsTarget = _scope != DataBankBindingScope.global;
    final availableTargets = switch (_scope) {
      DataBankBindingScope.global => const <DataBankBindingTarget>[],
      DataBankBindingScope.character => widget.characterTargets,
      DataBankBindingScope.chat => widget.chatTargets,
    };
    return AlertDialog(
      title: Text(l10n.dataBankBindings),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final binding in _bindings)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_bindingIcon(binding.scope)),
                  title: Text(_bindingLabel(l10n, binding)),
                  trailing: IconButton(
                    tooltip: l10n.dataBankRemoveBinding,
                    onPressed: _working ? null : () => _remove(binding),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              const Divider(),
              DropdownButtonFormField<DataBankBindingScope>(
                key: const Key('data-bank-binding-scope'),
                initialValue: _scope,
                decoration: InputDecoration(labelText: l10n.scope),
                items: DataBankBindingScope.values
                    .map(
                      (scope) => DropdownMenuItem(
                        value: scope,
                        child: Text(_scopeLabel(l10n, scope)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _working
                    ? null
                    : (scope) => setState(() {
                          _scope = scope ?? DataBankBindingScope.global;
                          _targetId = null;
                        }),
              ),
              if (needsTarget) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey('data-bank-binding-target-${_scope.name}'),
                  initialValue: _targetId,
                  decoration: InputDecoration(
                    labelText: _scope == DataBankBindingScope.character
                        ? l10n.character
                        : l10n.chat,
                  ),
                  items: availableTargets
                      .map(
                        (target) => DropdownMenuItem(
                          value: target.id,
                          child: Text(
                            target.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: _working
                      ? null
                      : (targetId) => setState(() => _targetId = targetId),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('data-bank-add-binding'),
                onPressed: _working || (needsTarget && _targetId == null)
                    ? null
                    : _save,
                icon: const Icon(Icons.add_link),
                label: Text(l10n.dataBankAddBinding),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: Text(l10n.done),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_scope != DataBankBindingScope.global && _targetId == null) return;
    setState(() => _working = true);
    try {
      await widget.onSave(
        scope: _scope,
        targetId: _scope == DataBankBindingScope.global ? null : _targetId,
      );
      if (!mounted) return;
      Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _remove(DataBankBinding binding) async {
    setState(() => _working = true);
    try {
      await widget.onDelete(binding.id);
      if (mounted) setState(() => _bindings.remove(binding));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

class _StatusBadge extends StatelessWidget {
  final DataBankProcessingState state;

  const _StatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = switch (state) {
      DataBankProcessingState.ready => Colors.green,
      DataBankProcessingState.failed => Theme.of(context).colorScheme.error,
      DataBankProcessingState.disabled => Colors.grey,
      DataBankProcessingState.pending ||
      DataBankProcessingState.processing =>
        Theme.of(context).colorScheme.primary,
      DataBankProcessingState.deleted => Colors.grey,
    };
    return Semantics(
      label: l10n.dataBankStatusSemantics(_stateLabel(l10n, state)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          _stateLabel(l10n, state),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      content: Text(message),
      leading: Icon(
        Icons.error_outline,
        color: Theme.of(context).colorScheme.error,
      ),
      actions: [
        IconButton(
          tooltip: AppLocalizations.of(context).dataBankDismiss,
          onPressed: onDismiss,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? action;

  const _EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

String _stateLabel(AppLocalizations l10n, DataBankProcessingState state) =>
    switch (state) {
      DataBankProcessingState.pending => l10n.dataBankStatePending,
      DataBankProcessingState.processing => l10n.dataBankStateProcessing,
      DataBankProcessingState.ready => l10n.dataBankStateReady,
      DataBankProcessingState.failed => l10n.dataBankStateFailed,
      DataBankProcessingState.disabled => l10n.disabled,
      DataBankProcessingState.deleted => l10n.dataBankStateDeleted,
    };

IconData _bindingIcon(DataBankBindingScope scope) => switch (scope) {
      DataBankBindingScope.global => Icons.public,
      DataBankBindingScope.character => Icons.person_outline,
      DataBankBindingScope.chat => Icons.chat_bubble_outline,
    };

String _scopeLabel(AppLocalizations l10n, DataBankBindingScope scope) =>
    switch (scope) {
      DataBankBindingScope.global => l10n.global,
      DataBankBindingScope.character => l10n.character,
      DataBankBindingScope.chat => l10n.chat,
    };

String _bindingLabel(AppLocalizations l10n, DataBankBinding binding) {
  final scope = _scopeLabel(l10n, binding.scope);
  final target = binding.targetId;
  return target == null ? scope : '$scope: $target';
}

String _locatorLabel(DataBankSourceLocator locator, int index) {
  final parts = <String>[
    if (locator.chapter != null) locator.chapter!,
    if (locator.pageStart != null)
      locator.pageEnd == null || locator.pageEnd == locator.pageStart
          ? 'Page ${locator.pageStart}'
          : 'Pages ${locator.pageStart}-${locator.pageEnd}',
  ];
  return parts.isEmpty ? 'Chunk ${index + 1}' : parts.join('  |  ');
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(1)} KiB';
  return '${(kib / 1024).toStringAsFixed(1)} MiB';
}

String _friendlyError(AppLocalizations l10n, Object error) {
  if (error is DataBankDuplicateDocumentException) {
    return l10n.dataBankDuplicateDocument;
  }
  return error.toString().replaceFirst(RegExp(r'^[^:]+:\s*'), '');
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/data/models/world_info.dart';
import 'package:native_tavern/presentation/providers/world_info_providers.dart';
import 'package:native_tavern/presentation/providers/character_providers.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';

/// Enhanced World Info Entry Editor Screen with all new fields
class WorldInfoEntryEditorScreen extends ConsumerStatefulWidget {
  final String worldInfoId;
  final WorldInfoEntry? entry; // null for creating new entry

  const WorldInfoEntryEditorScreen({
    super.key,
    required this.worldInfoId,
    this.entry,
  });

  @override
  ConsumerState<WorldInfoEntryEditorScreen> createState() =>
      _WorldInfoEntryEditorScreenState();
}

class _WorldInfoEntryEditorScreenState
    extends ConsumerState<WorldInfoEntryEditorScreen>
    with SingleTickerProviderStateMixin {
  AppLocalizations get _l10n => AppLocalizations.of(context);
  late TabController _tabController;
  late TextEditingController _keysController;
  late TextEditingController _secondaryKeysController;
  late TextEditingController _contentController;
  late TextEditingController _commentController;
  late TextEditingController _groupController;

  // Settings
  WorldInfoPosition _position = WorldInfoPosition.before;
  int _depth = 4;
  int _insertionOrder = 0;
  int _scanDepth = 0;
  bool _enabled = true;
  bool _constant = true;
  bool _selective = false;
  bool _caseSensitive = false;
  bool _matchWholeWords = false;
  bool _preventRecursion = false;
  bool _excludeRecursion = false;
  bool _delayUntilRecursion = false;
  bool _useGroupScoring = false;
  int _groupWeight = 0;
  int _groupOverride = 0;
  bool _useProbability = false;
  int _probability = 100;
  bool _isFavorite = false;

  // Advanced fields
  WorldInfoRole _role = WorldInfoRole.system;
  WorldInfoTimedEffects _timedEffects = const WorldInfoTimedEffects();
  WorldInfoCharacterFilter _characterFilter = const WorldInfoCharacterFilter();

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);

    // Initialize controllers with existing data
    final entry = widget.entry;
    _keysController = TextEditingController(text: entry?.keys.join(', ') ?? '');
    _secondaryKeysController =
        TextEditingController(text: entry?.secondaryKeys.join(', ') ?? '');
    _contentController = TextEditingController(text: entry?.content ?? '');
    _commentController = TextEditingController(text: entry?.comment ?? '');
    _groupController = TextEditingController(text: entry?.group ?? '');

    if (entry != null) {
      _position = entry.position;
      _depth = entry.depth;
      _insertionOrder = entry.insertionOrder;
      _scanDepth = entry.scanDepth;
      _enabled = entry.enabled;
      _constant = entry.constant;
      _selective = entry.selective;
      _caseSensitive = entry.caseSensitive;
      _matchWholeWords = entry.matchWholeWords;
      _preventRecursion = entry.preventRecursion;
      _excludeRecursion = entry.excludeRecursion;
      _delayUntilRecursion = entry.delayUntilRecursion;
      _useGroupScoring = entry.useGroupScoring;
      _groupWeight = entry.groupWeight;
      _groupOverride = entry.groupOverride;
      _useProbability = entry.useProbability;
      _probability = entry.probability;
      _isFavorite = entry.isFavorite;
      _role = entry.role;
      _timedEffects = entry.timedEffects;
      _characterFilter = entry.characterFilter;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _keysController.dispose();
    _secondaryKeysController.dispose();
    _contentController.dispose();
    _commentController.dispose();
    _groupController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry == null ? _l10n.createEntry : _l10n.editEntry),
        actions: [
          IconButton(
            icon: Icon(_isFavorite ? Icons.star : Icons.star_border),
            tooltip: _l10n.favorites,
            onPressed: () => setState(() => _isFavorite = !_isFavorite),
          ),
          Switch(
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: _l10n.save,
            onPressed: _isSaving ? null : _save,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            Tab(text: _l10n.basic, icon: const Icon(Icons.edit)),
            Tab(text: _l10n.insertion, icon: const Icon(Icons.settings)),
            Tab(text: _l10n.filters, icon: const Icon(Icons.filter_list)),
            Tab(text: _l10n.advanced, icon: const Icon(Icons.tune)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildBasicTab(),
          _buildInsertionTab(),
          _buildFiltersTab(),
          _buildAdvancedTab(),
        ],
      ),
    );
  }

  Widget _buildBasicTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _keysController,
            decoration: InputDecoration(
              labelText: _l10n.keywordsCommaSeparated,
              hintText: _l10n.keywordsHint,
              border: const OutlineInputBorder(),
              helperText: _l10n.entryActivatesWhenKeywordFound,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _secondaryKeysController,
            decoration: InputDecoration(
              labelText: _l10n.secondaryKeysOptional,
              hintText: _l10n.secondaryKeysHint,
              border: const OutlineInputBorder(),
              helperText: _l10n.bothPrimaryAndSecondaryMustMatch,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _commentController,
            decoration: InputDecoration(
              labelText: _l10n.commentOptional,
              hintText: _l10n.noteForThisEntry,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _contentController,
            decoration: InputDecoration(
              labelText: _l10n.content,
              hintText: _l10n.contextToInjectWhenMatches,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            maxLines: 10,
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: Text(_l10n.constant),
            subtitle: Text(_l10n.alwaysIncludeInPrompt),
            value: _constant,
            onChanged: (v) => setState(() => _constant = v),
          ),
          SwitchListTile(
            title: Text(_l10n.selective),
            subtitle: Text(_l10n.requiresSecondaryKey),
            value: _selective,
            onChanged: (v) => setState(() => _selective = v),
          ),
        ],
      ),
    );
  }

  Widget _buildInsertionTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<WorldInfoPosition>(
            value: _position,
            decoration: InputDecoration(
              labelText: _l10n.position,
              border: const OutlineInputBorder(),
            ),
            items: WorldInfoPosition.values.map((pos) {
              return DropdownMenuItem(
                value: pos,
                child: Text(_positionName(pos)),
              );
            }).toList(),
            onChanged: (v) => setState(() => _position = v!),
          ),
          const SizedBox(height: 16),
          if (_position == WorldInfoPosition.atDepth) ...[
            TextField(
              decoration: InputDecoration(
                labelText: _l10n.depth,
                border: const OutlineInputBorder(),
                helperText: _l10n.depthInChatHistory,
              ),
              keyboardType: TextInputType.number,
              controller: TextEditingController(text: _depth.toString()),
              onChanged: (v) => _depth = int.tryParse(v) ?? 4,
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            decoration: InputDecoration(
              labelText: _l10n.insertionOrder,
              border: const OutlineInputBorder(),
              helperText: _l10n.lowerOrderInsertsFirst,
            ),
            keyboardType: TextInputType.number,
            controller: TextEditingController(text: _insertionOrder.toString()),
            onChanged: (v) => _insertionOrder = int.tryParse(v) ?? 0,
          ),
          const SizedBox(height: 16),
          TextField(
            decoration: InputDecoration(
              labelText: _l10n.scanDepth,
              border: const OutlineInputBorder(),
              helperText: _l10n.scanDepthDescription,
            ),
            keyboardType: TextInputType.number,
            controller: TextEditingController(text: _scanDepth.toString()),
            onChanged: (v) => _scanDepth = int.tryParse(v) ?? 0,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<WorldInfoRole>(
            value: _role,
            decoration: InputDecoration(
              labelText: _l10n.messageRole,
              border: const OutlineInputBorder(),
              helperText: _l10n.roleForInjectedContent,
            ),
            items: WorldInfoRole.values.map((role) {
              return DropdownMenuItem(
                value: role,
                child: Text(_roleName(role)),
              );
            }).toList(),
            onChanged: (v) => setState(() => _role = v!),
          ),
        ],
      ),
    );
  }

  Widget _buildFiltersTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            title: Text(_l10n.caseSensitive),
            subtitle: Text(_l10n.matchKeywordsExactCase),
            value: _caseSensitive,
            onChanged: (v) => setState(() => _caseSensitive = v),
          ),
          SwitchListTile(
            title: Text(_l10n.matchWholeWords),
            subtitle: Text(_l10n.onlyMatchCompleteWords),
            value: _matchWholeWords,
            onChanged: (v) => setState(() => _matchWholeWords = v),
          ),
          const Divider(height: 32),
          Text(
            _l10n.recursionControl,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: Text(_l10n.preventRecursion),
            subtitle: Text(_l10n.preventRecursionDescription),
            value: _preventRecursion,
            onChanged: (v) => setState(() => _preventRecursion = v),
          ),
          SwitchListTile(
            title: Text(_l10n.excludeRecursion),
            subtitle: Text(_l10n.excludeRecursionDescription),
            value: _excludeRecursion,
            onChanged: (v) => setState(() => _excludeRecursion = v),
          ),
          SwitchListTile(
            title: Text(_l10n.delayUntilRecursion),
            subtitle: Text(_l10n.delayUntilRecursionDescription),
            value: _delayUntilRecursion,
            onChanged: (v) => setState(() => _delayUntilRecursion = v),
          ),
          const Divider(height: 32),
          Text(
            _l10n.characterFilter,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _buildCharacterFilterSection(),
        ],
      ),
    );
  }

  Widget _buildAdvancedTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _l10n.groupSettings,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _groupController,
            decoration: InputDecoration(
              labelText: _l10n.groupName,
              border: const OutlineInputBorder(),
              helperText: _l10n.groupMutuallyExclusive,
            ),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: Text(_l10n.useGroupScoring),
            value: _useGroupScoring,
            onChanged: (v) => setState(() => _useGroupScoring = v),
          ),
          if (_useGroupScoring) ...[
            TextField(
              decoration: InputDecoration(
                labelText: _l10n.groupWeight,
                border: const OutlineInputBorder(),
                helperText: _l10n.groupWeightDescription,
              ),
              keyboardType: TextInputType.number,
              controller: TextEditingController(text: _groupWeight.toString()),
              onChanged: (v) => _groupWeight = int.tryParse(v) ?? 0,
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: InputDecoration(
                labelText: _l10n.groupOverride,
                border: const OutlineInputBorder(),
                helperText: _l10n.groupPriority,
              ),
              keyboardType: TextInputType.number,
              controller:
                  TextEditingController(text: _groupOverride.toString()),
              onChanged: (v) => _groupOverride = int.tryParse(v) ?? 0,
            ),
          ],
          const Divider(height: 32),
          Text(
            _l10n.probability,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: Text(_l10n.useProbability),
            subtitle: Text(_l10n.randomActivationProbability),
            value: _useProbability,
            onChanged: (v) => setState(() => _useProbability = v),
          ),
          if (_useProbability) ...[
            Slider(
              value: _probability.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              label: '$_probability%',
              onChanged: (v) => setState(() => _probability = v.toInt()),
            ),
            Text(
              _l10n.probabilityPercent(_probability),
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
          ],
          const Divider(height: 32),
          Text(
            _l10n.timedEffects,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _buildTimedEffectsSection(),
        ],
      ),
    );
  }

  Widget _buildCharacterFilterSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<WorldInfoCharacterFilterType>(
              value: _characterFilter.type,
              decoration: InputDecoration(
                labelText: _l10n.filterType,
                border: const OutlineInputBorder(),
              ),
              items: WorldInfoCharacterFilterType.values.map((type) {
                return DropdownMenuItem(
                  value: type,
                  child: Text(_filterTypeName(type)),
                );
              }).toList(),
              onChanged: (v) {
                setState(() {
                  _characterFilter = _characterFilter.copyWith(type: v!);
                });
              },
            ),
            if (_characterFilter.type != WorldInfoCharacterFilterType.none) ...[
              const SizedBox(height: 16),
              Text(
                _l10n.characterIds,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                  hintText: 'char_123, char_456',
                  border: OutlineInputBorder(),
                ),
                controller: TextEditingController(
                  text: _characterFilter.characterIds.join(', '),
                ),
                onChanged: (v) {
                  final ids = v
                      .split(',')
                      .map((s) => s.trim())
                      .where((s) => s.isNotEmpty)
                      .toList();
                  setState(() {
                    _characterFilter =
                        _characterFilter.copyWith(characterIds: ids);
                  });
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTimedEffectsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              decoration: InputDecoration(
                labelText: _l10n.stickyDuration,
                border: const OutlineInputBorder(),
                helperText: _l10n.stickyDurationDescription,
              ),
              keyboardType: TextInputType.number,
              controller:
                  TextEditingController(text: _timedEffects.sticky.toString()),
              onChanged: (v) {
                setState(() {
                  _timedEffects =
                      _timedEffects.copyWith(sticky: int.tryParse(v) ?? 0);
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: InputDecoration(
                labelText: _l10n.cooldown,
                border: const OutlineInputBorder(),
                helperText: _l10n.cooldownDescription,
              ),
              keyboardType: TextInputType.number,
              controller: TextEditingController(
                  text: _timedEffects.cooldown.toString()),
              onChanged: (v) {
                setState(() {
                  _timedEffects =
                      _timedEffects.copyWith(cooldown: int.tryParse(v) ?? 0);
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: InputDecoration(
                labelText: _l10n.delay,
                border: const OutlineInputBorder(),
                helperText: _l10n.delayDescription,
              ),
              keyboardType: TextInputType.number,
              controller:
                  TextEditingController(text: _timedEffects.delay.toString()),
              onChanged: (v) {
                setState(() {
                  _timedEffects =
                      _timedEffects.copyWith(delay: int.tryParse(v) ?? 0);
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final keys = _keysController.text
        .split(',')
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();

    final content = _contentController.text.trim();
    if (content.isEmpty) {
      _showError(_l10n.pleaseEnterContent);
      return;
    }

    final secondaryKeys = _secondaryKeysController.text
        .split(',')
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();

    final group = _groupController.text.trim();

    setState(() => _isSaving = true);

    try {
      final now = DateTime.now();
      final entry = WorldInfoEntry(
        id: widget.entry?.id ?? now.millisecondsSinceEpoch.toString(),
        worldInfoId: widget.worldInfoId,
        keys: keys,
        secondaryKeys: secondaryKeys,
        content: content,
        comment: _commentController.text.trim(),
        enabled: _enabled,
        constant: keys.isEmpty ? true : _constant,
        selective: _selective,
        insertionOrder: _insertionOrder,
        caseSensitive: _caseSensitive,
        matchWholeWords: _matchWholeWords,
        useGroupScoring: _useGroupScoring,
        automationId: false,
        probability: _probability,
        position: _position,
        depth: _depth,
        group: group.isEmpty ? null : group,
        groupWeight: _groupWeight,
        preventRecursion: _preventRecursion,
        delayUntilRecursion: _delayUntilRecursion,
        scanDepth: _scanDepth,
        role: _role,
        timedEffects: _timedEffects,
        characterFilter: _characterFilter,
        groupOverride: _groupOverride,
        excludeRecursion: _excludeRecursion,
        useProbability: _useProbability,
        vectorized: null,
        displayIndex: widget.entry?.displayIndex ?? 0,
        isFavorite: _isFavorite,
      );

      if (widget.entry == null) {
        await ref.read(worldInfoNotifierProvider.notifier).addEntry(
              worldInfoId: widget.worldInfoId,
              keys: entry.keys,
              content: entry.content,
              comment: entry.comment,
              secondaryKeys: entry.secondaryKeys,
              position: entry.position,
              constant: entry.constant,
              selective: entry.selective,
              insertionOrder: entry.insertionOrder,
            );
      } else {
        await ref.read(worldInfoNotifierProvider.notifier).updateEntry(entry);
      }

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      _showError(_l10n.saveFailed('$e'));
      setState(() => _isSaving = false);
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  String _positionName(WorldInfoPosition position) => switch (position) {
        WorldInfoPosition.before => _l10n.beforeCharacterDefinition,
        WorldInfoPosition.after => _l10n.afterCharacterDefinition,
        WorldInfoPosition.ANTop => _l10n.beforeAuthorNote,
        WorldInfoPosition.ANBottom => _l10n.afterAuthorNote,
        WorldInfoPosition.atDepth => _l10n.atDepth,
        WorldInfoPosition.EMTop => _l10n.beforeExampleMessages,
        WorldInfoPosition.EMBottom => _l10n.afterExampleMessages,
        WorldInfoPosition.outlet => _l10n.outlet,
      };

  String _roleName(WorldInfoRole role) => switch (role) {
        WorldInfoRole.system => _l10n.system,
        WorldInfoRole.user => _l10n.user,
        WorldInfoRole.assistant => _l10n.assistant,
      };

  String _filterTypeName(WorldInfoCharacterFilterType type) => switch (type) {
        WorldInfoCharacterFilterType.none => _l10n.none,
        WorldInfoCharacterFilterType.include => _l10n.include,
        WorldInfoCharacterFilterType.exclude => _l10n.exclude,
      };
}

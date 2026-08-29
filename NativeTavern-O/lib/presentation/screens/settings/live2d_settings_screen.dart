import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:native_tavern/domain/services/live2d_import_service.dart';
import 'package:native_tavern/domain/services/live2d_model_lifecycle_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/character_providers.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';
import 'package:native_tavern/presentation/widgets/live2d/live2d_character_view.dart';
import 'package:url_launcher/url_launcher.dart';

class Live2DSettingsScreen extends ConsumerWidget {
  final String characterId;

  const Live2DSettingsScreen({super.key, required this.characterId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return ref.watch(characterDetailProvider(characterId)).when(
          data: (character) {
            if (character == null) {
              return Scaffold(
                appBar: AppBar(title: const Text('Live2D')),
                body: Center(child: Text(l10n.characterNotFound)),
              );
            }
            return _Live2DSettingsEditor(
              key: ValueKey(character.id),
              character: character,
            );
          },
          loading: () => Scaffold(
            appBar: AppBar(title: const Text('Live2D')),
            body: const Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Scaffold(
            appBar: AppBar(title: const Text('Live2D')),
            body: Center(child: Text('${l10n.error}: $error')),
          ),
        );
  }
}

class _Live2DSettingsEditor extends ConsumerStatefulWidget {
  final Character character;

  const _Live2DSettingsEditor({super.key, required this.character});

  @override
  ConsumerState<_Live2DSettingsEditor> createState() =>
      _Live2DSettingsEditorState();
}

class _Live2DSettingsEditorState extends ConsumerState<_Live2DSettingsEditor> {
  static const _noneModel = '__none__';
  late final Live2DService _service;
  late final Live2DImportService _importService;
  final Live2DCharacterController _previewController =
      Live2DCharacterController();

  List<Live2DModelDefinition> _availableModels = List.of(
    Live2DService.bundledModels,
  );
  Live2DConfig? _config;
  Live2DModelManifest? _manifest;
  Live2DMotionRef? _selectedMotion;
  bool _isLoadingModel = false;
  bool _isImporting = false;
  bool _isDeleting = false;
  bool _isSaving = false;
  bool _isPreviewReady = false;
  bool _isPlayingPreviewMotion = false;
  String? _error;
  int _modelLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _service = ref.read(live2DServiceProvider);
    _importService = ref.read(live2DImportServiceProvider);
    _config = widget.character.assets?.live2d;
    _isLoadingModel = true;
    _loadImportedModels();
  }

  Future<void> _loadImportedModels() async {
    List<Live2DModelDefinition> imported;
    try {
      imported = await _importService.listImportedModels();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingModel = false;
        _error = error.toString();
      });
      return;
    }
    if (!mounted) return;
    final models = [...Live2DService.bundledModels, ...imported];
    setState(() => _availableModels = models);
    final config = _config;
    if (config == null) {
      setState(() => _isLoadingModel = false);
      return;
    }
    final definition = Live2DService.resolveDefinitionForConfig(config, models);
    if (definition == null) {
      _modelLoadGeneration++;
      setState(() {
        _isLoadingModel = false;
        _manifest = null;
        _selectedMotion = null;
        _isPreviewReady = false;
        _isPlayingPreviewMotion = false;
        _error = AppLocalizations.of(context).live2dUnavailableModelMessage;
      });
      return;
    }
    await _loadManifest(definition, replaceConfig: false);
  }

  Future<void> _selectModel(String id) async {
    if (id == _noneModel) {
      _modelLoadGeneration++;
      setState(() {
        _config = null;
        _manifest = null;
        _selectedMotion = null;
        _isLoadingModel = false;
        _isPreviewReady = false;
        _isPlayingPreviewMotion = false;
        _error = null;
      });
      return;
    }
    Live2DModelDefinition? definition;
    for (final model in _availableModels) {
      if (model.id == id) {
        definition = model;
        break;
      }
    }
    if (definition == null) {
      _modelLoadGeneration++;
      setState(() {
        _isLoadingModel = false;
        _error = AppLocalizations.of(context).live2dSelectionExpiredMessage;
      });
      return;
    }
    await _loadManifest(definition, replaceConfig: true);
  }

  Future<void> _importModel() async {
    if (_isImporting) return;
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'zip',
          'skel',
          'atlas',
          'png',
          'jpg',
          'jpeg',
          'webp',
        ],
        allowMultiple: true,
      );
      final paths = selection?.files
          .map((file) => file.path)
          .whereType<String>()
          .toList();
      if (paths == null || paths.isEmpty || !mounted) return;
      setState(() {
        _isImporting = true;
        _error = null;
      });
      final files = paths.map(File.new).toList();
      final zipFiles = files
          .where((file) => file.path.toLowerCase().endsWith('.zip'))
          .toList();
      final imported = <Live2DModelDefinition>[];
      if (zipFiles.isNotEmpty) {
        for (final zipFile in zipFiles) {
          imported.addAll(await _importService.importZip(zipFile));
        }
      } else {
        imported.addAll(await _importService.importSpineFiles(files));
      }
      if (!mounted) return;
      final allImported = await _importService.listImportedModels();
      if (!mounted) return;
      setState(() {
        _availableModels = [...Live2DService.bundledModels, ...allImported];
      });
      if (imported.isNotEmpty) {
        await _loadManifest(imported.first, replaceConfig: true);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).live2dModelsImported(
                imported.length,
              ),
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _deleteImportedModel(Live2DModelDefinition definition) async {
    if (_isDeleting) return;
    final lifecycle = ref.read(live2DModelLifecycleServiceProvider);
    try {
      final plan = await lifecycle.planDeletion(definition);
      if (!mounted) return;
      final confirmed = await _confirmDeletion(plan);
      if (confirmed != true || !mounted) return;
      setState(() {
        _isDeleting = true;
        _error = null;
      });

      final confirmation = lifecycle.confirmDeletion(plan);
      final result = await lifecycle.deleteImportedModel(confirmation);
      if (!mounted) return;
      final deletedModels = result.plan.packageModels;
      final currentConfig = _config;
      final clearsCurrent = currentConfig != null &&
          _configReferencesAny(currentConfig, deletedModels);
      final imported = await _importService.listImportedModels();
      if (!mounted) return;
      setState(() {
        _availableModels = [...Live2DService.bundledModels, ...imported];
        if (clearsCurrent) {
          _modelLoadGeneration++;
          _config = null;
          _manifest = null;
          _selectedMotion = null;
          _isLoadingModel = false;
          _error = null;
        }
      });

      for (final character in result.plan.affectedCharacters) {
        ref.invalidate(characterDetailProvider(character.id));
      }
      await ref.read(characterListProvider.notifier).refresh();
      final activeChat = ref.read(activeChatProvider);
      final affectedIds = result.plan.affectedCharacters
          .map((character) => character.id)
          .toSet();
      if (activeChat.chat != null &&
          affectedIds.contains(activeChat.character?.id)) {
        await ref
            .read(activeChatProvider.notifier)
            .loadChat(activeChat.chat!.id);
      }
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final suffix = result.cleanupPending ? l10n.live2dCleanupPending : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.live2dModelDeleted}$suffix')),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  Future<bool?> _confirmDeletion(Live2DDeletionPlan plan) {
    final removesPackage = plan.packageModels.length > 1;
    return showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.live2dDeleteImportedModelQuestion),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  removesPackage
                      ? l10n.live2dDeletePackageBody(plan.packageModels.length)
                      : l10n.live2dDeleteModelBody(plan.target.displayName),
                ),
                if (plan.affectedCharacters.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(l10n.live2dDisabledFor),
                  const SizedBox(height: 8),
                  ...plan.affectedCharacters.map(
                    (character) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('- ${character.name}'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.delete),
            ),
          ],
        );
      },
    );
  }

  bool _configReferencesAny(
    Live2DConfig config,
    List<Live2DModelDefinition> definitions,
  ) {
    return definitions.any((definition) {
      return config.modelId == definition.id ||
          (config.modelDirectory == definition.modelDirectory &&
              config.modelFileName == definition.modelFileName);
    });
  }

  Future<void> _loadManifest(
    Live2DModelDefinition definition, {
    required bool replaceConfig,
  }) async {
    final generation = ++_modelLoadGeneration;
    setState(() {
      _isLoadingModel = true;
      _isPreviewReady = false;
      _isPlayingPreviewMotion = false;
      _error = null;
    });
    try {
      final manifest = await _service.loadManifest(definition);
      final missing = await _service.findMissingFiles(definition, manifest);
      if (missing.isNotEmpty) {
        throw FormatException('Missing model file: ${missing.first}');
      }
      if (!mounted || generation != _modelLoadGeneration) return;
      final previous = _config;
      final discovered = Live2DConfig.fromDefinition(definition, manifest);
      var config = replaceConfig
          ? discovered
          : Live2DService.rebindConfigToDefinition(
              previous!,
              definition,
              manifest,
            );
      if (replaceConfig && previous != null) {
        config = config.copyWith(
          enabled: previous.enabled,
          scale: previous.scale,
          offsetX: previous.offsetX,
          offsetY: previous.offsetY,
          opacity: previous.opacity,
          motionSpeed: previous.motionSpeed,
        );
      }
      setState(() {
        _config = config;
        _manifest = manifest;
        _selectedMotion = manifest.motions.firstOrNull;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _modelLoadGeneration) {
        setState(() {
          if (!replaceConfig) {
            _manifest = null;
            _selectedMotion = null;
          }
          _error = error.toString();
        });
      }
    } finally {
      if (mounted && generation == _modelLoadGeneration) {
        setState(() => _isLoadingModel = false);
      }
    }
  }

  Future<void> _playPreviewMotion() async {
    final motion = _selectedMotion;
    final config = _config;
    if (_isPlayingPreviewMotion ||
        !_isPreviewReady ||
        motion == null ||
        config == null) {
      return;
    }
    if (!_previewController.isReady ||
        _previewController.loadedModelId != config.modelId) {
      setState(() => _isPreviewReady = false);
      return;
    }

    setState(() => _isPlayingPreviewMotion = true);
    try {
      await _previewController.playMotion(motion, priority: 3);
    } finally {
      if (mounted) setState(() => _isPlayingPreviewMotion = false);
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final currentAssets = widget.character.assets;
      final assets = CharacterAssets(
        avatarPath: currentAssets?.avatarPath,
        avatarUrl: currentAssets?.avatarUrl,
        expressionPack: currentAssets?.expressionPack,
        live2d: _config,
      );
      final updated = widget.character.copyWith(
        assets: assets.hasAssets ? assets : null,
        clearAssets: !assets.hasAssets,
        modifiedAt: DateTime.now(),
      );
      await ref.read(characterRepositoryProvider).updateCharacter(updated);
      ref.invalidate(characterDetailProvider(widget.character.id));
      await ref.read(characterListProvider.notifier).refresh();

      final activeChat = ref.read(activeChatProvider);
      if (activeChat.character?.id == widget.character.id &&
          activeChat.chat != null) {
        await ref
            .read(activeChatProvider.notifier)
            .loadChat(activeChat.chat!.id);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _setStateAfterBuild(VoidCallback fn) {
    scheduleLive2DEditorSetState(
      mounted: mounted,
      setState: setState,
      fn: fn,
    );
  }

  Future<void> _showLicenseNotice() async {
    final openTerms = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.live2dLicensing),
          content: Text(l10n.live2dLicenseNotice),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.close),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.live2dReviewTerms),
            ),
          ],
        );
      },
    );
    if (openTerms == true) {
      await launchUrl(
        Uri.parse('https://www.live2d.com/en/learn/sample/model-terms/'),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final config = _config;
    final selectedModelId = config == null ? _noneModel : config.modelId;
    final availableIds = _availableModels.map((m) => m.id).toSet();
    final hasUnavailableModel =
        config != null && !availableIds.contains(config.modelId);
    final importedModels = _availableModels
        .where((model) => model.source == Live2DModelSource.appData)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.character.name} Live2D'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: l10n.live2dLicensing,
            onPressed: _showLicenseNotice,
          ),
          IconButton(
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            tooltip: l10n.save,
            onPressed: _isSaving ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.animation),
            title: const Text('Live2D'),
            value: config?.enabled ?? false,
            onChanged: config == null
                ? null
                : (value) => setState(() {
                      _config = config.copyWith(enabled: value);
                    }),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: DropdownButtonFormField<String>(
              key: const Key('live2d-model-selector'),
              initialValue: selectedModelId,
              isExpanded: true,
              menuMaxHeight: math.min(
                MediaQuery.sizeOf(context).height * 0.6,
                480,
              ),
              decoration: InputDecoration(
                labelText: l10n.model,
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(value: _noneModel, child: Text(l10n.none)),
                if (hasUnavailableModel)
                  DropdownMenuItem(
                    value: config.modelId,
                    child: Text(
                      l10n.live2dUnavailableLabel(config.displayName),
                    ),
                  ),
                ..._availableModels.map(
                  (model) => DropdownMenuItem(
                    value: model.id,
                    child: Text(
                      model.source == Live2DModelSource.asset
                          ? model.displayName
                          : l10n.live2dImportedLabel(model.displayName),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: _isLoadingModel || _isImporting || _isDeleting
                  ? null
                  : (value) {
                      if (value != null) _selectModel(value);
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                icon: _isImporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.archive_outlined),
                label: Text(l10n.live2dImportZip),
                onPressed: _isImporting || _isDeleting ? null : _importModel,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              key: const Key('live2d-model-error'),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_isLoadingModel)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (config != null && _manifest != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: math.min(MediaQuery.sizeOf(context).width, 420),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Live2DCharacterView(
                  key: ValueKey(
                    '${config.modelDirectory}/${config.modelFileName}',
                  ),
                  config: config.copyWith(enabled: true),
                  controller: _previewController,
                  showStatus: true,
                  interactive: true,
                  onReady: () {
                    if (!mounted ||
                        _previewController.loadedModelId != config.modelId) {
                      return;
                    }
                    _setStateAfterBuild(() => _isPreviewReady = true);
                  },
                  onTransformChanged: (transform) => _setStateAfterBuild(
                    () => _config = config.copyWith(
                      scale: transform.scale,
                      offsetX: transform.offsetX,
                      offsetY: transform.offsetY,
                    ),
                  ),
                ),
              ),
            ),
            if (_manifest?.motions.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<Live2DMotionRef>(
                        initialValue: _selectedMotion,
                        decoration: InputDecoration(
                          labelText: l10n.live2dMotion,
                          border: const OutlineInputBorder(),
                        ),
                        items: _manifest!.motions
                            .map(
                              (motion) => DropdownMenuItem(
                                value: motion,
                                child: Text(
                                  motion.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (motion) =>
                            setState(() => _selectedMotion = motion),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      key: const Key('live2d-preview-play-motion'),
                      icon: _isPlayingPreviewMotion
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      tooltip: l10n.live2dPlayMotion,
                      onPressed: _selectedMotion == null ||
                              !_isPreviewReady ||
                              _isPlayingPreviewMotion
                          ? null
                          : _playPreviewMotion,
                    ),
                  ],
                ),
              ),
            ExpansionTile(
              leading: const Icon(Icons.tune),
              title: Text(l10n.live2dStageAdjustment),
              children: [
                _SliderTile(
                  label: l10n.opacity,
                  value: config.opacity,
                  min: 0.3,
                  max: 1,
                  onChanged: (value) =>
                      setState(() => _config = config.copyWith(opacity: value)),
                ),
                _SliderTile(
                  label: l10n.live2dMotionSpeed,
                  value: config.motionSpeed,
                  min: 0.5,
                  max: 1.5,
                  onChanged: (value) => setState(
                    () => _config = config.copyWith(motionSpeed: value),
                  ),
                ),
              ],
            ),
          ],
          if (importedModels.isNotEmpty) ...[
            const Divider(height: 32),
            ExpansionTile(
              key: const PageStorageKey('live2d-imported-models'),
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(l10n.live2dImportedModels),
              subtitle: Text(
                l10n.live2dModelsCount(importedModels.length),
              ),
              initiallyExpanded: false,
              children: importedModels
                  .map(
                    (model) => ListTile(
                      leading: const Icon(Icons.view_in_ar),
                      title: Text(model.displayName),
                      subtitle: Text(
                        model.modelFileName,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: l10n.live2dDeleteImportedModel,
                        onPressed: _isDeleting || _isImporting
                            ? null
                            : () => _deleteImportedModel(model),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

@visibleForTesting
void scheduleLive2DEditorSetState({
  required bool mounted,
  required void Function(VoidCallback fn) setState,
  required VoidCallback fn,
}) {
  if (!mounted) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) setState(fn);
  });
}

class _SliderTile extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value.toStringAsFixed(2)),
        ],
      ),
      subtitle: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    );
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

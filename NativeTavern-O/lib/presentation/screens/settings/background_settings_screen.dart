import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../../data/models/chat_background.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../providers/background_providers.dart';
import '../../providers/settings_providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/chat/chat_background_widget.dart';

/// Screen for managing chat backgrounds
class BackgroundSettingsScreen extends ConsumerStatefulWidget {
  final String? characterId; // If set, editing character-specific background

  const BackgroundSettingsScreen({super.key, this.characterId});

  @override
  ConsumerState<BackgroundSettingsScreen> createState() =>
      _BackgroundSettingsScreenState();
}

class _BackgroundSettingsScreenState
    extends ConsumerState<BackgroundSettingsScreen> {
  late ChatBackground _currentBackground;
  bool _isLoading = false;

  /// Background gallery (ST 1.17 Background Folders)
  List<_GalleryImage> _galleryImages = [];
  String? _selectedFolder; // null = all folders
  List<String> _galleryFolders = [];

  @override
  void initState() {
    super.initState();
    _loadCurrentBackground();
    _loadGallery();
  }

  Future<Directory> _backgroundsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final bgDir = Directory(p.join(appDir.path, 'NativeTavern', 'backgrounds'));
    await bgDir.create(recursive: true);
    return bgDir;
  }

  Future<void> _loadGallery() async {
    try {
      final bgDir = await _backgroundsDir();
      final images = <_GalleryImage>[];
      final folders = <String>{};

      await for (final entity in bgDir.list(recursive: true)) {
        if (entity is File && _isImageFile(entity.path)) {
          final relative = p.relative(entity.path, from: bgDir.path);
          final folder =
              p.dirname(relative) == '.' ? '' : p.split(relative).first;
          if (folder.isNotEmpty) folders.add(folder);
          images.add(_GalleryImage(
            path: entity.path,
            folder: folder,
            modified: (await entity.stat()).modified,
          ));
        }
      }

      // Newest first
      images.sort((a, b) => b.modified.compareTo(a.modified));

      if (mounted) {
        setState(() {
          _galleryImages = images;
          _galleryFolders = folders.toList()..sort();
        });
      }
    } catch (_) {
      // Gallery is best-effort; ignore scan errors
    }
  }

  bool _isImageFile(String path) {
    final ext = p.extension(path).toLowerCase();
    return const ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp']
        .contains(ext);
  }

  void _loadCurrentBackground() {
    if (widget.characterId != null) {
      final charBg = ref.read(characterBackgroundProvider(widget.characterId!));
      _currentBackground = charBg ?? ChatBackground.none;
    } else {
      _currentBackground = ref.read(globalBackgroundProvider);
    }
  }

  Future<void> _saveBackground(ChatBackground background) async {
    setState(() => _currentBackground = background);

    if (widget.characterId != null) {
      await ref
          .read(characterBackgroundProvider(widget.characterId!).notifier)
          .setBackground(background);
    } else {
      await ref
          .read(globalBackgroundProvider.notifier)
          .setBackground(background);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isCharacterSpecific = widget.characterId != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isCharacterSpecific
            ? l10n.characterBackground
            : l10n.chatBackground),
        actions: [
          if (_currentBackground.type != BackgroundType.none)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.clearBackground,
              onPressed: () => _saveBackground(ChatBackground.none),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Character Avatar Background Setting (only for global settings)
          if (!isCharacterSpecific) ...[
            _buildCharacterAvatarSetting(),
            const SizedBox(height: 24),
          ],

          // Preview
          _buildPreviewSection(),
          const SizedBox(height: 24),

          // Preset gradients
          _buildSectionHeader(l10n.gradientPresets),
          const SizedBox(height: 8),
          _buildGradientPresets(),
          const SizedBox(height: 24),

          // Solid colors
          _buildSectionHeader(l10n.solidColors),
          const SizedBox(height: 8),
          _buildColorPresets(),
          const SizedBox(height: 24),

          // Custom image
          _buildSectionHeader(l10n.customImage),
          const SizedBox(height: 8),
          _buildImageSection(),
          const SizedBox(height: 24),

          // Background gallery with virtual folders
          if (_galleryImages.isNotEmpty) ...[
            _buildSectionHeader(AppLocalizations.of(context).gallery),
            const SizedBox(height: 8),
            _buildGallerySection(),
            const SizedBox(height: 24),
          ],

          // Adjustments
          if (_currentBackground.type != BackgroundType.none) ...[
            _buildSectionHeader(l10n.adjustments),
            const SizedBox(height: 8),
            _buildAdjustments(),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: AppTheme.accentColor,
            fontWeight: FontWeight.bold,
          ),
    );
  }

  Widget _buildCharacterAvatarSetting() {
    final useCharacterAvatar = ref.watch(
        appSettingsProvider.select((s) => s.useCharacterAvatarAsBackground));
    final enableBlur =
        ref.watch(appSettingsProvider.select((s) => s.enableBackgroundBlur));
    final backgroundOpacity =
        ref.watch(appSettingsProvider.select((s) => s.backgroundOpacity));
    final l10n = AppLocalizations.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wallpaper, color: AppTheme.accentColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.imageBackgroundSettings,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Use character avatar toggle
            SwitchListTile(
              title: Text(l10n.useCharacterImageAsBackground),
              subtitle: Text(l10n.useCharacterImageAsBackgroundHint),
              value: useCharacterAvatar,
              onChanged: (value) {
                ref
                    .read(appSettingsProvider.notifier)
                    .updateUseCharacterAvatarAsBackground(value);
              },
              contentPadding: EdgeInsets.zero,
            ),

            const Divider(height: 24),

            // Background opacity slider
            Row(
              children: [
                const Icon(Icons.opacity, size: 20),
                const SizedBox(width: 12),
                Text(l10n.backgroundOpacity),
                const Spacer(),
                Text('${(backgroundOpacity * 100).round()}%'),
              ],
            ),
            const SizedBox(height: 8),
            Slider(
              value: backgroundOpacity,
              min: 0.1,
              max: 1.0,
              divisions: 18,
              onChanged: (value) {
                ref
                    .read(appSettingsProvider.notifier)
                    .updateBackgroundOpacity(value);
              },
            ),
            Text(
              l10n.backgroundOpacityHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textMuted,
                  ),
            ),

            const Divider(height: 24),

            // Background blur toggle
            SwitchListTile(
              title: Text(l10n.enableBackgroundBlur),
              subtitle: Text(l10n.enableBackgroundBlurHint),
              value: enableBlur,
              onChanged: (value) {
                ref
                    .read(appSettingsProvider.notifier)
                    .updateEnableBackgroundBlur(value);
              },
              contentPadding: EdgeInsets.zero,
            ),

            const SizedBox(height: 8),
            Text(
              l10n.backgroundPriorityHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textMuted,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewSection() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_currentBackground.type != BackgroundType.none)
              _BackgroundPreviewFull(background: _currentBackground)
            else
              Container(
                color: AppTheme.darkBackground,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.wallpaper,
                          size: 48, color: AppTheme.textMuted),
                      const SizedBox(height: 8),
                      Text(
                        AppLocalizations.of(context).noBackgroundSelected,
                        style: const TextStyle(color: AppTheme.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            // Sample chat bubbles overlay
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.darkCard
                          .withValues(alpha: _currentBackground.bubbleOpacity),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      AppLocalizations.of(context).sampleMessage1,
                      style: const TextStyle(color: AppTheme.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.accentColor.withValues(
                            alpha: _currentBackground.bubbleOpacity),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        AppLocalizations.of(context).sampleMessage2,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGradientPresets() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        BackgroundPreview(
          background: ChatBackground.none,
          selected: _currentBackground.type == BackgroundType.none,
          onTap: () => _saveBackground(ChatBackground.none),
        ),
        ...BackgroundPresets.gradients.map((bg) => BackgroundPreview(
              background: bg,
              selected: _currentBackground.type == BackgroundType.gradient &&
                  _currentBackground.gradientColors?.join(',') ==
                      bg.gradientColors?.join(','),
              onTap: () => _saveBackground(bg),
            )),
      ],
    );
  }

  Widget _buildColorPresets() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: BackgroundPresets.solidColors
          .map((bg) => BackgroundPreview(
                background: bg,
                selected: _currentBackground.type == BackgroundType.color &&
                    _currentBackground.color == bg.color,
                onTap: () => _saveBackground(bg),
              ))
          .toList(),
    );
  }

  Widget _buildImageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.image),
                label: Text(AppLocalizations.of(context).chooseImage),
                onPressed: _isLoading ? null : _pickImage,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.link),
                label: Text(AppLocalizations.of(context).fromUrl),
                onPressed: _isLoading ? null : _showUrlDialog,
              ),
            ),
          ],
        ),
        if (_currentBackground.type == BackgroundType.image) ...[
          const SizedBox(height: 12),
          Text(
            _currentBackground.imagePath != null
                ? AppLocalizations.of(context)
                    .localImage(p.basename(_currentBackground.imagePath!))
                : _currentBackground.imageUrl != null
                    ? AppLocalizations.of(context)
                        .urlLabel(_currentBackground.imageUrl!)
                    : AppLocalizations.of(context).noImage,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textMuted,
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  Widget _buildAdjustments() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Bubble opacity slider
            Row(
              children: [
                const Icon(Icons.chat_bubble_outline, size: 20),
                const SizedBox(width: 12),
                Text(AppLocalizations.of(context).bubbleOpacity),
                const SizedBox(width: 4),
                Tooltip(
                  message: AppLocalizations.of(context).bubbleOpacityHelp,
                  triggerMode: TooltipTriggerMode.tap,
                  child: const Icon(Icons.info_outline,
                      size: 16, color: AppTheme.textMuted),
                ),
                const Spacer(),
                Text('${(_currentBackground.bubbleOpacity * 100).round()}%'),
              ],
            ),
            Slider(
              value: _currentBackground.bubbleOpacity,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              onChanged: (value) {
                _saveBackground(
                    _currentBackground.copyWith(bubbleOpacity: value));
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGallerySection() {
    final visibleImages = _selectedFolder == null
        ? _galleryImages
        : _galleryImages.where((i) => i.folder == _selectedFolder).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Folder filter chips
        if (_galleryFolders.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: Text(AppLocalizations.of(context).allLabel),
                  selected: _selectedFolder == null,
                  onSelected: (_) => setState(() => _selectedFolder = null),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(AppLocalizations.of(context).ungrouped),
                  selected: _selectedFolder == '',
                  onSelected: (_) => setState(() => _selectedFolder = ''),
                ),
                for (final folder in _galleryFolders) ...[
                  const SizedBox(width: 8),
                  ChoiceChip(
                    avatar: const Icon(Icons.folder, size: 16),
                    label: Text(folder),
                    selected: _selectedFolder == folder,
                    onSelected: (_) => setState(() => _selectedFolder = folder),
                  ),
                ],
              ],
            ),
          ),
        if (_galleryFolders.isNotEmpty) const SizedBox(height: 12),

        // Image grid with thumbnails
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 0.75,
          ),
          itemCount: visibleImages.length,
          itemBuilder: (context, index) {
            final image = visibleImages[index];
            final isActive = _currentBackground.imagePath == image.path;
            return GestureDetector(
              onTap: () => _applyGalleryImage(image),
              onLongPress: () => _showGalleryImageOptions(image),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isActive
                      ? Border.all(color: AppTheme.accentColor, width: 2)
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(image.path),
                    fit: BoxFit.cover,
                    cacheWidth: 300,
                    errorBuilder: (_, __, ___) => Container(
                      color: AppTheme.darkCard,
                      child: const Icon(Icons.broken_image,
                          color: AppTheme.textMuted),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  void _applyGalleryImage(_GalleryImage image) {
    final enableBlur =
        ref.read(appSettingsProvider.select((s) => s.enableBackgroundBlur));
    final opacity =
        ref.read(appSettingsProvider.select((s) => s.backgroundOpacity));
    _saveBackground(ChatBackground.imagePath(
      image.path,
      opacity: opacity,
      blur: enableBlur,
      blurAmount: 10.0,
      bubbleOpacity: _currentBackground.bubbleOpacity,
    ));
  }

  void _showGalleryImageOptions(_GalleryImage image) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.wallpaper),
              title: Text(AppLocalizations.of(context).setAsBackground),
              onTap: () {
                Navigator.pop(context);
                _applyGalleryImage(image);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text(AppLocalizations.of(context).moveToFolder),
              onTap: () {
                Navigator.pop(context);
                _showMoveToFolderDialog(image);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(AppLocalizations.of(context).delete,
                  style: const TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(context);
                await _deleteGalleryImage(image);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMoveToFolderDialog(_GalleryImage image) async {
    final controller = TextEditingController(text: image.folder);
    final l10n = AppLocalizations.of(context);
    final folder = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.moveToFolder),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: l10n.folderName,
                hintText: l10n.folderNameHint,
              ),
              autofocus: true,
            ),
            if (_galleryFolders.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: _galleryFolders
                    .map((f) => ActionChip(
                          label: Text(f),
                          onPressed: () => Navigator.pop(context, f),
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l10n.move),
          ),
        ],
      ),
    );

    if (folder == null) return;

    try {
      final bgDir = await _backgroundsDir();
      final targetDir =
          folder.isEmpty ? bgDir : Directory(p.join(bgDir.path, folder));
      await targetDir.create(recursive: true);
      final newPath = p.join(targetDir.path, p.basename(image.path));
      if (newPath != image.path) {
        await File(image.path).rename(newPath);
        // Keep the active background pointing at the moved file
        if (_currentBackground.imagePath == image.path) {
          await _saveBackground(
              _currentBackground.copyWith(imagePath: newPath));
        }
      }
      await _loadGallery();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).moveFailed('$e'))));
      }
    }
  }

  Future<void> _deleteGalleryImage(_GalleryImage image) async {
    try {
      await File(image.path).delete();
      if (_currentBackground.imagePath == image.path) {
        await _saveBackground(ChatBackground.none);
      }
      await _loadGallery();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).deleteFailed('$e'))));
      }
    }
  }

  Future<void> _pickImage() async {
    setState(() => _isLoading = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        if (file.path != null) {
          // Copy to app directory (into the selected gallery folder, if any)
          final baseDir = await _backgroundsDir();
          final bgDir = (_selectedFolder == null || _selectedFolder!.isEmpty)
              ? baseDir
              : Directory(p.join(baseDir.path, _selectedFolder!));
          await bgDir.create(recursive: true);

          final fileName =
              '${DateTime.now().millisecondsSinceEpoch}_${file.name}';
          final destPath = p.join(bgDir.path, fileName);
          await File(file.path!).copy(destPath);
          await _loadGallery();

          // Get global settings
          final enableBlur = ref
              .read(appSettingsProvider.select((s) => s.enableBackgroundBlur));
          final opacity =
              ref.read(appSettingsProvider.select((s) => s.backgroundOpacity));

          await _saveBackground(ChatBackground.imagePath(
            destPath,
            opacity: opacity,
            blur: enableBlur,
            blurAmount: 10.0,
            bubbleOpacity: _currentBackground.bubbleOpacity,
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)
                  .failedToLoadImage(e.toString()))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showUrlDialog() {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.imageUrl),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: l10n.enterImageUrl,
            hintText: 'https://example.com/image.jpg',
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              final url = controller.text.trim();
              if (url.isNotEmpty) {
                // Get global settings
                final enableBlur = ref.read(
                    appSettingsProvider.select((s) => s.enableBackgroundBlur));
                final opacity = ref.read(
                    appSettingsProvider.select((s) => s.backgroundOpacity));

                _saveBackground(ChatBackground.imageUrl(
                  url,
                  opacity: opacity,
                  blur: enableBlur,
                  blurAmount: 10.0,
                  bubbleOpacity: _currentBackground.bubbleOpacity,
                ));
                Navigator.pop(context);
              }
            },
            child: Text(l10n.apply),
          ),
        ],
      ),
    );
  }
}

/// A background image in the gallery
class _GalleryImage {
  final String path;
  final String folder; // '' = ungrouped (root directory)
  final DateTime modified;

  const _GalleryImage({
    required this.path,
    required this.folder,
    required this.modified,
  });
}

class _BackgroundPreviewFull extends StatelessWidget {
  final ChatBackground background;

  const _BackgroundPreviewFull({required this.background});

  @override
  Widget build(BuildContext context) {
    switch (background.type) {
      case BackgroundType.none:
        return Container(color: AppTheme.darkBackground);

      case BackgroundType.color:
        return Container(color: _parseColor(background.color));

      case BackgroundType.gradient:
        final colors = background.gradientColors ?? ['#000000', '#333333'];
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: colors.map(_parseColor).toList(),
            ),
          ),
        );

      case BackgroundType.image:
        if (background.imagePath != null) {
          return Opacity(
            opacity: background.opacity,
            child: Image.file(
              File(background.imagePath!),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(color: Colors.grey[800]),
            ),
          );
        }
        if (background.imageUrl != null) {
          return Opacity(
            opacity: background.opacity,
            child: Image.network(
              background.imageUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(color: Colors.grey[800]),
            ),
          );
        }
        return Container(color: Colors.grey[800]);
    }
  }

  Color _parseColor(String? hexColor) {
    if (hexColor == null || hexColor.isEmpty) {
      return Colors.transparent;
    }

    String hex = hexColor.replaceAll('#', '');
    if (hex.length == 6) {
      hex = 'FF$hex';
    }
    return Color(int.parse(hex, radix: 16));
  }
}

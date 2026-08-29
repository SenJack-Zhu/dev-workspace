import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:native_tavern/data/models/persona.dart';
import 'package:native_tavern/presentation/providers/persona_providers.dart';
import 'package:native_tavern/presentation/providers/character_providers.dart';
import 'package:native_tavern/presentation/providers/group_providers.dart';
import 'package:native_tavern/presentation/providers/world_info_providers.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';

/// Enhanced Persona Editor Screen with all new fields
class PersonaEditorScreen extends ConsumerStatefulWidget {
  final Persona? persona; // null for creating new persona

  const PersonaEditorScreen({super.key, this.persona});

  @override
  ConsumerState<PersonaEditorScreen> createState() =>
      _PersonaEditorScreenState();
}

class _PersonaEditorScreenState extends ConsumerState<PersonaEditorScreen>
    with SingleTickerProviderStateMixin {
  AppLocalizations get _l10n => AppLocalizations.of(context);
  late TabController _tabController;
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _systemPromptController;
  late TextEditingController _postHistoryController;
  late TextEditingController _creatorNotesController;
  late TextEditingController _tagInputController;

  String? _avatarPath;
  bool _isFavorite = false;
  String? _lorebookId;
  List<String> _tags = [];
  List<PersonaConnection> _connections = [];
  PersonaDescriptionSettings _descriptionSettings =
      const PersonaDescriptionSettings();

  bool _isSaving = false;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    // Initialize controllers with existing data
    final persona = widget.persona;
    _nameController = TextEditingController(text: persona?.name ?? '');
    _descriptionController =
        TextEditingController(text: persona?.description ?? '');
    _systemPromptController =
        TextEditingController(text: persona?.systemPromptOverride ?? '');
    _postHistoryController =
        TextEditingController(text: persona?.postHistoryInstructions ?? '');
    _creatorNotesController =
        TextEditingController(text: persona?.creatorNotes ?? '');
    _tagInputController = TextEditingController();

    _avatarPath = persona?.avatarPath;
    _isFavorite = persona?.isFavorite ?? false;
    _lorebookId = persona?.lorebookId;
    _tags = List.from(persona?.tags ?? []);
    _connections = List.from(persona?.connections ?? []);
    _descriptionSettings =
        persona?.descriptionSettings ?? const PersonaDescriptionSettings();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _systemPromptController.dispose();
    _postHistoryController.dispose();
    _creatorNotesController.dispose();
    _tagInputController.dispose();
    super.dispose();
  }

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.persona == null ? _l10n.createPersona : _l10n.editPersona,
        ),
        actions: [
          IconButton(
            icon: Icon(_isFavorite ? Icons.star : Icons.star_border),
            tooltip: _l10n.favorite,
            onPressed: () => setState(() => _isFavorite = !_isFavorite),
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: _l10n.save,
            onPressed: _isSaving ? null : _save,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: _l10n.basic, icon: const Icon(Icons.person)),
            Tab(text: _l10n.advanced, icon: const Icon(Icons.settings)),
            Tab(text: _l10n.connections, icon: const Icon(Icons.link)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildBasicTab(),
          _buildAdvancedTab(),
          _buildConnectionsTab(),
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
          // Avatar picker
          Center(child: _buildAvatarPicker()),
          const SizedBox(height: 24),

          // Name
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: _l10n.name,
              hintText: _l10n.enterPersonaName,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.badge),
            ),
          ),
          const SizedBox(height: 16),

          // Description
          TextField(
            controller: _descriptionController,
            decoration: InputDecoration(
              labelText: _l10n.description,
              hintText: _l10n.describePersona,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.description),
              helperText: _l10n.personaDescriptionHelp,
            ),
            maxLines: 5,
          ),
          const SizedBox(height: 16),

          // Tags
          _buildTagsSection(),
          const SizedBox(height: 16),

          // Creator Notes
          TextField(
            controller: _creatorNotesController,
            decoration: InputDecoration(
              labelText: _l10n.creatorNotes,
              hintText: _l10n.creatorNotesNotSentToAi,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.note),
            ),
            maxLines: 3,
          ),
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
          // Lorebook Selection
          _buildLorebookSelector(),
          const SizedBox(height: 16),

          // System Prompt Override
          TextField(
            controller: _systemPromptController,
            decoration: InputDecoration(
              labelText: _l10n.systemPromptOverride,
              hintText: _l10n.systemPromptOverrideHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.code),
              helperText: _l10n.systemPromptOverrideDescription,
            ),
            maxLines: 5,
          ),
          const SizedBox(height: 16),

          // Post-History Instructions
          TextField(
            controller: _postHistoryController,
            decoration: InputDecoration(
              labelText: _l10n.postHistoryInstructions,
              hintText: _l10n.instructionsAddedAfterHistory,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.history),
              helperText: _l10n.instructionsInsertedAfterHistory,
            ),
            maxLines: 5,
          ),
          const SizedBox(height: 16),

          // Description Settings
          _buildDescriptionSettings(),
        ],
      ),
    );
  }

  Widget _buildConnectionsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _l10n.bindPersonaDescription,
                  style: const TextStyle(color: AppTheme.textSecondary),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: _l10n.addConnection,
                onPressed: _showAddConnectionDialog,
              ),
            ],
          ),
        ),
        Expanded(
          child: _connections.isEmpty
              ? Center(
                  child: Text(
                    _l10n.noConnections,
                    style: const TextStyle(color: AppTheme.textMuted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _connections.length,
                  itemBuilder: (context, index) {
                    final connection = _connections[index];
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          connection.characterId != null
                              ? Icons.person
                              : connection.groupId != null
                                  ? Icons.group
                                  : Icons.chat,
                          color: AppTheme.primaryColor,
                        ),
                        title: Text(
                          connection.characterId != null
                              ? _l10n
                                  .connectionCharacter(connection.characterId!)
                              : connection.groupId != null
                                  ? _l10n.connectionGroup(connection.groupId!)
                                  : _l10n.connectionChat(connection.chatId!),
                        ),
                        subtitle: Text(_l10n.lockLabel(
                          _personaLockName(connection.lockType, _l10n),
                        )),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () => _removeConnection(index),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTagsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _l10n.tags,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ..._tags.map((tag) => Chip(
                  label: Text(tag),
                  onDeleted: () => setState(() => _tags.remove(tag)),
                  deleteIcon: const Icon(Icons.close, size: 18),
                )),
            ActionChip(
              label: Text(_l10n.addTag),
              avatar: const Icon(Icons.add, size: 18),
              onPressed: _showAddTagDialog,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLorebookSelector() {
    final lorebooksAsync = ref.watch(allWorldInfosProvider);

    return lorebooksAsync.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, __) => Text(_l10n.errorLoadingLorebooks('$error')),
      data: (lorebooks) {
        return DropdownButtonFormField<String?>(
          value: _lorebookId,
          decoration: InputDecoration(
            labelText: _l10n.personaLorebook,
            hintText: _l10n.selectLorebook,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.book),
            helperText: _l10n.personaLorebookDescription,
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(_l10n.none),
            ),
            ...lorebooks.map((lb) => DropdownMenuItem(
                  value: lb.id,
                  child: Text(lb.name),
                )),
          ],
          onChanged: (value) => setState(() => _lorebookId = value),
        );
      },
    );
  }

  Widget _buildDescriptionSettings() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _l10n.descriptionPlacement,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PersonaDescriptionPosition>(
              value: _descriptionSettings.position,
              decoration: InputDecoration(
                labelText: _l10n.position,
                border: const OutlineInputBorder(),
                helperText: _l10n.personaDescriptionPositionHelp,
              ),
              items: PersonaDescriptionPosition.values.map((pos) {
                return DropdownMenuItem(
                  value: pos,
                  child: Text(_personaPositionName(pos, _l10n)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _descriptionSettings =
                        _descriptionSettings.copyWith(position: value);
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            if (_descriptionSettings.position ==
                PersonaDescriptionPosition.atDepth)
              TextField(
                decoration: InputDecoration(
                  labelText: _l10n.depth,
                  border: const OutlineInputBorder(),
                  helperText: _l10n.depthInChatHistory,
                ),
                keyboardType: TextInputType.number,
                controller: TextEditingController(
                  text: _descriptionSettings.depth.toString(),
                ),
                onChanged: (value) {
                  final depth = int.tryParse(value) ?? 4;
                  setState(() {
                    _descriptionSettings =
                        _descriptionSettings.copyWith(depth: depth);
                  });
                },
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PersonaDescriptionRole>(
              value: _descriptionSettings.role,
              decoration: InputDecoration(
                labelText: _l10n.messageRole,
                border: const OutlineInputBorder(),
                helperText: _l10n.roleForDescription,
              ),
              items: PersonaDescriptionRole.values.map((role) {
                return DropdownMenuItem(
                  value: role,
                  child: Text(_personaRoleName(role, _l10n)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _descriptionSettings =
                        _descriptionSettings.copyWith(role: value);
                  });
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarPicker() {
    return Stack(
      children: [
        GestureDetector(
          onTap: _showAvatarOptions,
          child: CircleAvatar(
            radius: 60,
            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.2),
            backgroundImage:
                _avatarPath != null ? FileImage(File(_avatarPath!)) : null,
            child: _avatarPath == null
                ? const Icon(Icons.person,
                    size: 60, color: AppTheme.primaryColor)
                : null,
          ),
        ),
        Positioned(
          bottom: 0,
          right: 0,
          child: GestureDetector(
            onTap: _showAvatarOptions,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.darkCard, width: 2),
              ),
              child:
                  const Icon(Icons.camera_alt, size: 20, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  void _showAvatarOptions() {
    if (_isDesktop) {
      _pickImageFromFiles();
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.darkCard,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(_l10n.chooseFromGallery),
              onTap: () {
                Navigator.pop(context);
                _pickImageFromGallery();
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(_l10n.takePhoto),
              onTap: () {
                Navigator.pop(context);
                _takePhoto();
              },
            ),
            if (_avatarPath != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: Text(_l10n.removeAvatar,
                    style: const TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _avatarPath = null);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImageFromFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result != null && result.files.first.path != null) {
        await _saveAvatarImage(result.files.first.path!);
      }
    } catch (e) {
      _showError(_l10n.failedToPickImage('$e'));
    }
  }

  Future<void> _pickImageFromGallery() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image != null) {
        await _saveAvatarImage(image.path);
      }
    } catch (e) {
      _showError(_l10n.failedToPickImage('$e'));
    }
  }

  Future<void> _takePhoto() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image != null) {
        await _saveAvatarImage(image.path);
      }
    } catch (e) {
      _showError(_l10n.failedToTakePhoto('$e'));
    }
  }

  Future<void> _saveAvatarImage(String sourcePath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final avatarsDir =
          Directory(p.join(appDir.path, 'NativeTavern', 'avatars', 'personas'));
      await avatarsDir.create(recursive: true);

      const uuid = Uuid();
      final extension = p.extension(sourcePath);
      final newFileName = '${uuid.v4()}$extension';
      final newPath = p.join(avatarsDir.path, newFileName);

      await File(sourcePath).copy(newPath);
      setState(() => _avatarPath = newPath);
    } catch (e) {
      _showError(_l10n.failedToSaveAvatar('$e'));
    }
  }

  void _showAddTagDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_l10n.addTag),
        content: TextField(
          controller: _tagInputController,
          decoration: InputDecoration(
            hintText: _l10n.enterTagName,
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty && !_tags.contains(value.trim())) {
              setState(() => _tags.add(value.trim()));
              _tagInputController.clear();
            }
            Navigator.pop(context);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              final value = _tagInputController.text.trim();
              if (value.isNotEmpty && !_tags.contains(value)) {
                setState(() => _tags.add(value));
                _tagInputController.clear();
              }
              Navigator.pop(context);
            },
            child: Text(_l10n.add),
          ),
        ],
      ),
    );
  }

  void _showAddConnectionDialog() {
    showDialog(
      context: context,
      builder: (context) => _AddConnectionDialog(
        onAdd: (connection) {
          setState(() {
            _connections.removeWhere((existing) =>
                (connection.characterId != null &&
                    existing.characterId == connection.characterId) ||
                (connection.groupId != null &&
                    existing.groupId == connection.groupId) ||
                (connection.chatId != null &&
                    existing.chatId == connection.chatId));
            _connections.add(connection);
          });
        },
      ),
    );
  }

  void _removeConnection(int index) {
    setState(() => _connections.removeAt(index));
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showError(_l10n.pleaseEnterAName);
      return;
    }

    setState(() => _isSaving = true);

    try {
      final now = DateTime.now();
      final persona = Persona(
        id: widget.persona?.id ?? now.millisecondsSinceEpoch.toString(),
        name: name,
        description: _descriptionController.text.trim(),
        avatarPath: _avatarPath,
        isDefault: widget.persona?.isDefault ?? false,
        createdAt: widget.persona?.createdAt ?? now,
        updatedAt: now,
        connections: _connections,
        descriptionSettings: _descriptionSettings,
        lorebookId: _lorebookId,
        systemPromptOverride: _systemPromptController.text.trim().isEmpty
            ? null
            : _systemPromptController.text.trim(),
        postHistoryInstructions: _postHistoryController.text.trim().isEmpty
            ? null
            : _postHistoryController.text.trim(),
        tags: _tags,
        creatorNotes: _creatorNotesController.text.trim(),
        isFavorite: _isFavorite,
      );

      if (widget.persona == null) {
        await ref.read(personaNotifierProvider.notifier).createPersona(persona);
      } else {
        await ref.read(personaNotifierProvider.notifier).updatePersona(persona);
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
}

/// Dialog for adding a persona connection
class _AddConnectionDialog extends ConsumerStatefulWidget {
  final Function(PersonaConnection) onAdd;

  const _AddConnectionDialog({required this.onAdd});

  @override
  ConsumerState<_AddConnectionDialog> createState() =>
      _AddConnectionDialogState();
}

class _AddConnectionDialogState extends ConsumerState<_AddConnectionDialog> {
  _ConnectionTarget _target = _ConnectionTarget.character;
  String? _selectedId;
  PersonaLockType _lockType = PersonaLockType.none;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.addConnection),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Type selector
          SegmentedButton<_ConnectionTarget>(
            segments: [
              ButtonSegment(
                value: _ConnectionTarget.character,
                label: Text(l10n.character),
                icon: const Icon(Icons.person),
              ),
              ButtonSegment(
                value: _ConnectionTarget.group,
                label: Text(l10n.group),
                icon: const Icon(Icons.group),
              ),
              ButtonSegment(
                value: _ConnectionTarget.chat,
                label: Text(l10n.chat),
                icon: const Icon(Icons.chat),
              ),
            ],
            selected: {_target},
            onSelectionChanged: (Set<_ConnectionTarget> selected) {
              setState(() {
                _target = selected.first;
                _selectedId = null;
              });
            },
          ),
          const SizedBox(height: 16),

          // Entity selector
          switch (_target) {
            _ConnectionTarget.character => _buildCharacterSelector(),
            _ConnectionTarget.group => _buildGroupSelector(),
            _ConnectionTarget.chat => _buildChatSelector(),
          },
          const SizedBox(height: 16),

          // Lock type
          DropdownButtonFormField<PersonaLockType>(
            value: _lockType,
            decoration: InputDecoration(
              labelText: l10n.lockType,
              border: const OutlineInputBorder(),
            ),
            items: PersonaLockType.values.map((type) {
              return DropdownMenuItem(
                value: type,
                child: Text(_personaLockName(type, l10n)),
              );
            }).toList(),
            onChanged: (value) =>
                setState(() => _lockType = value ?? PersonaLockType.none),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: _selectedId == null
              ? null
              : () {
                  widget.onAdd(
                    PersonaConnection(
                      characterId: _target == _ConnectionTarget.character
                          ? _selectedId
                          : null,
                      groupId: _target == _ConnectionTarget.group
                          ? _selectedId
                          : null,
                      chatId: _target == _ConnectionTarget.chat
                          ? _selectedId
                          : null,
                      lockType: _lockType,
                    ),
                  );
                  Navigator.pop(context);
                },
          child: Text(l10n.add),
        ),
      ],
    );
  }

  Widget _buildCharacterSelector() {
    final charactersAsync = ref.watch(characterListProvider);
    final l10n = AppLocalizations.of(context);
    return charactersAsync.when(
      loading: () => const CircularProgressIndicator(),
      error: (error, __) => Text(l10n.errorLoadingCharacters('$error')),
      data: (characters) => DropdownButtonFormField<String>(
        value: _selectedId,
        decoration: InputDecoration(
          labelText: l10n.character,
          border: const OutlineInputBorder(),
        ),
        items: characters
            .map((char) => DropdownMenuItem(
                  value: char.id,
                  child: Text(char.name),
                ))
            .toList(),
        onChanged: (value) => setState(() => _selectedId = value),
      ),
    );
  }

  Widget _buildGroupSelector() {
    final groupsAsync = ref.watch(groupListProvider);
    final l10n = AppLocalizations.of(context);
    return groupsAsync.when(
      loading: () => const CircularProgressIndicator(),
      error: (error, __) => Text(l10n.errorLoadingGroups('$error')),
      data: (groups) => DropdownButtonFormField<String>(
        value: _selectedId,
        decoration: InputDecoration(
          labelText: l10n.group,
          border: const OutlineInputBorder(),
        ),
        items: groups
            .map((group) => DropdownMenuItem(
                  value: group.id,
                  child: Text(group.name),
                ))
            .toList(),
        onChanged: (value) => setState(() => _selectedId = value),
      ),
    );
  }

  Widget _buildChatSelector() {
    final chatsAsync = ref.watch(allChatsProvider);
    final l10n = AppLocalizations.of(context);
    return chatsAsync.when(
      loading: () => const CircularProgressIndicator(),
      error: (error, __) => Text(l10n.errorLoadingChats('$error')),
      data: (chats) => DropdownButtonFormField<String>(
        value: _selectedId,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.chat,
          border: const OutlineInputBorder(),
        ),
        items: chats
            .map((chat) => DropdownMenuItem(
                  value: chat.id,
                  child: Text(chat.title, overflow: TextOverflow.ellipsis),
                ))
            .toList(),
        onChanged: (value) => setState(() => _selectedId = value),
      ),
    );
  }
}

enum _ConnectionTarget { character, group, chat }

String _personaPositionName(
  PersonaDescriptionPosition position,
  AppLocalizations l10n,
) {
  return switch (position) {
    PersonaDescriptionPosition.beforeChar => l10n.beforeCharacterDefinition,
    PersonaDescriptionPosition.afterChar => l10n.afterCharacterDefinition,
    PersonaDescriptionPosition.atDepth => l10n.atDepth,
    PersonaDescriptionPosition.inSystemPrompt => l10n.inSystemPrompt,
    PersonaDescriptionPosition.topAN => l10n.beforeAuthorNote,
    PersonaDescriptionPosition.bottomAN => l10n.afterAuthorNote,
  };
}

String _personaRoleName(
  PersonaDescriptionRole role,
  AppLocalizations l10n,
) {
  return switch (role) {
    PersonaDescriptionRole.system => l10n.system,
    PersonaDescriptionRole.user => l10n.user,
    PersonaDescriptionRole.assistant => l10n.assistant,
  };
}

String _personaLockName(PersonaLockType lock, AppLocalizations l10n) {
  return switch (lock) {
    PersonaLockType.none => l10n.none,
    PersonaLockType.chat => l10n.chat,
    PersonaLockType.character => l10n.character,
    PersonaLockType.defaultLock => l10n.default_,
  };
}

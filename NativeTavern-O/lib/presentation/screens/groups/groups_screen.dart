import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/data/models/group.dart';
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/presentation/providers/group_providers.dart';
import 'package:native_tavern/presentation/providers/character_providers.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';
import 'package:native_tavern/presentation/widgets/common/character_avatar_image.dart';
import 'package:native_tavern/presentation/widgets/common/group_avatar.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/widgets/common/adaptive_popup_menu.dart';

/// Groups list screen
class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(groupListProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.groupChats),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(groupListProvider.notifier).refresh(),
          ),
        ],
      ),
      body: groupsAsync.when(
        data: (groups) {
          if (groups.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.groups,
                    size: 80,
                    color: AppTheme.textMuted,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizations.of(context)!.noGroupChatsYet,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizations.of(context)!.createGroupDescription,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textMuted,
                        ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _showCreateGroupDialog(context, ref),
                    icon: const Icon(Icons.add),
                    label: Text(AppLocalizations.of(context)!.createGroup),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: groups.length,
            itemBuilder: (context, index) {
              return _GroupCard(group: groups[index]);
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text('${AppLocalizations.of(context)!.error}: $error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.read(groupListProvider.notifier).refresh(),
                child: Text(AppLocalizations.of(context)!.retry),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateGroupDialog(context, ref),
        icon: const Icon(Icons.add),
        label: Text(AppLocalizations.of(context)!.newGroup),
      ),
    );
  }

  void _showCreateGroupDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => const _CreateGroupDialog(),
    );
  }
}

class _GroupCard extends ConsumerWidget {
  final Group group;

  const _GroupCard({required this.group});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => context.push('/groups/${group.id}'),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Group avatar or first few members
                  _buildGroupAvatar(context, ref),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (group.description != null &&
                            group.description!.isNotEmpty)
                          Text(
                            group.description!,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppTheme.textMuted,
                                    ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        const SizedBox(height: 4),
                        Text(
                          AppLocalizations.of(context)!.membersAndMode(
                              group.members.length,
                              group.settings.effectiveResponseMode.name),
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppTheme.textMuted,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  AdaptivePopupMenuButton<String>(
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'chat',
                        child: ListTile(
                          leading: const Icon(Icons.chat),
                          title: Text(AppLocalizations.of(context)!.startChat),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: const Icon(Icons.edit),
                          title: Text(AppLocalizations.of(context)!.edit),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: const Icon(Icons.delete, color: Colors.red),
                          title: Text(AppLocalizations.of(context)!.delete,
                              style: const TextStyle(color: Colors.red)),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                    onSelected: (value) {
                      switch (value) {
                        case 'chat':
                          _startGroupChat(context, ref);
                          break;
                        case 'edit':
                          context.push('/groups/${group.id}');
                          break;
                        case 'delete':
                          _confirmDelete(context, ref);
                          break;
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Member avatars
              _buildMemberAvatars(context, ref),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroupAvatar(BuildContext context, WidgetRef ref) {
    final members = group.sortedMembers.take(4).toList(growable: false);
    return FutureBuilder<List<Character?>>(
      future: Future.wait(
        members.map(
          (member) => ref
              .read(characterRepositoryProvider)
              .getCharacter(member.characterId),
        ),
      ),
      builder: (context, snapshot) => GroupAvatar(
        characters: snapshot.data ?? const [],
      ),
    );
  }

  Widget _buildMemberAvatars(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: group.members.length,
        itemBuilder: (context, index) {
          final member = group.members[index];
          return FutureBuilder<Character?>(
            future: ref
                .read(characterRepositoryProvider)
                .getCharacter(member.characterId),
            builder: (context, snapshot) {
              final Character? character = snapshot.data;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message:
                      character?.name ?? AppLocalizations.of(context).unknown,
                  child: Stack(
                    children: [
                      character?.assets?.avatarPath != null
                          ? CharacterAvatarCircle(
                              imagePath: character!.assets!.avatarPath!,
                              radius: 20,
                              errorBuilder: (_, __, ___) => CircleAvatar(
                                radius: 20,
                                backgroundColor: AppTheme.darkDivider,
                                child: Text(
                                  character.name.substring(0, 1).toUpperCase(),
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ),
                            )
                          : CircleAvatar(
                              radius: 20,
                              backgroundColor: AppTheme.darkDivider,
                              child: Text(
                                character?.name.substring(0, 1).toUpperCase() ??
                                    '?',
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                      if (member.isMuted)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(
                              Icons.volume_off,
                              size: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _startGroupChat(BuildContext context, WidgetRef ref) async {
    final chatId =
        await ref.read(activeChatProvider.notifier).createGroupChat(group);
    if (!context.mounted) return;
    if (chatId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context)!.failedToCreateChat)),
      );
      return;
    }
    context.push('/chat/$chatId');
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.deleteGroup),
        content: Text(
            AppLocalizations.of(context)!.deleteGroupConfirmation(group.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(groupListProvider.notifier).deleteGroup(group.id);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text(AppLocalizations.of(context)!
                        .groupDeleted(group.name))),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(AppLocalizations.of(context)!.delete),
          ),
        ],
      ),
    );
  }
}

class _CreateGroupDialog extends ConsumerStatefulWidget {
  const _CreateGroupDialog();

  @override
  ConsumerState<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends ConsumerState<_CreateGroupDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _selectedCharacterIds = <String>{};
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onFormChanged);
  }

  void _onFormChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _nameController.removeListener(_onFormChanged);
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final charactersAsync = ref.watch(characterListProvider);

    return AlertDialog(
      title: Text(AppLocalizations.of(context)!.createGroup),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context)!.groupNameRequired,
                hintText: AppLocalizations.of(context)!.enterGroupName,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context)!.description,
                hintText: AppLocalizations.of(context)!.optionalDescription,
                border: const OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context)!.selectCharacters,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              AppLocalizations.of(context)!.selectAtLeast2Characters,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textMuted,
                  ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: charactersAsync.when(
                data: (characters) {
                  if (characters.isEmpty) {
                    return Center(
                      child: Text(
                          AppLocalizations.of(context)!.noCharactersAvailable),
                    );
                  }
                  return ListView.builder(
                    itemCount: characters.length,
                    itemBuilder: (context, index) {
                      final character = characters[index];
                      final isSelected =
                          _selectedCharacterIds.contains(character.id);
                      return CheckboxListTile(
                        value: isSelected,
                        onChanged: (value) {
                          setState(() {
                            if (value == true) {
                              _selectedCharacterIds.add(character.id);
                            } else {
                              _selectedCharacterIds.remove(character.id);
                            }
                          });
                        },
                        title: Text(character.name),
                        secondary: character.assets?.avatarPath != null
                            ? CharacterAvatarCircle(
                                imagePath: character.assets!.avatarPath!,
                                errorBuilder: (_, __, ___) => CircleAvatar(
                                  child: Text(character.name
                                      .substring(0, 1)
                                      .toUpperCase()),
                                ),
                              )
                            : CircleAvatar(
                                child: Text(character.name
                                    .substring(0, 1)
                                    .toUpperCase()),
                              ),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Text('${AppLocalizations.of(context).error}: $e'),
                ),
              ),
            ),
            if (_selectedCharacterIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  AppLocalizations.of(context)!
                      .charactersSelected(_selectedCharacterIds.length),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.accentColor,
                      ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context)!.cancel),
        ),
        ElevatedButton(
          onPressed: _isCreating ||
                  _nameController.text.trim().isEmpty ||
                  _selectedCharacterIds.length < 2
              ? null
              : _createGroup,
          child: _isCreating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppLocalizations.of(context)!.create),
        ),
      ],
    );
  }

  Future<void> _createGroup() async {
    if (_nameController.text.trim().isEmpty) return;
    if (_selectedCharacterIds.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(AppLocalizations.of(context)!.selectAtLeast2Characters)),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      await ref.read(groupListProvider.notifier).createGroup(
            name: _nameController.text.trim(),
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
            characterIds: _selectedCharacterIds.toList(),
          );

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(AppLocalizations.of(context)!.groupCreatedSuccessfully)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!
                  .failedToCreateGroup(e.toString()))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCreating = false);
      }
    }
  }
}

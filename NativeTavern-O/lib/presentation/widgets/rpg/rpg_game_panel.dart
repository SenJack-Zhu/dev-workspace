import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/domain/services/rpg_narrative_bridge.dart';
import 'package:native_tavern/domain/services/rpg_game_session_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/rpg_chat_providers.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';

class RpgGamePanel extends ConsumerWidget {
  const RpgGamePanel({
    super.key,
    required this.chatId,
    required this.onDisable,
  });

  final String chatId;
  final VoidCallback onDisable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final uiState = ref.watch(rpgChatProvider(chatId));
    final session = uiState.session;
    if (!uiState.enabled || session == null) return const SizedBox.shrink();

    final panelHeight = (MediaQuery.sizeOf(context).height * 0.34)
        .clamp(240.0, 340.0)
        .toDouble();
    return DefaultTabController(
      length: 6,
      child: Container(
        key: const Key('rpg-game-panel'),
        height: panelHeight,
        decoration: const BoxDecoration(
          color: AppTheme.darkCard,
          border: Border(top: BorderSide(color: AppTheme.darkDivider)),
        ),
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              SizedBox(
                height: 42,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    const Icon(Icons.sports_esports, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: Text(
                        session.scenario.metadata.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        '${l10n.rpgTurnNumber(session.state.turn)} · ${session.branchId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textMuted,
                            ),
                      ),
                    ),
                    IconButton(
                      key: const Key('rpg-disable'),
                      onPressed: onDisable,
                      icon: const Icon(Icons.close, size: 19),
                      tooltip: l10n.rpgDisableMode,
                    ),
                  ],
                ),
              ),
              if (uiState.lastResult case final result?)
                _ResultBanner(result: result),
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerHeight: 1,
                tabs: [
                  Tab(
                      key: const Key('rpg-tab-status'),
                      icon: const Icon(Icons.tune),
                      text: l10n.rpgStatus),
                  Tab(
                      key: const Key('rpg-tab-inventory'),
                      icon: const Icon(Icons.backpack_outlined),
                      text: l10n.rpgInventory),
                  Tab(
                      key: const Key('rpg-tab-quests'),
                      icon: const Icon(Icons.task_alt),
                      text: l10n.rpgQuests),
                  Tab(
                      key: const Key('rpg-tab-relations'),
                      icon: const Icon(Icons.people_outline),
                      text: l10n.rpgRelations),
                  Tab(
                      key: const Key('rpg-tab-actions'),
                      icon: const Icon(Icons.bolt),
                      text: l10n.rpgActions),
                  Tab(
                      key: const Key('rpg-tab-log'),
                      icon: const Icon(Icons.history),
                      text: l10n.rpgLog),
                ],
              ),
              Expanded(
                child: Stack(
                  children: [
                    TabBarView(
                      children: [
                        _StatusView(session: session),
                        _InventoryView(session: session),
                        _QuestView(session: session),
                        _RelationshipView(session: session),
                        _ActionView(chatId: chatId, session: session),
                        _LogView(
                          chatId: chatId,
                          session: session,
                          snapshots: uiState.snapshots,
                        ),
                      ],
                    ),
                    if (uiState.isLoading)
                      const Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({required this.result});

  final RpgNarrativeResult result;

  @override
  Widget build(BuildContext context) {
    final isError = result.status == RpgNarrativeStatus.rejected ||
        result.status == RpgNarrativeStatus.malformed;
    final isCancelled = result.status == RpgNarrativeStatus.cancelled;
    if (result.feedback.isEmpty) return const SizedBox.shrink();
    final color = isError
        ? Colors.red
        : isCancelled
            ? Colors.orange
            : Colors.green;
    return Container(
      key: const Key('rpg-result-banner'),
      width: double.infinity,
      color: color.withValues(alpha: 0.13),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          Icon(
            isError
                ? Icons.error_outline
                : isCancelled
                    ? Icons.cancel_outlined
                    : Icons.verified_outlined,
            size: 17,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              result.feedback,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.session});

  final RpgGameSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scenario = session.scenario;
    final state = session.state;
    final location = scenario.locations
        .where((candidate) => candidate.id == state.locationId)
        .firstOrNull;
    return ListView(
      key: const Key('rpg-status-view'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        _SectionLine(
          icon: Icons.place_outlined,
          label: l10n.rpgLocation,
          value: location?.label ??
              (state.locationId.isEmpty ? l10n.unknown : state.locationId),
        ),
        _SectionLine(
          icon: Icons.schedule,
          label: l10n.rpgTime,
          value: l10n.rpgDayTime(
            state.clock.day,
            _clockLabel(state.clock.minuteOfDay),
          ),
        ),
        const Divider(),
        ...scenario.attributes.map((definition) {
          final value =
              state.attributes[definition.id] ?? definition.initialValue;
          final bounds = definition.maximum == null
              ? '$value'
              : '$value / ${definition.maximum}';
          return _SectionLine(
            icon: Icons.monitor_heart_outlined,
            label: definition.label,
            value: bounds,
          );
        }),
        if (state.variables.isNotEmpty) ...[
          const Divider(),
          ...state.variables.entries.map(
            (entry) => _SectionLine(
              icon: Icons.data_object,
              label: entry.key,
              value: '${entry.value}',
            ),
          ),
        ],
      ],
    );
  }
}

class _InventoryView extends StatelessWidget {
  const _InventoryView({required this.session});

  final RpgGameSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (session.state.inventory.isEmpty) {
      return _EmptyView(
        icon: Icons.backpack_outlined,
        label: l10n.rpgInventoryEmpty,
      );
    }
    return ListView.separated(
      key: const Key('rpg-inventory-view'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: session.state.inventory.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = session.state.inventory[index];
        final definition = session.scenario.items
            .where((item) => item.id == entry.itemId)
            .firstOrNull;
        return ListTile(
          dense: true,
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(definition?.label ?? entry.itemId),
          subtitle: definition?.description.isEmpty ?? true
              ? null
              : Text(definition!.description,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text('x${entry.quantity}'),
        );
      },
    );
  }
}

class _QuestView extends StatelessWidget {
  const _QuestView({required this.session});

  final RpgGameSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (session.state.quests.isEmpty) {
      return _EmptyView(icon: Icons.task_alt, label: l10n.rpgNoQuests);
    }
    return ListView.separated(
      key: const Key('rpg-quest-view'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: session.state.quests.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final quest = session.state.quests[index];
        final definition = session.scenario.quests
            .where((item) => item.id == quest.questId)
            .firstOrNull;
        final stage = definition?.stages
            .where((item) => item.id == quest.stageId)
            .firstOrNull;
        return ListTile(
          dense: true,
          leading: Icon(_questIcon(quest.status)),
          title: Text(definition?.label ?? quest.questId),
          subtitle: Text(
            [
              _questStatusLabel(l10n, quest.status),
              if (stage != null) stage.label,
              if (quest.objectiveProgress.isNotEmpty)
                quest.objectiveProgress.entries
                    .map((entry) => '${entry.key}: ${entry.value}')
                    .join(', '),
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}

class _RelationshipView extends StatelessWidget {
  const _RelationshipView({required this.session});

  final RpgGameSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (session.state.relationships.isEmpty) {
      return _EmptyView(
        icon: Icons.people_outline,
        label: l10n.rpgNoRelationships,
      );
    }
    return ListView.separated(
      key: const Key('rpg-relationship-view'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: session.state.relationships.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final relationship = session.state.relationships[index];
        final actor = session.scenario.actors
            .where((candidate) => candidate.id == relationship.actorId)
            .firstOrNull;
        return ListTile(
          dense: true,
          leading: const Icon(Icons.person_outline),
          title: Text(actor?.label ?? relationship.actorId),
          subtitle: relationship.tags.isEmpty
              ? null
              : Text(relationship.tags.join(', ')),
          trailing: Text('${relationship.score}'),
        );
      },
    );
  }
}

class _ActionView extends ConsumerWidget {
  const _ActionView({required this.chatId, required this.session});

  final String chatId;
  final RpgGameSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    if (session.scenario.actions.isEmpty) {
      return _EmptyView(icon: Icons.bolt, label: l10n.rpgNoActions);
    }
    final controller = ref.read(rpgChatProvider(chatId).notifier);
    final availableIds =
        controller.availableActions.map((action) => action.id).toSet();
    return ListView.separated(
      key: const Key('rpg-action-view'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: session.scenario.actions.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final action = session.scenario.actions[index];
        final available = availableIds.contains(action.id);
        final cooldown = session.state.cooldowns[action.id] ?? 0;
        final details = <String>[
          if (action.description.isNotEmpty) action.description,
          if (action.costs.isNotEmpty)
            l10n.rpgCost(
              action.costs
                  .map((cost) => '${cost.path} ${cost.amount}')
                  .join(', '),
            ),
          if (action.check != null)
            l10n.rpgCheck(
              action.check!.dice.expression,
              action.check!.attributeId,
              action.check!.difficulty,
            ),
          if (!available)
            cooldown > 0
                ? l10n.rpgCooldown(cooldown)
                : l10n.rpgRequirementsNotMet,
        ];
        return ListTile(
          key: Key('rpg-action-${action.id}'),
          dense: true,
          enabled: available,
          leading: Icon(available ? Icons.play_arrow : Icons.lock_outline),
          title: Text(action.label),
          subtitle: details.isEmpty
              ? null
              : Text(details.join('\n'),
                  maxLines: 3, overflow: TextOverflow.ellipsis),
          onTap: available
              ? () async {
                  await controller.executeAction(action.id);
                  if (!context.mounted) return;
                  final result = ref.read(rpgChatProvider(chatId)).lastResult;
                  if (result != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(result.feedback)),
                    );
                  }
                }
              : null,
        );
      },
    );
  }
}

class _LogView extends ConsumerWidget {
  const _LogView({
    required this.chatId,
    required this.session,
    required this.snapshots,
  });

  final String chatId;
  final RpgGameSession session;
  final List<RpgStateSnapshot> snapshots;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final events = session.state.eventHistory.reversed.toList();
    return ListView(
      key: const Key('rpg-log-view'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (events.isEmpty)
          SizedBox(
            height: 72,
            child: _EmptyView(
              icon: Icons.history,
              label: l10n.rpgNoTurnsRecorded,
            ),
          ),
        ...events.map((event) => _eventTile(l10n, session, event)),
        const Divider(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(l10n.rpgSnapshots,
              style: Theme.of(context).textTheme.titleSmall),
        ),
        ...snapshots.reversed.map(
          (snapshot) => ListTile(
            dense: true,
            leading: Icon(
              snapshot.metadata.id == session.snapshot.metadata.id
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
            ),
            title: Text(
                '${l10n.rpgTurnNumber(snapshot.metadata.turn)} · ${snapshot.metadata.branchId}'),
            subtitle: Text(
              snapshot.metadata.createdAt.toLocal().toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: PopupMenuButton<String>(
              key: Key('rpg-snapshot-${snapshot.metadata.id}'),
              tooltip: l10n.rpgSnapshotActions,
              enabled: snapshot.metadata.id != session.snapshot.metadata.id,
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'restore', child: Text(l10n.rpgRestoreSnapshot)),
                PopupMenuItem(
                    value: 'fork', child: Text(l10n.rpgForkNewBranch)),
              ],
              onSelected: (value) async {
                final controller = ref.read(rpgChatProvider(chatId).notifier);
                try {
                  if (value == 'restore') {
                    await controller.rollback(snapshot.metadata.id);
                  } else {
                    final branchId = await _askForBranchId(context);
                    if (branchId == null || branchId.isEmpty) return;
                    await controller.forkBranch(
                      snapshotId: snapshot.metadata.id,
                      branchId: branchId,
                    );
                  }
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(error.toString())),
                    );
                  }
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}

Widget _eventTile(
  AppLocalizations l10n,
  RpgGameSession session,
  RpgEventRecord event,
) {
  final action = session.scenario.actions
      .where((candidate) => candidate.id == event.actionId)
      .firstOrNull;
  final roll = event.data['roll'];
  final details = <String>[
    l10n.rpgTurnNumber(event.turn),
    l10n.rpgRuleEngineSource,
  ];
  if (roll is Map<String, Object?>) {
    details.add(l10n.rpgRoll('${roll['total']}', '${roll['expression']}'));
  } else if (roll is Map) {
    details.add(l10n.rpgRoll('${roll['total']}', '${roll['expression']}'));
  }
  final effects = event.data['effects'];
  if (effects is List && effects.isNotEmpty) {
    final labels = effects.whereType<Map<Object?, Object?>>().map((effect) {
      final type = effect['type'] ?? 'effect';
      final target = effect['target'];
      return target == null ? '$type' : '$type:$target';
    });
    details.add(l10n.rpgChanges(labels.join(', ')));
  }
  return ListTile(
    dense: true,
    leading: const Icon(Icons.verified_user_outlined),
    title: Text(
        action?.label ?? (event.summary.isEmpty ? event.type : event.summary)),
    subtitle:
        Text(details.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
  );
}

class _SectionLine extends StatelessWidget {
  const _SectionLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.textMuted),
          const SizedBox(width: 8),
          Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppTheme.textMuted),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: AppTheme.textMuted)),
        ],
      ),
    );
  }
}

Future<String?> _askForBranchId(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  var branchId = '';
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.rpgForkBranch),
      content: TextField(
        key: const Key('rpg-branch-id'),
        autofocus: true,
        onChanged: (value) => branchId = value,
        decoration: InputDecoration(labelText: l10n.rpgBranchId),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, branchId.trim()),
          child: Text(l10n.rpgFork),
        ),
      ],
    ),
  );
}

IconData _questIcon(RpgQuestStatus status) => switch (status) {
      RpgQuestStatus.inactive => Icons.pause_circle_outline,
      RpgQuestStatus.active => Icons.play_circle_outline,
      RpgQuestStatus.completed => Icons.check_circle_outline,
      RpgQuestStatus.failed => Icons.cancel_outlined,
    };

String _questStatusLabel(AppLocalizations l10n, RpgQuestStatus status) =>
    switch (status) {
      RpgQuestStatus.inactive => l10n.rpgQuestInactive,
      RpgQuestStatus.active => l10n.rpgQuestActive,
      RpgQuestStatus.completed => l10n.rpgQuestCompleted,
      RpgQuestStatus.failed => l10n.rpgQuestFailed,
    };

String _clockLabel(int minuteOfDay) {
  final hours = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
  final minutes = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$hours:$minutes';
}

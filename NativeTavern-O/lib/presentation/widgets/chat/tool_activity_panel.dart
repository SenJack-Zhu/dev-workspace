import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/models/tool_generation.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/tool_calling_providers.dart';

class ToolActivityPanel extends ConsumerWidget {
  const ToolActivityPanel({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(toolRuntimeProvider);
    if (state.chatId != chatId ||
        (state.activities.isEmpty && state.pendingApproval == null)) {
      return const SizedBox.shrink();
    }

    final activities = state.activities.length <= 4
        ? state.activities
        : state.activities.sublist(state.activities.length - 4);
    return Material(
      key: const Key('tool-activity-panel'),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.build_outlined, size: 18),
                const SizedBox(width: 8),
                Text(
                  l10n.toolActivity,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            if (activities.isNotEmpty) const SizedBox(height: 6),
            for (final activity in activities) _ActivityRow(activity: activity),
            if (state.pendingApproval case final approval?) ...[
              const Divider(height: 20),
              _ApprovalPrompt(approval: approval),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.activity});

  final ToolCallProgress activity;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = _statusColor(activity.status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: activity.status == ToolCallProgressStatus.running
                ? Padding(
                    padding: const EdgeInsets.all(3),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : Icon(_statusIcon(activity.status), size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activity.toolName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  activity.message?.trim().isNotEmpty == true
                      ? '${_statusLabel(l10n, activity.status)}: ${activity.message}'
                      : _statusLabel(l10n, activity.status),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalPrompt extends ConsumerWidget {
  const _ApprovalPrompt({required this.approval});

  final PendingToolApproval approval;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final preview = approval.preview;
    final encoded = jsonEncode(preview.parameters);
    final parameters =
        encoded.length <= 500 ? encoded : '${encoded.substring(0, 500)}...';
    final controller = ref.read(toolRuntimeProvider.notifier);
    return Column(
      key: const Key('tool-approval-prompt'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.toolApprovalRequired,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '${preview.toolName}  ${preview.target}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          parameters,
          key: const Key('tool-approval-parameters'),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            FilledButton.icon(
              key: const Key('tool-allow-once'),
              onPressed: () => controller.resolveApproval(
                ToolApprovalAction.allowOnce,
              ),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: Text(l10n.toolAllowOnce),
            ),
            if (approval.kind == ToolApprovalKind.mcp)
              OutlinedButton.icon(
                key: const Key('tool-always-allow'),
                onPressed: () => controller.resolveApproval(
                  ToolApprovalAction.alwaysAllow,
                ),
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: Text(l10n.toolAlwaysAllow),
              ),
            TextButton.icon(
              key: const Key('tool-deny'),
              onPressed: () => controller.resolveApproval(
                ToolApprovalAction.deny,
              ),
              icon: const Icon(Icons.block, size: 18),
              label: Text(l10n.toolDeny),
            ),
            IconButton(
              key: const Key('tool-cancel'),
              onPressed: () => controller.resolveApproval(
                ToolApprovalAction.cancel,
              ),
              icon: const Icon(Icons.close),
              tooltip: l10n.toolCancelCall,
            ),
          ],
        ),
      ],
    );
  }
}

String _statusLabel(
  AppLocalizations l10n,
  ToolCallProgressStatus status,
) =>
    switch (status) {
      ToolCallProgressStatus.waitingApproval => l10n.toolStatusWaitingApproval,
      ToolCallProgressStatus.running => l10n.toolStatusRunning,
      ToolCallProgressStatus.succeeded => l10n.toolStatusSucceeded,
      ToolCallProgressStatus.failed => l10n.toolStatusFailed,
      ToolCallProgressStatus.denied => l10n.toolStatusDenied,
      ToolCallProgressStatus.cancelled => l10n.toolStatusCancelled,
    };

IconData _statusIcon(ToolCallProgressStatus status) => switch (status) {
      ToolCallProgressStatus.waitingApproval => Icons.approval_outlined,
      ToolCallProgressStatus.running => Icons.hourglass_top,
      ToolCallProgressStatus.succeeded => Icons.check_circle_outline,
      ToolCallProgressStatus.failed => Icons.error_outline,
      ToolCallProgressStatus.denied => Icons.block,
      ToolCallProgressStatus.cancelled => Icons.cancel_outlined,
    };

Color _statusColor(ToolCallProgressStatus status) => switch (status) {
      ToolCallProgressStatus.waitingApproval => Colors.amber.shade700,
      ToolCallProgressStatus.running => Colors.blue.shade400,
      ToolCallProgressStatus.succeeded => Colors.green.shade500,
      ToolCallProgressStatus.failed => Colors.red.shade400,
      ToolCallProgressStatus.denied => Colors.orange.shade500,
      ToolCallProgressStatus.cancelled => Colors.grey.shade500,
    };

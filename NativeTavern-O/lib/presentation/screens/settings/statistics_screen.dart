import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/chat_statistics.dart';
import '../../providers/statistics_providers.dart';
import '../../theme/app_theme.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';

/// Screen for viewing app and chat statistics
class StatisticsScreen extends ConsumerWidget {
  final String? chatId;

  const StatisticsScreen({super.key, this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(chatId != null ? l10n.chatStatistics : l10n.appStatistics),
        actions: [
          if (chatId == null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.resetStatistics,
              onPressed: () => _showResetConfirmation(context, ref),
            ),
        ],
      ),
      body: chatId != null
          ? _ChatStatisticsView(chatId: chatId!)
          : const _AppStatisticsView(),
    );
  }

  void _showResetConfirmation(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.resetStatistics),
        content: Text(l10n.resetStatisticsConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              ref.read(appStatisticsProvider.notifier).reset();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.statisticsReset)),
              );
            },
            child: Text(l10n.reset),
          ),
        ],
      ),
    );
  }
}

class _AppStatisticsView extends ConsumerWidget {
  const _AppStatisticsView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(appStatisticsProvider);
    final summary = ref.watch(statisticsSummaryProvider);
    final l10n = AppLocalizations.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Overview card
        _StatisticsCard(
          title: l10n.overview,
          icon: Icons.dashboard,
          children: [
            _StatRow(
              label: l10n.firstUsed,
              value: stats.appFirstUsed != null
                  ? _formatDate(stats.appFirstUsed!)
                  : l10n.unknown,
            ),
            _StatRow(
              label: l10n.totalCharacters,
              value: summary.characterCount.toString(),
            ),
            _StatRow(
              label: l10n.totalChats,
              value: stats.totalChats.toString(),
            ),
            _StatRow(
              label: l10n.totalGroups,
              value: stats.totalGroups.toString(),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Messages card
        _StatisticsCard(
          title: l10n.messages,
          icon: Icons.message,
          children: [
            _StatRow(
              label: l10n.totalMessages,
              value: _formatNumber(stats.totalMessages),
            ),
            _StatRow(
              label: l10n.totalGenerations,
              value: _formatNumber(stats.totalGenerations),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Tokens card
        _StatisticsCard(
          title: l10n.tokenUsage,
          icon: Icons.token,
          children: [
            _StatRow(
              label: l10n.totalTokensUsed,
              value: _formatNumber(stats.totalTokensUsed),
            ),
            _StatRow(
              label: l10n.avgTokensPerGeneration,
              value: stats.averageTokensPerGeneration.toStringAsFixed(1),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Performance card
        _StatisticsCard(
          title: l10n.performance,
          icon: Icons.speed,
          children: [
            _StatRow(
              label: l10n.totalGenerationTime,
              value: _formatDuration(stats.totalGenerationTime),
            ),
            _StatRow(
              label: l10n.avgGenerationTime,
              value: _formatDuration(stats.averageGenerationTime),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChatStatisticsView extends ConsumerWidget {
  final String chatId;

  const _ChatStatisticsView({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(computedChatStatisticsProvider(chatId));

    return statsAsync.when(
      data: (stats) => _buildStatsList(context, stats),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('${AppLocalizations.of(context).error}: $e'),
      ),
    );
  }

  Widget _buildStatsList(BuildContext context, ChatStatistics stats) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Messages card
        _StatisticsCard(
          title: l10n.messages,
          icon: Icons.message,
          children: [
            _StatRow(
              label: l10n.totalMessages,
              value: stats.totalMessages.toString(),
            ),
            _StatRow(
              label: l10n.userMessages,
              value: stats.userMessages.toString(),
            ),
            _StatRow(
              label: l10n.assistantMessages,
              value: stats.assistantMessages.toString(),
            ),
            _StatRow(
              label: l10n.systemMessages,
              value: stats.systemMessages.toString(),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Timeline card
        _StatisticsCard(
          title: l10n.timeline,
          icon: Icons.timeline,
          children: [
            _StatRow(
              label: l10n.firstMessage,
              value: stats.firstMessageAt != null
                  ? _formatDateTime(stats.firstMessageAt!)
                  : l10n.unknown,
            ),
            _StatRow(
              label: l10n.lastMessage,
              value: stats.lastMessageAt != null
                  ? _formatDateTime(stats.lastMessageAt!)
                  : l10n.unknown,
            ),
            _StatRow(
              label: l10n.chatDuration,
              value: _formatDuration(stats.chatDuration),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Tokens card
        _StatisticsCard(
          title: l10n.tokenUsage,
          icon: Icons.token,
          children: [
            _StatRow(
              label: l10n.totalTokens,
              value: _formatNumber(stats.totalTokensUsed),
            ),
            _StatRow(
              label: l10n.promptTokens,
              value: _formatNumber(stats.promptTokens),
            ),
            _StatRow(
              label: l10n.completionTokens,
              value: _formatNumber(stats.completionTokens),
            ),
            _StatRow(
              label: l10n.avgTokensPerMessage,
              value: stats.averageTokensPerMessage.toStringAsFixed(1),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Performance card
        _StatisticsCard(
          title: l10n.generationPerformance,
          icon: Icons.speed,
          children: [
            _StatRow(
              label: l10n.totalGenerations,
              value: stats.generationCount.toString(),
            ),
            _StatRow(
              label: l10n.totalGenerationTime,
              value: _formatDuration(stats.totalGenerationTime),
            ),
            _StatRow(
              label: l10n.avgGenerationTime,
              value: _formatDuration(stats.averageGenerationTime),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatisticsCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _StatisticsCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppTheme.accentColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const Divider(height: 24),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textMuted,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }
}

String _formatNumber(int number) {
  if (number >= 1000000) {
    return '${(number / 1000000).toStringAsFixed(1)}M';
  } else if (number >= 1000) {
    return '${(number / 1000).toStringAsFixed(1)}K';
  }
  return number.toString();
}

String _formatDuration(Duration duration) {
  if (duration.inDays > 0) {
    return '${duration.inDays}d ${duration.inHours % 24}h';
  } else if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes % 60}m';
  } else if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
  } else if (duration.inSeconds > 0) {
    return '${duration.inSeconds}.${(duration.inMilliseconds % 1000) ~/ 100}s';
  } else if (duration.inMilliseconds > 0) {
    return '${duration.inMilliseconds}ms';
  }
  return '0s';
}

String _formatDate(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String _formatDateTime(DateTime date) {
  return '${_formatDate(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

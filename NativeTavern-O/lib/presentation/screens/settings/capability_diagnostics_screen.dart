import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/domain/services/capability_registry.dart';
import 'package:native_tavern/domain/services/external_call_audit_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/capability_providers.dart';
import 'package:native_tavern/presentation/providers/external_call_audit_providers.dart';
import 'package:native_tavern/presentation/providers/stt_providers.dart';

class CapabilityDiagnosticsScreen extends ConsumerWidget {
  const CapabilityDiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final diagnostics = ref.watch(capabilityDiagnosticsProvider);
    final externalCalls = ref.watch(recentExternalCallsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.capabilityCheck),
        actions: [
          IconButton(
            tooltip: l10n.refresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => _refresh(ref),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(ref),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            diagnostics.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => ListTile(
                leading: const Icon(Icons.error_outline, color: Colors.red),
                title: Text(l10n.capabilityCheckFailed),
                trailing: IconButton(
                  tooltip: l10n.retry,
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _refresh(ref),
                ),
              ),
              data: (report) => _CapabilityReport(
                report: report,
                onAction: (result) => _runAction(context, ref, result),
              ),
            ),
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.capabilityRecentExternalActivity,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            externalCalls.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
              error: (_, __) => ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(l10n.capabilityAuditUnavailable),
              ),
              data: (records) => records.isEmpty
                  ? ListTile(
                      leading: const Icon(Icons.history),
                      title: Text(l10n.capabilityNoExternalCalls),
                    )
                  : Column(
                      children: [
                        for (final record in records)
                          _ExternalCallTile(record: record),
                      ],
                    ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(capabilityRuntimeSignalsProvider);
    ref.invalidate(recentExternalCallsProvider);
  }

  Future<void> _runAction(
    BuildContext context,
    WidgetRef ref,
    CapabilityDiagnosticResult result,
  ) async {
    switch (result.fixKind) {
      case CapabilityFixKind.openSettings:
        final route = result.capability.settingsRoute;
        if (route != null) await context.push(route);
      case CapabilityFixKind.requestPermission:
        await ref.read(sttServiceProvider).initialize();
      case CapabilityFixKind.retry:
        break;
      case null:
        return;
    }
    ref.invalidate(capabilityRuntimeSignalsProvider);
  }
}

class _CapabilityReport extends StatelessWidget {
  final CapabilityDiagnosticReport report;
  final ValueChanged<CapabilityDiagnosticResult> onAction;

  const _CapabilityReport({required this.report, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final total = report.results.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.capabilityReadyCount(report.readyCount, total),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Icon(
                report.attentionCount == 0
                    ? Icons.check_circle
                    : Icons.info_outline,
                color: report.attentionCount == 0
                    ? Colors.green
                    : Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LinearProgressIndicator(
            value: total == 0 ? 0 : report.readyCount / total,
          ),
        ),
        const SizedBox(height: 8),
        for (final result in report.results) ...[
          _CapabilityTile(result: result, onAction: onAction),
          const Divider(height: 1, indent: 72),
        ],
      ],
    );
  }
}

class _CapabilityTile extends StatelessWidget {
  final CapabilityDiagnosticResult result;
  final ValueChanged<CapabilityDiagnosticResult> onAction;

  const _CapabilityTile({required this.result, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = _statusColor(context, result.availability);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: SizedBox.square(
        dimension: 40,
        child: Icon(_capabilityIcon(result.capability.id)),
      ),
      title: Text(_capabilityName(l10n, result.capability.id)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_capabilityDescription(l10n, result.capability.id)),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(_statusIcon(result.availability), size: 16, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _capabilityMessage(l10n, result),
                  style: TextStyle(color: color),
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: switch (result.fixKind) {
        CapabilityFixKind.openSettings => IconButton(
            tooltip: l10n.capabilityOpenSettings,
            icon: const Icon(Icons.chevron_right),
            onPressed: () => onAction(result),
          ),
        CapabilityFixKind.requestPermission => IconButton(
            tooltip: l10n.capabilityRequestPermission,
            icon: const Icon(Icons.security),
            onPressed: () => onAction(result),
          ),
        CapabilityFixKind.retry => IconButton(
            tooltip: l10n.retry,
            icon: const Icon(Icons.refresh),
            onPressed: () => onAction(result),
          ),
        null => null,
      },
    );
  }

  IconData _capabilityIcon(CapabilityId id) => switch (id) {
        CapabilityId.llm => Icons.auto_awesome,
        CapabilityId.systemTts => Icons.volume_up,
        CapabilityId.systemStt => Icons.mic,
        CapabilityId.embedding => Icons.manage_search,
        CapabilityId.imageGeneration => Icons.image,
        CapabilityId.mcp => Icons.extension,
        CapabilityId.live2d => Icons.emoji_emotions,
      };

  IconData _statusIcon(CapabilityAvailability availability) {
    return switch (availability) {
      CapabilityAvailability.ready => Icons.check_circle,
      CapabilityAvailability.disabled => Icons.pause_circle_outline,
      CapabilityAvailability.offline => Icons.cloud_off,
      CapabilityAvailability.permissionDenied => Icons.block,
      CapabilityAvailability.unsupported => Icons.not_interested,
      CapabilityAvailability.needsPermission => Icons.security,
      CapabilityAvailability.needsDownload => Icons.download,
      CapabilityAvailability.needsConfiguration => Icons.settings_outlined,
    };
  }

  Color _statusColor(
    BuildContext context,
    CapabilityAvailability availability,
  ) {
    return switch (availability) {
      CapabilityAvailability.ready => Colors.green,
      CapabilityAvailability.disabled ||
      CapabilityAvailability.unsupported =>
        Theme.of(context).colorScheme.onSurfaceVariant,
      _ => Theme.of(context).colorScheme.error,
    };
  }
}

class _ExternalCallTile extends StatelessWidget {
  final ExternalCallAuditRecord record;

  const _ExternalCallTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final succeeded = record.outcome == ExternalCallOutcome.succeeded;
    final types = record.dataTypes
        .map((type) => _externalDataTypeLabel(l10n, type))
        .join(', ');
    final localTime = record.timestamp.toLocal();
    final time = '${localTime.hour.toString().padLeft(2, '0')}:'
        '${localTime.minute.toString().padLeft(2, '0')}';
    return ListTile(
      dense: true,
      leading: Icon(
        succeeded ? Icons.check_circle_outline : Icons.error_outline,
        color: succeeded ? Colors.green : Theme.of(context).colorScheme.error,
      ),
      title: Text(record.targetDomain),
      subtitle: Text('${record.capabilityId} · $types'),
      trailing: Text(time),
    );
  }
}

String _capabilityName(AppLocalizations l10n, CapabilityId id) => switch (id) {
      CapabilityId.llm => l10n.capabilityCurrentAi,
      CapabilityId.systemTts => l10n.capabilitySystemSpeech,
      CapabilityId.systemStt => l10n.capabilityVoiceInput,
      CapabilityId.embedding => l10n.capabilitySemanticSearch,
      CapabilityId.imageGeneration => l10n.imageGeneration,
      CapabilityId.mcp => l10n.capabilityMcpTools,
      CapabilityId.live2d => 'Live2D',
    };

String _capabilityDescription(AppLocalizations l10n, CapabilityId id) =>
    switch (id) {
      CapabilityId.llm => l10n.capabilityChatGenerationConnection,
      CapabilityId.systemTts => l10n.capabilityDeviceTts,
      CapabilityId.systemStt => l10n.capabilityDeviceSpeechRecognition,
      CapabilityId.embedding => l10n.capabilityOptionalEmbeddingConnection,
      CapabilityId.imageGeneration => l10n.capabilityOptionalImageConnection,
      CapabilityId.mcp => l10n.capabilityExternalToolServers,
      CapabilityId.live2d => l10n.capabilityBundledCharacterRendering,
    };

String _capabilityMessage(
  AppLocalizations l10n,
  CapabilityDiagnosticResult result,
) {
  if (result.availability == CapabilityAvailability.needsConfiguration) {
    return switch (result.capability.id) {
      CapabilityId.llm => l10n.capabilityCompleteAiConnection,
      CapabilityId.embedding => l10n.capabilityCompleteEmbeddingConnection,
      CapabilityId.imageGeneration => l10n.capabilityCompleteImageConnection,
      _ => l10n.capabilityConfigurationRequired,
    };
  }
  return switch (result.availability) {
    CapabilityAvailability.ready => result.message == 'Configured'
        ? l10n.capabilityConfigured
        : l10n.capabilityAvailable,
    CapabilityAvailability.disabled => l10n.off,
    CapabilityAvailability.needsPermission => l10n.capabilityPermissionRequired,
    CapabilityAvailability.permissionDenied => l10n.capabilityPermissionDenied,
    CapabilityAvailability.needsDownload => l10n.capabilityDownloadRequired,
    CapabilityAvailability.offline => l10n.capabilityUnavailableOffline,
    CapabilityAvailability.unsupported => l10n.capabilityUnavailableBuild,
    CapabilityAvailability.needsConfiguration =>
      l10n.capabilityConfigurationRequired,
  };
}

String _externalDataTypeLabel(
  AppLocalizations l10n,
  ExternalDataType type,
) =>
    switch (type) {
      ExternalDataType.chatText => l10n.capabilityDataChatText,
      ExternalDataType.prompt => l10n.capabilityDataPrompt,
      ExternalDataType.documentText => l10n.capabilityDataDocumentText,
      ExternalDataType.audio => l10n.capabilityDataAudio,
      ExternalDataType.image => l10n.capabilityDataImage,
      ExternalDataType.characterCard => l10n.capabilityDataCharacterCard,
      ExternalDataType.toolArguments => l10n.capabilityDataToolArguments,
      ExternalDataType.metadata => l10n.capabilityDataMetadata,
    };

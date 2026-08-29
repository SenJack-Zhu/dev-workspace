import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';

enum AiPlayFeature { moments, story }

Future<bool> ensureAiPlayFeatureEnabled(
  BuildContext context,
  WidgetRef ref,
  AiPlayFeature feature,
) async {
  final settings = ref.read(appSettingsProvider);
  final enabled = switch (feature) {
    AiPlayFeature.moments => settings.momentsEnabled,
    AiPlayFeature.story => settings.storyEnabled,
  };
  if (enabled) return true;

  final l10n = AppLocalizations.of(context);
  final featureName = switch (feature) {
    AiPlayFeature.moments => l10n.moments,
    AiPlayFeature.story => l10n.story,
  };
  final shouldEnable = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          key: Key('enable-${feature.name}-dialog'),
          icon: const Icon(Icons.auto_awesome_outlined),
          title: Text(l10n.playAiFeatureEnableTitle(featureName)),
          content: Text(l10n.playAiFeatureEnableDescription(featureName)),
          actions: [
            TextButton(
              key: const Key('enable-play-feature-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              key: const Key('enable-play-feature-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.playAiFeatureEnableAction),
            ),
          ],
        ),
      ) ??
      false;
  if (!shouldEnable) return false;

  final notifier = ref.read(appSettingsProvider.notifier);
  switch (feature) {
    case AiPlayFeature.moments:
      notifier.updateMomentsEnabled(true);
    case AiPlayFeature.story:
      notifier.updateStoryEnabled(true);
  }
  return true;
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/services/ai_data_sharing_consent_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/ai_data_sharing_consent_providers.dart';
import 'package:url_launcher/url_launcher.dart';

const _privacyPolicyUrl = 'https://docs.nativetavern.com/legal/privacy.html';

class AiDataSharingConsentGate extends ConsumerWidget {
  final Widget child;

  const AiDataSharingConsentGate({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(aiDataSharingConsentProvider);
    if (choice != AiDataSharingChoice.undecided) return child;
    return const AiDataSharingConsentScreen();
  }
}

class AiDataSharingConsentScreen extends ConsumerWidget {
  const AiDataSharingConsentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      key: const Key('ai-data-sharing-consent-screen'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              children: [
                Icon(
                  Icons.privacy_tip_outlined,
                  size: 52,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.aiDataSharingTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.aiDataSharingIntroduction,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 28),
                _DisclosureSection(
                  icon: Icons.upload_outlined,
                  title: l10n.aiDataSharingDataTitle,
                  body: l10n.aiDataSharingDataTypes,
                ),
                const SizedBox(height: 24),
                _DisclosureSection(
                  icon: Icons.hub_outlined,
                  title: l10n.aiDataSharingRecipientsTitle,
                  body: l10n.aiDataSharingRecipients,
                ),
                const SizedBox(height: 24),
                _DisclosureSection(
                  icon: Icons.shield_outlined,
                  title: l10n.aiDataSharingControlTitle,
                  body: l10n.aiDataSharingControlDescription,
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(_privacyPolicyUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(l10n.privacyPolicy),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: _ConsentActions(
          onAllow: () =>
              ref.read(aiDataSharingConsentProvider.notifier).allowRemoteAi(),
          onLocalOnly: () =>
              ref.read(aiDataSharingConsentProvider.notifier).useLocalOnly(),
        ),
      ),
    );
  }
}

class _ConsentActions extends StatelessWidget {
  final VoidCallback onAllow;
  final VoidCallback onLocalOnly;

  const _ConsentActions({
    required this.onAllow,
    required this.onLocalOnly,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Material(
      elevation: 8,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final allowButton = FilledButton.icon(
                  key: const Key('allow-remote-ai-button'),
                  onPressed: onAllow,
                  icon: const Icon(Icons.check),
                  label: Text(l10n.allowRemoteAi),
                );
                final localButton = OutlinedButton.icon(
                  key: const Key('use-local-ai-only-button'),
                  onPressed: onLocalOnly,
                  icon: const Icon(Icons.devices_outlined),
                  label: Text(l10n.useLocalAiOnly),
                );

                if (constraints.maxWidth < 520) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: 48, child: allowButton),
                      const SizedBox(height: 10),
                      SizedBox(height: 48, child: localButton),
                    ],
                  );
                }
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(child: SizedBox(height: 48, child: localButton)),
                    const SizedBox(width: 12),
                    Expanded(child: SizedBox(height: 48, child: allowButton)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _DisclosureSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _DisclosureSection({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 6),
              Text(body, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}

class AiDataSharingSettingsTile extends ConsumerWidget {
  const AiDataSharingSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final choice = ref.watch(aiDataSharingConsentProvider);
    final allowed = choice == AiDataSharingChoice.allowed;

    return SwitchListTile(
      key: const Key('ai-data-sharing-settings-tile'),
      secondary: const Icon(Icons.privacy_tip_outlined),
      title: Text(l10n.aiDataSharingSettingsTitle),
      subtitle: Text(
        allowed
            ? l10n.aiDataSharingAllowedDescription
            : l10n.aiDataSharingLocalOnlyDescription,
      ),
      value: allowed,
      onChanged: (value) {
        final notifier = ref.read(aiDataSharingConsentProvider.notifier);
        if (value) {
          notifier.allowRemoteAi();
        } else {
          notifier.useLocalOnly();
        }
      },
    );
  }
}

class PrivacyPolicyTile extends StatelessWidget {
  const PrivacyPolicyTile({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.policy_outlined),
      title: Text(l10n.privacyPolicy),
      trailing: const Icon(Icons.open_in_new),
      onTap: () => launchUrl(
        Uri.parse(_privacyPolicyUrl),
        mode: LaunchMode.externalApplication,
      ),
    );
  }
}

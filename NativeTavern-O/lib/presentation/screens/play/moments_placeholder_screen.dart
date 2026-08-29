import 'package:flutter/material.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';

/// Placeholder for `/play/moments` until #67 lands the moments timeline.
class MomentsPlaceholderScreen extends StatelessWidget {
  const MomentsPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.moments)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.playFeatureComingSoon,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

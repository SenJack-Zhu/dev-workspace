import 'package:shared_preferences/shared_preferences.dart';

enum AiDataSharingChoice { undecided, allowed, localOnly }

class AiDataSharingConsent {
  static const currentDisclosureVersion = 1;

  final AiDataSharingChoice choice;
  final int disclosureVersion;

  const AiDataSharingConsent({
    required this.choice,
    required this.disclosureVersion,
  });

  bool get allowsRemoteAi =>
      choice == AiDataSharingChoice.allowed &&
      disclosureVersion == currentDisclosureVersion;
}

abstract interface class AiDataSharingConsentRepository {
  AiDataSharingConsent get current;

  Future<void> setChoice(AiDataSharingChoice choice);
}

class AllowAllAiDataSharingConsentRepository
    implements AiDataSharingConsentRepository {
  const AllowAllAiDataSharingConsentRepository();

  @override
  AiDataSharingConsent get current => const AiDataSharingConsent(
        choice: AiDataSharingChoice.allowed,
        disclosureVersion: AiDataSharingConsent.currentDisclosureVersion,
      );

  @override
  Future<void> setChoice(AiDataSharingChoice choice) async {}
}

class MemoryAiDataSharingConsentRepository
    implements AiDataSharingConsentRepository {
  MemoryAiDataSharingConsentRepository({
    AiDataSharingChoice choice = AiDataSharingChoice.undecided,
    int disclosureVersion = AiDataSharingConsent.currentDisclosureVersion,
  }) : _current = AiDataSharingConsent(
          choice: choice,
          disclosureVersion: disclosureVersion,
        );

  AiDataSharingConsent _current;

  @override
  AiDataSharingConsent get current => _current;

  @override
  Future<void> setChoice(AiDataSharingChoice choice) async {
    _current = AiDataSharingConsent(
      choice: choice,
      disclosureVersion: AiDataSharingConsent.currentDisclosureVersion,
    );
  }
}

class SharedPreferencesAiDataSharingConsentRepository
    implements AiDataSharingConsentRepository {
  static const _choiceKey = 'ai_data_sharing_choice';
  static const _versionKey = 'ai_data_sharing_disclosure_version';

  final SharedPreferences preferences;

  const SharedPreferencesAiDataSharingConsentRepository(this.preferences);

  @override
  AiDataSharingConsent get current {
    final version = preferences.getInt(_versionKey) ?? 0;
    final storedChoice = preferences.getString(_choiceKey);
    final choice = AiDataSharingChoice.values
        .where(
          (candidate) => candidate.name == storedChoice,
        )
        .firstOrNull;

    if (version != AiDataSharingConsent.currentDisclosureVersion) {
      return AiDataSharingConsent(
        choice: AiDataSharingChoice.undecided,
        disclosureVersion: version,
      );
    }

    return AiDataSharingConsent(
      choice: choice ?? AiDataSharingChoice.undecided,
      disclosureVersion: version,
    );
  }

  @override
  Future<void> setChoice(AiDataSharingChoice choice) async {
    if (choice == AiDataSharingChoice.undecided) {
      await preferences.remove(_choiceKey);
      await preferences.remove(_versionKey);
      return;
    }

    await preferences.setString(_choiceKey, choice.name);
    await preferences.setInt(
      _versionKey,
      AiDataSharingConsent.currentDisclosureVersion,
    );
  }
}

class AiDataSharingConsentRequiredException implements Exception {
  const AiDataSharingConsentRequiredException();

  @override
  String toString() =>
      'Remote AI data sharing is disabled. Enable it in Settings > Privacy.';
}

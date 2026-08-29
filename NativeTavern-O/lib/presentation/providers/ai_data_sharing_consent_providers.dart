import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/services/ai_data_sharing_consent_service.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';

final aiDataSharingConsentRepositoryProvider =
    Provider<AiDataSharingConsentRepository>((ref) {
  return SharedPreferencesAiDataSharingConsentRepository(
    ref.watch(sharedPreferencesProvider),
  );
});

final aiDataSharingConsentProvider =
    StateNotifierProvider<AiDataSharingConsentNotifier, AiDataSharingChoice>(
        (ref) {
  return AiDataSharingConsentNotifier(
    ref.watch(aiDataSharingConsentRepositoryProvider),
  );
});

class AiDataSharingConsentNotifier extends StateNotifier<AiDataSharingChoice> {
  final AiDataSharingConsentRepository _repository;

  AiDataSharingConsentNotifier(this._repository)
      : super(_repository.current.choice);

  Future<void> allowRemoteAi() => _setChoice(AiDataSharingChoice.allowed);

  Future<void> useLocalOnly() => _setChoice(AiDataSharingChoice.localOnly);

  Future<void> _setChoice(AiDataSharingChoice choice) async {
    await _repository.setChoice(choice);
    state = choice;
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/ai_data_sharing_consent_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('starts undecided and persists the current disclosure choice', () async {
    final preferences = await SharedPreferences.getInstance();
    final repository =
        SharedPreferencesAiDataSharingConsentRepository(preferences);

    expect(repository.current.choice, AiDataSharingChoice.undecided);
    expect(repository.current.allowsRemoteAi, isFalse);

    await repository.setChoice(AiDataSharingChoice.allowed);

    final reloaded =
        SharedPreferencesAiDataSharingConsentRepository(preferences);
    expect(reloaded.current.choice, AiDataSharingChoice.allowed);
    expect(reloaded.current.allowsRemoteAi, isTrue);
  });

  test('requires a new choice after the disclosure version changes', () async {
    SharedPreferences.setMockInitialValues({
      'ai_data_sharing_choice': 'allowed',
      'ai_data_sharing_disclosure_version':
          AiDataSharingConsent.currentDisclosureVersion - 1,
    });
    final preferences = await SharedPreferences.getInstance();
    final repository =
        SharedPreferencesAiDataSharingConsentRepository(preferences);

    expect(repository.current.choice, AiDataSharingChoice.undecided);
    expect(repository.current.allowsRemoteAi, isFalse);
  });
}

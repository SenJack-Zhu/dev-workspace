import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/services/stt_service.dart';
import 'package:native_tavern/presentation/providers/ai_data_sharing_consent_providers.dart';
import 'package:native_tavern/presentation/providers/external_call_audit_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

final sttServiceProvider = Provider<STTService>((ref) {
  final service = STTService(
    auditRepository: ref.watch(externalCallAuditRepositoryProvider),
    consentRepository: ref.watch(aiDataSharingConsentRepositoryProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final sttSettingsProvider =
    StateNotifierProvider<STTSettingsNotifier, STTSettings>((ref) {
  return STTSettingsNotifier(ref.watch(sttServiceProvider));
});

class STTSettingsNotifier extends StateNotifier<STTSettings> {
  STTSettingsNotifier(this._service) : super(const STTSettings()) {
    unawaited(_loadSettings());
  }

  static const _prefsKey = 'stt_settings';
  final STTService _service;

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_prefsKey);
      if (jsonString == null) return;
      state = STTSettings.fromJson(
        jsonDecode(jsonString) as Map<String, dynamic>,
      );
      _service.updateSettings(state);
    } catch (_) {
      // Corrupt or unavailable preferences fall back to local defaults.
    }
  }

  Future<void> _saveSettings() async {
    _service.updateSettings(state);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(state.toJson()));
    } catch (_) {
      // The active in-memory configuration remains usable.
    }
  }

  void setEnabled(bool enabled) {
    state = state.copyWith(enabled: enabled);
    unawaited(_saveSettings());
  }

  void setProvider(STTProvider provider) {
    state = state.copyWith(provider: provider);
    unawaited(_saveSettings());
  }

  void setLanguage(String language) {
    state = state.copyWith(language: language);
    unawaited(_saveSettings());
  }

  void setContinuousListening(bool continuous) {
    state = state.copyWith(continuousListening: continuous);
    unawaited(_saveSettings());
  }

  void setAutoSend(bool autoSend) {
    state = state.copyWith(autoSend: autoSend);
    unawaited(_saveSettings());
  }

  void setShowPartialResults(bool show) {
    state = state.copyWith(showPartialResults: show);
    unawaited(_saveSettings());
  }

  void setApiKey(String? apiKey) {
    state = state.copyWith(apiKey: apiKey?.trim() ?? '');
    unawaited(_saveSettings());
  }

  void setApiEndpoint(String? endpoint) {
    state = state.copyWith(apiEndpoint: endpoint?.trim() ?? '');
    unawaited(_saveSettings());
  }

  void setModel(String? model) {
    state = state.copyWith(model: model?.trim() ?? '');
    unawaited(_saveSettings());
  }

  void reset() {
    state = const STTSettings();
    unawaited(_saveSettings());
  }
}

final sttSessionProvider =
    StateNotifierProvider<STTSessionNotifier, STTSessionState>((ref) {
  return STTSessionNotifier(ref.watch(sttServiceProvider));
});

class STTSessionNotifier extends StateNotifier<STTSessionState> {
  STTSessionNotifier(this._service) : super(_service.state) {
    _subscription = _service.states.listen((next) => state = next);
  }

  final STTService _service;
  late final StreamSubscription<STTSessionState> _subscription;

  Future<void> start() => _service.startListening();
  Future<void> stop() => _service.stopListening();
  Future<void> toggle() => _service.toggleListening();
  Future<void> cancel() => _service.cancelListening();
  Future<bool> openPermissionSettings() => _service.openPermissionSettings();
  void clear() => _service.clearResult();

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

final sttListeningProvider = Provider<bool>(
  (ref) => ref.watch(sttSessionProvider).phase == STTSessionPhase.listening,
);

final sttResultProvider = Provider<STTResult?>(
  (ref) => ref.watch(sttSessionProvider).result,
);

final sttAvailableProvider = FutureProvider<bool>((ref) async {
  ref.watch(sttSettingsProvider);
  return ref.watch(sttServiceProvider).isAvailable();
});

final sttStartListeningProvider = Provider<Future<void> Function()>((ref) {
  return ref.read(sttSessionProvider.notifier).start;
});

final sttStopListeningProvider = Provider<Future<void> Function()>((ref) {
  return ref.read(sttSessionProvider.notifier).stop;
});

final sttToggleListeningProvider = Provider<Future<void> Function()>((ref) {
  return ref.read(sttSessionProvider.notifier).toggle;
});

final sttCancelListeningProvider = Provider<Future<void> Function()>((ref) {
  return ref.read(sttSessionProvider.notifier).cancel;
});

final sttClearResultProvider = Provider<void Function()>((ref) {
  return ref.read(sttSessionProvider.notifier).clear;
});

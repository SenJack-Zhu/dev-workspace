import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/data/repositories/drift_rpg_persistence_repository.dart';
import 'package:native_tavern/domain/repositories/rpg_persistence_repository.dart';
import 'package:native_tavern/domain/services/rpg_game_session_service.dart';
import 'package:native_tavern/domain/services/rpg_narrative_bridge.dart';
import 'package:native_tavern/domain/services/rpg_rule_engine.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

final rpgPersistenceRepositoryProvider = Provider<RpgPersistenceRepository>(
  (ref) => DriftRpgPersistenceRepository(ref.watch(databaseProvider)),
);

final rpgGameSessionServiceProvider = Provider<RpgGameSessionService>(
  (ref) => RpgGameSessionService(
    repository: ref.watch(rpgPersistenceRepositoryProvider),
  ),
);

class RpgChatUiState {
  const RpgChatUiState({
    this.isLoading = false,
    this.enabled = false,
    this.session,
    this.snapshots = const [],
    this.lastResult,
    this.error,
  });

  final bool isLoading;
  final bool enabled;
  final RpgGameSession? session;
  final List<RpgStateSnapshot> snapshots;
  final RpgNarrativeResult? lastResult;
  final String? error;

  bool get hasSession => session != null;

  RpgChatUiState copyWith({
    bool? isLoading,
    bool? enabled,
    RpgGameSession? session,
    bool clearSession = false,
    List<RpgStateSnapshot>? snapshots,
    RpgNarrativeResult? lastResult,
    bool clearLastResult = false,
    String? error,
  }) {
    return RpgChatUiState(
      isLoading: isLoading ?? this.isLoading,
      enabled: enabled ?? this.enabled,
      session: clearSession ? null : (session ?? this.session),
      snapshots: snapshots ?? this.snapshots,
      lastResult: clearLastResult ? null : (lastResult ?? this.lastResult),
      error: error,
    );
  }
}

class RpgChatController extends StateNotifier<RpgChatUiState> {
  RpgChatController({
    required this.chatId,
    required RpgGameSessionService sessionService,
    required RpgPersistenceRepository repository,
    required SharedPreferences preferences,
    RpgRuleEngine engine = const RpgRuleEngine(),
  })  : _sessionService = sessionService,
        _repository = repository,
        _preferences = preferences,
        _engine = engine,
        super(const RpgChatUiState()) {
    unawaited(load());
  }

  final String chatId;
  final RpgGameSessionService _sessionService;
  final RpgPersistenceRepository _repository;
  final SharedPreferences _preferences;
  final RpgRuleEngine _engine;
  Future<void>? _loading;
  bool _hasLoaded = false;

  String get _modePreferenceKey => 'rpg.mode.enabled.$chatId';

  List<RpgActionDefinition> get availableActions {
    final session = state.session;
    if (session == null) return const [];
    return _engine.availableActions(session.scenario, session.state);
  }

  bool isActionAvailable(String actionId) =>
      availableActions.any((action) => action.id == actionId);

  Future<void> load({bool force = false}) {
    if (!force && _hasLoaded) return Future.value();
    final current = _loading;
    if (current != null) return current;
    final loading = _load();
    _loading = loading;
    return loading.whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final session = await _sessionService.load(chatId);
      final enabledPreference = _preferences.getBool(_modePreferenceKey);
      final snapshots = session == null
          ? const <RpgStateSnapshot>[]
          : await _sessionService.listSessionSnapshots(chatId);
      _hasLoaded = true;
      state = state.copyWith(
        isLoading: false,
        enabled: session != null && (enabledPreference ?? true),
        session: session,
        clearSession: session == null,
        snapshots: snapshots,
        error: null,
      );
    } catch (error) {
      _hasLoaded = true;
      state = state.copyWith(isLoading: false, error: error.toString());
    }
  }

  Future<bool> isModeEnabled() async {
    await load();
    return state.enabled && state.session != null;
  }

  Future<RpgGameSession?> enabledSession() async {
    await load();
    return state.enabled ? state.session : null;
  }

  Future<List<RpgScenario>> listScenarios() => _repository.listScenarios();

  Future<void> enable(RpgScenario scenario) async {
    await load();
    state = state.copyWith(isLoading: true, error: null);
    try {
      final current = state.session;
      final session = current ??
          await _sessionService.initialize(chatId: chatId, scenario: scenario);
      if (session.scenario.metadata.id != scenario.metadata.id) {
        throw RpgSessionException(
          'scenario_already_selected',
          'This chat already uses `${session.scenario.metadata.name}`.',
        );
      }
      await _preferences.setBool(_modePreferenceKey, true);
      _hasLoaded = false;
      await load(force: true);
    } catch (error) {
      state = state.copyWith(isLoading: false, error: error.toString());
      rethrow;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    await load();
    if (enabled && state.session == null) {
      throw const RpgSessionException(
        'session_not_found',
        'Choose an RPG scenario before enabling RPG mode.',
      );
    }
    await _preferences.setBool(_modePreferenceKey, enabled);
    state = state.copyWith(enabled: enabled, error: null);
  }

  Future<void> executeAction(String actionId) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final session = state.session;
      final action = session?.scenario.actions
          .where((candidate) => candidate.id == actionId)
          .firstOrNull;
      final committed = await _sessionService.executeAction(
        chatId: chatId,
        actionId: actionId,
      );
      final result = RpgNarrativeResult(
        chatId: chatId,
        status: RpgNarrativeStatus.committed,
        narrative: '',
        actionId: actionId,
        actionLabel: action?.label,
        feedback: committed.execution.succeeded
            ? 'Rule engine committed the action.'
            : 'Rule engine committed the failed check outcome.',
        execution: committed.execution,
        snapshot: committed.snapshot,
      );
      _hasLoaded = false;
      await load(force: true);
      state = state.copyWith(lastResult: result, error: null);
    } on RpgRuleViolation catch (error) {
      final result = RpgNarrativeResult(
        chatId: chatId,
        status: RpgNarrativeStatus.rejected,
        narrative: '',
        actionId: actionId,
        feedback:
            'Action rejected (${error.code}): ${error.message} No state changed.',
        errorCode: error.code,
      );
      state = state.copyWith(isLoading: false, lastResult: result, error: null);
    } catch (error) {
      state = state.copyWith(isLoading: false, error: error.toString());
      rethrow;
    }
  }

  Future<void> rollback(String snapshotId) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _sessionService.rollback(chatId: chatId, snapshotId: snapshotId);
      _hasLoaded = false;
      await load(force: true);
    } catch (error) {
      state = state.copyWith(isLoading: false, error: error.toString());
      rethrow;
    }
  }

  Future<void> forkBranch({
    required String snapshotId,
    required String branchId,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _sessionService.forkBranch(
        chatId: chatId,
        fromSnapshotId: snapshotId,
        branchId: branchId,
      );
      _hasLoaded = false;
      await load(force: true);
    } catch (error) {
      state = state.copyWith(isLoading: false, error: error.toString());
      rethrow;
    }
  }

  Future<void> applyNarrativeResult(RpgNarrativeResult result) async {
    if (result.status == RpgNarrativeStatus.committed) {
      _hasLoaded = false;
      await load(force: true);
    }
    state = state.copyWith(lastResult: result, error: null);
  }
}

final rpgChatProvider =
    StateNotifierProvider.family<RpgChatController, RpgChatUiState, String>((
  ref,
  chatId,
) {
  return RpgChatController(
    chatId: chatId,
    sessionService: ref.watch(rpgGameSessionServiceProvider),
    repository: ref.watch(rpgPersistenceRepositoryProvider),
    preferences: ref.watch(sharedPreferencesProvider),
  );
});

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/mcp.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/models/tool_generation.dart';
import 'package:native_tavern/domain/services/capability_registry.dart';
import 'package:native_tavern/domain/services/tool_calling/built_in_tool_service.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_generation_loop.dart';
import 'package:native_tavern/presentation/providers/image_gen_providers.dart';
import 'package:native_tavern/presentation/providers/mcp_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/variables_providers.dart';
import 'package:native_tavern/presentation/providers/world_info_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class ToolCallingSettingsController
    extends StateNotifier<ToolCallingSettings> {
  ToolCallingSettingsController(this._preferences) : super(_load(_preferences));

  static const _key = 'tool_calling_settings';
  final SharedPreferences _preferences;

  static ToolCallingSettings _load(SharedPreferences preferences) {
    try {
      final stored = preferences.getString(_key);
      if (stored == null) return ToolCallingSettings();
      return ToolCallingSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(stored) as Map),
      );
    } catch (_) {
      return ToolCallingSettings();
    }
  }

  Future<void> _save(ToolCallingSettings value) async {
    state = value;
    await _preferences.setString(_key, jsonEncode(value.toJson()));
  }

  Future<void> setEnabled(bool enabled) {
    return _save(state.copyWith(enabled: enabled));
  }

  Future<void> setBuiltInEnabled(String toolName, bool enabled) {
    final tools = state.enabledBuiltInTools.toSet();
    enabled ? tools.add(toolName) : tools.remove(toolName);
    return _save(state.copyWith(enabledBuiltInTools: tools));
  }

  Future<void> setLimits(ToolLoopLimits limits) {
    limits.validate();
    return _save(state.copyWith(limits: limits));
  }
}

final toolCallingSettingsProvider =
    StateNotifierProvider<ToolCallingSettingsController, ToolCallingSettings>(
        (ref) {
  return ToolCallingSettingsController(ref.watch(sharedPreferencesProvider));
});

final builtInToolRegistryProvider = Provider<BuiltInToolRegistry>((ref) {
  return BuiltInToolRegistry.nativeTavern(
    imageGenerator: ImageGenerationServiceToolImageGenerator(
      ref.watch(imageGenServiceProvider),
    ),
    variableReader: VariablesServiceToolVariableReader(
      ref.watch(variablesServiceProvider),
    ),
    worldInfoSource: WorldInfoRepositoryToolWorldInfoSource(
      ref.watch(worldInfoRepositoryProvider),
    ),
  );
});

final builtInToolExecutionServiceProvider =
    Provider<BuiltInToolExecutionService>((ref) {
  return BuiltInToolExecutionService(
    registry: ref.watch(builtInToolRegistryProvider),
    auditRepository: ref.watch(toolExecutionAuditRepositoryProvider),
  );
});

final toolCapabilitySnapshotProvider = Provider<ToolCapabilitySnapshot>((ref) {
  final capabilities = <CapabilityId>{};
  if (ref.watch(imageGenSettingsProvider).enabled) {
    capabilities.add(CapabilityId.imageGeneration);
  }
  if (ref.watch(mcpManagementProvider).enabled) {
    capabilities.add(CapabilityId.mcp);
  }
  return ToolCapabilitySnapshot.available(capabilities);
});

final toolGenerationLoopProvider = Provider<ToolGenerationLoop>((ref) {
  return ToolGenerationLoop(
    builtInTools: ref.watch(builtInToolExecutionServiceProvider),
    mcpManager: ref.watch(mcpClientManagerProvider),
    transport: ref.watch(llmServiceProvider).generateToolTurn,
  );
});

enum ToolApprovalKind { builtIn, mcp }

enum ToolApprovalAction { allowOnce, alwaysAllow, deny, cancel }

final class PendingToolApproval {
  PendingToolApproval({
    required this.chatId,
    required this.kind,
    required this.preview,
    required Completer<ToolApprovalAction> completer,
  }) : _completer = completer;

  final String chatId;
  final ToolApprovalKind kind;
  final ToolExecutionPreview preview;
  final Completer<ToolApprovalAction> _completer;
}

final class ToolRuntimeState {
  const ToolRuntimeState({
    this.chatId,
    this.activities = const [],
    this.pendingApproval,
  });

  final String? chatId;
  final List<ToolCallProgress> activities;
  final PendingToolApproval? pendingApproval;

  ToolRuntimeState copyWith({
    String? chatId,
    List<ToolCallProgress>? activities,
    PendingToolApproval? pendingApproval,
    bool clearApproval = false,
  }) {
    return ToolRuntimeState(
      chatId: chatId ?? this.chatId,
      activities: activities ?? this.activities,
      pendingApproval:
          clearApproval ? null : (pendingApproval ?? this.pendingApproval),
    );
  }
}

final class ToolGenerationHandle {
  const ToolGenerationHandle(this.chatId, this.controller);

  final String chatId;
  final ToolCancellationController controller;
  ToolCancellationToken get token => controller.token;
}

final class ToolRuntimeController extends StateNotifier<ToolRuntimeState> {
  ToolRuntimeController() : super(const ToolRuntimeState());

  ToolGenerationHandle? _active;

  ToolGenerationHandle beginGeneration(String chatId) {
    cancelGeneration('Replaced by a newer generation.');
    final handle = ToolGenerationHandle(
      chatId,
      ToolCancellationController(),
    );
    _active = handle;
    state = ToolRuntimeState(chatId: chatId);
    return handle;
  }

  void finishGeneration(ToolGenerationHandle handle) {
    if (identical(_active, handle)) _active = null;
  }

  void report(ToolCallProgress progress) {
    if (state.chatId != progress.chatId) return;
    final activities = [...state.activities];
    final index = activities.indexWhere(
      (activity) => activity.callId == progress.callId,
    );
    if (index < 0) {
      activities.add(progress);
    } else {
      activities[index] = progress;
    }
    state = state.copyWith(activities: activities);
  }

  Future<ToolApprovalDecision> requestBuiltIn(
    String chatId,
    ToolExecutionPreview preview,
  ) async {
    final action = await _request(chatId, ToolApprovalKind.builtIn, preview);
    return switch (action) {
      ToolApprovalAction.allowOnce ||
      ToolApprovalAction.alwaysAllow =>
        ToolApprovalDecision.approveOnce,
      ToolApprovalAction.deny => ToolApprovalDecision.deny,
      ToolApprovalAction.cancel => ToolApprovalDecision.cancel,
    };
  }

  Future<McpApprovalDecision> requestMcp(
    String chatId,
    ToolExecutionPreview preview,
  ) async {
    final action = await _request(chatId, ToolApprovalKind.mcp, preview);
    return switch (action) {
      ToolApprovalAction.allowOnce => McpApprovalDecision.allowOnce,
      ToolApprovalAction.alwaysAllow => McpApprovalDecision.alwaysAllow,
      ToolApprovalAction.deny => McpApprovalDecision.deny,
      ToolApprovalAction.cancel => McpApprovalDecision.cancel,
    };
  }

  Future<ToolApprovalAction> _request(
    String chatId,
    ToolApprovalKind kind,
    ToolExecutionPreview preview,
  ) async {
    if (_active?.chatId != chatId || _active?.token.isCancelled == true) {
      return ToolApprovalAction.cancel;
    }
    _completePending(ToolApprovalAction.cancel);
    final completer = Completer<ToolApprovalAction>();
    state = state.copyWith(
      pendingApproval: PendingToolApproval(
        chatId: chatId,
        kind: kind,
        preview: preview,
        completer: completer,
      ),
    );
    final action = await completer.future;
    if (identical(state.pendingApproval?._completer, completer)) {
      state = state.copyWith(clearApproval: true);
    }
    return action;
  }

  void resolveApproval(ToolApprovalAction action) {
    final pending = state.pendingApproval;
    if (pending == null) return;
    if (pending.kind == ToolApprovalKind.builtIn &&
        action == ToolApprovalAction.alwaysAllow) {
      action = ToolApprovalAction.allowOnce;
    }
    _completePending(action);
    state = state.copyWith(clearApproval: true);
  }

  void cancelGeneration([String reason = 'Cancelled by user.']) {
    _active?.controller.cancel(reason);
    _active = null;
    _completePending(ToolApprovalAction.cancel);
    if (state.pendingApproval != null) {
      state = state.copyWith(clearApproval: true);
    }
  }

  void clearActivities(String chatId) {
    if (state.chatId == chatId && state.pendingApproval == null) {
      state = ToolRuntimeState(chatId: chatId);
    }
  }

  void _completePending(ToolApprovalAction action) {
    final completer = state.pendingApproval?._completer;
    if (completer != null && !completer.isCompleted) completer.complete(action);
  }

  @override
  void dispose() {
    cancelGeneration('Tool runtime disposed.');
    super.dispose();
  }
}

final toolRuntimeProvider =
    StateNotifierProvider<ToolRuntimeController, ToolRuntimeState>((ref) {
  return ToolRuntimeController();
});

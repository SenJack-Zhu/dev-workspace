import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/services/stt_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/stt_providers.dart';

class ChatVoiceInputButton extends ConsumerStatefulWidget {
  const ChatVoiceInputButton({
    super.key,
    required this.controller,
    required this.onAutoSend,
  });

  final TextEditingController controller;
  final FutureOr<void> Function() onAutoSend;

  @override
  ConsumerState<ChatVoiceInputButton> createState() =>
      _ChatVoiceInputButtonState();
}

class _ChatVoiceInputButtonState extends ConsumerState<ChatVoiceInputButton> {
  String _originalDraft = '';
  int? _sessionId;
  int? _handledTerminalSequence;
  bool _pressHeld = false;
  STTService? _service;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(sttSettingsProvider);
    final session = ref.watch(sttSessionProvider);
    final active = session.isActive && session.sessionId == _sessionId;
    final l10n = AppLocalizations.of(context);
    _service = ref.read(sttServiceProvider);

    ref.listen<STTSessionState>(sttSessionProvider, _handleSessionChange);

    if (!settings.enabled) return const SizedBox.shrink();

    return SizedBox(
      width: 80,
      height: 48,
      child: Row(
        children: [
          Listener(
            key: const ValueKey('chat-voice-hold-button'),
            onPointerDown: active ? null : (_) => unawaited(_start()),
            onPointerUp: active ? (_) => unawaited(_stop()) : null,
            onPointerCancel: active ? (_) => unawaited(_cancel()) : null,
            child: Semantics(
              button: true,
              label: active ? l10n.releaseToTranscribe : l10n.holdToTalk,
              child: Tooltip(
                message: active ? l10n.releaseToTranscribe : l10n.holdToTalk,
                child: SizedBox.square(
                  dimension: 40,
                  child: Icon(
                    active ? Icons.mic : Icons.mic_none,
                    color: active ? Colors.red : null,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('chat-voice-cancel-button'),
            onPressed: active ? _cancel : null,
            icon: const Icon(Icons.close),
            tooltip: l10n.cancelVoiceInput,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Future<void> _start() async {
    if (_pressHeld) return;
    _pressHeld = true;
    _originalDraft = widget.controller.text;
    _handledTerminalSequence = null;
    ref.read(sttSessionProvider.notifier).clear();
    final starting = ref.read(sttSessionProvider.notifier).start();
    _sessionId = ref.read(sttSessionProvider).sessionId;
    await starting;
    if (!_pressHeld && ref.read(sttSessionProvider).isActive) {
      await ref.read(sttSessionProvider.notifier).stop();
    }
  }

  Future<void> _stop() async {
    _pressHeld = false;
    await ref.read(sttSessionProvider.notifier).stop();
  }

  Future<void> _cancel() async {
    _pressHeld = false;
    await ref.read(sttSessionProvider.notifier).cancel();
  }

  void _handleSessionChange(
    STTSessionState? previous,
    STTSessionState next,
  ) {
    if (_sessionId == null || next.sessionId != _sessionId) return;

    final transcript = next.result?.text ?? '';
    if (transcript.isNotEmpty &&
        next.phase != STTSessionPhase.cancelled &&
        !_isFailure(next.phase)) {
      _replaceDraftWithTranscript(transcript);
    }

    if (!_isTerminal(next.phase) || _handledTerminalSequence == next.sequence) {
      return;
    }
    _handledTerminalSequence = next.sequence;

    if (next.phase == STTSessionPhase.cancelled || _isFailure(next.phase)) {
      _restoreOriginalDraft();
    }

    if (_isFailure(next.phase) && next.message != null && mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(next.message!),
          action: next.phase == STTSessionPhase.permissionPermanentlyDenied
              ? SnackBarAction(
                  label: AppLocalizations.of(context).openSystemSettings,
                  onPressed: () => unawaited(
                    ref
                        .read(sttSessionProvider.notifier)
                        .openPermissionSettings(),
                  ),
                )
              : null,
        ),
      );
    }

    if (next.phase == STTSessionPhase.completed &&
        transcript.trim().isNotEmpty &&
        ref.read(sttSettingsProvider).autoSend) {
      unawaited(Future<void>.sync(widget.onAutoSend));
    }
  }

  void _replaceDraftWithTranscript(String transcript) {
    final separator =
        _originalDraft.isEmpty || _originalDraft.endsWith(' ') ? '' : ' ';
    final nextText = '$_originalDraft$separator$transcript';
    widget.controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  void _restoreOriginalDraft() {
    widget.controller.value = TextEditingValue(
      text: _originalDraft,
      selection: TextSelection.collapsed(offset: _originalDraft.length),
    );
  }

  bool _isTerminal(STTSessionPhase phase) =>
      phase == STTSessionPhase.completed ||
      phase == STTSessionPhase.cancelled ||
      _isFailure(phase);

  bool _isFailure(STTSessionPhase phase) =>
      phase == STTSessionPhase.failed ||
      phase == STTSessionPhase.unavailable ||
      phase == STTSessionPhase.permissionDenied ||
      phase == STTSessionPhase.permissionPermanentlyDenied;

  @override
  void dispose() {
    final service = _service;
    if (service?.state.sessionId == _sessionId &&
        service?.state.isActive == true) {
      unawaited(service!.cancelListening());
    }
    super.dispose();
  }
}

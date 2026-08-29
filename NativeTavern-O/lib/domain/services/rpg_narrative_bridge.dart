import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/rpg_game_session_service.dart';
import 'package:native_tavern/domain/services/rpg_rule_engine.dart';

typedef RpgSessionLoader = Future<RpgGameSession?> Function(String chatId);
typedef RpgModeResolver = FutureOr<bool> Function(String chatId);
typedef RpgNarrativeResultCallback = FutureOr<void> Function(
    RpgNarrativeResult result);

enum RpgNarrativeStatus { noAction, committed, rejected, malformed, cancelled }

class RpgNarrativeResult {
  const RpgNarrativeResult({
    required this.chatId,
    required this.status,
    required this.narrative,
    this.actionId,
    this.actionLabel,
    this.feedback = '',
    this.errorCode,
    this.execution,
    this.snapshot,
  });

  final String chatId;
  final RpgNarrativeStatus status;
  final String narrative;
  final String? actionId;
  final String? actionLabel;
  final String feedback;
  final String? errorCode;
  final RpgActionExecution? execution;
  final RpgStateSnapshot? snapshot;
}

class RpgNarrativeEnvelope {
  const RpgNarrativeEnvelope({required this.narrative, this.actionId});

  final String narrative;
  final String? actionId;
}

class RpgNarrativeFormatException implements Exception {
  const RpgNarrativeFormatException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'RpgNarrativeFormatException($code): $message';
}

class RpgNarrativeResponseParser {
  const RpgNarrativeResponseParser();

  RpgNarrativeEnvelope parse(String source) {
    final normalized = _unwrapJsonFence(source.trim());
    Object? decoded;
    try {
      decoded = jsonDecode(normalized);
    } on FormatException {
      throw const RpgNarrativeFormatException(
        'invalid_json',
        'The model response is not valid JSON.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const RpgNarrativeFormatException(
        'invalid_root',
        'The RPG response must be a JSON object.',
      );
    }

    const allowedRootKeys = {'narrative', 'proposedAction'};
    final unexpectedRootKeys = decoded.keys.toSet().difference(allowedRootKeys);
    if (unexpectedRootKeys.isNotEmpty) {
      throw RpgNarrativeFormatException(
        'unexpected_field',
        'Unexpected RPG response field `${unexpectedRootKeys.first}`.',
      );
    }

    final narrative = decoded['narrative'];
    if (narrative is! String || narrative.trim().isEmpty) {
      throw const RpgNarrativeFormatException(
        'invalid_narrative',
        'The RPG response requires a non-empty narrative.',
      );
    }

    final proposedAction = decoded['proposedAction'];
    if (proposedAction == null) {
      return RpgNarrativeEnvelope(narrative: narrative.trim());
    }
    if (proposedAction is! Map<String, dynamic> ||
        proposedAction.keys.any((key) => key != 'actionId')) {
      throw const RpgNarrativeFormatException(
        'invalid_action',
        'The proposed action may only contain an actionId.',
      );
    }
    final actionId = proposedAction['actionId'];
    if (actionId is! String || actionId.trim().isEmpty) {
      throw const RpgNarrativeFormatException(
        'invalid_action_id',
        'The proposed action requires a non-empty actionId.',
      );
    }
    return RpgNarrativeEnvelope(
      narrative: narrative.trim(),
      actionId: actionId.trim(),
    );
  }
}

class RpgNarrativeContextContributor extends ContextContributor {
  RpgNarrativeContextContributor({
    required RpgSessionLoader loadSession,
    required RpgModeResolver isModeEnabled,
    RpgRuleEngine engine = const RpgRuleEngine(),
  })  : _loadSession = loadSession,
        _isModeEnabled = isModeEnabled,
        _engine = engine;

  final RpgSessionLoader _loadSession;
  final RpgModeResolver _isModeEnabled;
  final RpgRuleEngine _engine;

  @override
  String get id => 'native_tavern.rpg.context';

  @override
  int get order => 700;

  @override
  int get maxTokens => 1800;

  @override
  Future<bool> isEnabled(ChatContextRequest request) async =>
      await _isModeEnabled(request.chatId) &&
      await _loadSession(request.chatId) != null;

  @override
  Future<ContextContribution> contribute(ChatContextRequest request) async {
    request.cancellationToken.throwIfCancelled();
    final session = await _loadSession(request.chatId);
    if (session == null) {
      throw StateError('The RPG session is no longer available.');
    }
    final state = session.state;
    final scenario = session.scenario;
    final actions = _engine.availableActions(scenario, state);
    final payload = {
      'scenario': {
        'id': scenario.metadata.id,
        'name': scenario.metadata.name,
        'version': scenario.metadata.version,
      },
      'state': {
        'turn': state.turn,
        'locationId': state.locationId,
        'attributes': state.attributes,
        'variables': state.variables,
        'inventory': state.inventory.map((entry) => entry.toJson()).toList(),
        'relationships': state.relationships
            .map((relationship) => relationship.toJson())
            .toList(),
        'quests': state.quests.map((quest) => quest.toJson()).toList(),
        'clock': state.clock.toJson(),
        'cooldowns': state.cooldowns,
      },
      'allowedActions': actions
          .map(
            (action) => {
              'actionId': action.id,
              'label': action.label,
              if (action.description.isNotEmpty)
                'description': action.description,
              if (action.costs.isNotEmpty)
                'costs': action.costs.map((cost) => cost.toJson()).toList(),
              if (action.check != null) 'check': action.check!.toJson(),
            },
          )
          .toList(),
    };
    const encoder = JsonEncoder.withIndent('  ');
    return ContextContribution(
      placement: ContextContributionPlacement.beforeConversation,
      messages: [
        {
          'role': 'system',
          'content': '''You are narrating a deterministic RPG session.
The JSON below is authoritative. Describe events, but never claim or encode direct state mutations. You may only propose one listed action by its exact actionId. The application will validate and execute it.

Return exactly one JSON object with no prose or markdown outside it:
{"narrative":"player-facing narration","proposedAction":null}
or
{"narrative":"player-facing narration before resolution","proposedAction":{"actionId":"allowed_action_id"}}

Do not add fields such as state, statePatch, effects, inventory, attributes, quests, random, or turn. If no listed action fits, use null.

RPG_CONTEXT:
${encoder.convert(payload)}''',
        },
      ],
    );
  }
}

class RpgNarrativeMiddleware extends ChatGenerationMiddleware
    implements ChatGenerationResponseTransformer {
  RpgNarrativeMiddleware({
    required RpgGameSessionService sessionService,
    required RpgSessionLoader loadSession,
    required RpgModeResolver isModeEnabled,
    required RpgNarrativeResultCallback onResult,
    RpgNarrativeResponseParser parser = const RpgNarrativeResponseParser(),
  })  : _sessionService = sessionService,
        _loadSession = loadSession,
        _isModeEnabled = isModeEnabled,
        _onResult = onResult,
        _parser = parser;

  final RpgGameSessionService _sessionService;
  final RpgSessionLoader _loadSession;
  final RpgModeResolver _isModeEnabled;
  final RpgNarrativeResultCallback _onResult;
  final RpgNarrativeResponseParser _parser;

  @override
  String get id => 'native_tavern.rpg.response';

  @override
  int get order => 700;

  @override
  Future<bool> isEnabled(ChatGenerationRequest request) async =>
      await _isModeEnabled(request.chatId) &&
      await _loadSession(request.chatId) != null;

  @override
  Future<LLMResponse> transformResponse(
    ChatGenerationRequest request,
    LLMResponse response,
  ) async {
    request.cancellationToken.throwIfCancelled();
    RpgNarrativeEnvelope envelope;
    try {
      envelope = _parser.parse(response.content);
    } on RpgNarrativeFormatException catch (error) {
      final result = RpgNarrativeResult(
        chatId: request.chatId,
        status: RpgNarrativeStatus.malformed,
        narrative: '',
        feedback: '${error.message} No action was applied.',
        errorCode: error.code,
      );
      await _onResult(result);
      return LLMResponse(
        content: result.feedback,
        reasoning: response.reasoning,
      );
    }

    final actionId = envelope.actionId;
    if (actionId == null) {
      await _onResult(
        RpgNarrativeResult(
          chatId: request.chatId,
          status: RpgNarrativeStatus.noAction,
          narrative: envelope.narrative,
        ),
      );
      return LLMResponse(
        content: envelope.narrative,
        reasoning: response.reasoning,
      );
    }

    final session = await _loadSession(request.chatId);
    final action = session?.scenario.actions
        .where((candidate) => candidate.id == actionId)
        .firstOrNull;
    try {
      request.cancellationToken.throwIfCancelled();
      final committed = await _sessionService.executeAction(
        chatId: request.chatId,
        actionId: actionId,
      );
      final feedback = _formatCommittedFeedback(
        action?.label ?? actionId,
        committed.execution,
      );
      await _onResult(
        RpgNarrativeResult(
          chatId: request.chatId,
          status: RpgNarrativeStatus.committed,
          narrative: envelope.narrative,
          actionId: actionId,
          actionLabel: action?.label,
          feedback: feedback,
          execution: committed.execution,
          snapshot: committed.snapshot,
        ),
      );
      return LLMResponse(
        content: '${envelope.narrative}\n\n$feedback',
        reasoning: response.reasoning,
      );
    } on RpgRuleViolation catch (error) {
      return _rejectedResponse(
        request: request,
        response: response,
        envelope: envelope,
        actionLabel: action?.label,
        errorCode: error.code,
        message: error.message,
      );
    } on RpgSessionException catch (error) {
      return _rejectedResponse(
        request: request,
        response: response,
        envelope: envelope,
        actionLabel: action?.label,
        errorCode: error.code,
        message: error.message,
      );
    }
  }

  Future<LLMResponse> _rejectedResponse({
    required ChatGenerationRequest request,
    required LLMResponse response,
    required RpgNarrativeEnvelope envelope,
    required String? actionLabel,
    required String errorCode,
    required String message,
  }) async {
    final feedback = 'Action rejected ($errorCode): $message No state changed.';
    await _onResult(
      RpgNarrativeResult(
        chatId: request.chatId,
        status: RpgNarrativeStatus.rejected,
        narrative: envelope.narrative,
        actionId: envelope.actionId,
        actionLabel: actionLabel,
        feedback: feedback,
        errorCode: errorCode,
      ),
    );
    return LLMResponse(
      content: '${envelope.narrative}\n\n$feedback',
      reasoning: response.reasoning,
    );
  }

  @override
  Future<void> onCancelled(ChatGenerationRequest request) async {
    if (!await _isModeEnabled(request.chatId)) return;
    await _onResult(
      RpgNarrativeResult(
        chatId: request.chatId,
        status: RpgNarrativeStatus.cancelled,
        narrative: '',
        feedback: 'Generation cancelled. No RPG action was applied.',
      ),
    );
  }
}

String _formatCommittedFeedback(
  String actionLabel,
  RpgActionExecution execution,
) {
  final details = <String>[];
  final roll = execution.roll;
  if (roll != null) {
    details.add(
      'check ${execution.checkTotal}/${execution.difficulty} '
      '(${roll.expression}: ${roll.values.join(', ')}'
      '${roll.modifier == 0 ? '' : roll.modifier > 0 ? ' + ${roll.modifier}' : ' - ${-roll.modifier}'})',
    );
  }
  details.addAll(_stateChanges(execution.previousState, execution.state));
  final outcome = execution.succeeded ? 'succeeded' : 'failed its check';
  return [
    'Rule engine: $actionLabel $outcome.',
    if (details.isNotEmpty) details.join('; '),
  ].join(' ');
}

List<String> _stateChanges(RpgRuntimeState before, RpgRuntimeState after) {
  final changes = <String>[];
  if (before.locationId != after.locationId) {
    changes.add('location ${before.locationId} -> ${after.locationId}');
  }
  for (final key in {...before.attributes.keys, ...after.attributes.keys}) {
    if (before.attributes[key] != after.attributes[key]) {
      changes.add(
        '$key ${before.attributes[key] ?? 0} -> ${after.attributes[key] ?? 0}',
      );
    }
  }
  for (final key in {...before.variables.keys, ...after.variables.keys}) {
    if (!const DeepCollectionEquality().equals(
      before.variables[key],
      after.variables[key],
    )) {
      changes.add(
        '$key ${before.variables[key] ?? '-'} -> ${after.variables[key] ?? '-'}',
      );
    }
  }
  final beforeItems = {
    for (final item in before.inventory) item.itemId: item.quantity,
  };
  final afterItems = {
    for (final item in after.inventory) item.itemId: item.quantity,
  };
  for (final key in {...beforeItems.keys, ...afterItems.keys}) {
    if (beforeItems[key] != afterItems[key]) {
      changes.add('$key x${beforeItems[key] ?? 0} -> x${afterItems[key] ?? 0}');
    }
  }
  final beforeRelationships = {
    for (final relationship in before.relationships)
      relationship.actorId: relationship.score,
  };
  final afterRelationships = {
    for (final relationship in after.relationships)
      relationship.actorId: relationship.score,
  };
  for (final key in {
    ...beforeRelationships.keys,
    ...afterRelationships.keys,
  }) {
    if (beforeRelationships[key] != afterRelationships[key]) {
      changes.add(
        '$key relation ${beforeRelationships[key] ?? 0} -> ${afterRelationships[key] ?? 0}',
      );
    }
  }
  final beforeQuests = {
    for (final quest in before.quests) quest.questId: quest.status,
  };
  final afterQuests = {
    for (final quest in after.quests) quest.questId: quest.status,
  };
  for (final key in {...beforeQuests.keys, ...afterQuests.keys}) {
    if (beforeQuests[key] != afterQuests[key]) {
      changes.add(
        '$key ${beforeQuests[key]?.name ?? '-'} -> ${afterQuests[key]?.name ?? '-'}',
      );
    }
  }
  for (final key in {...before.cooldowns.keys, ...after.cooldowns.keys}) {
    if (before.cooldowns[key] != after.cooldowns[key]) {
      changes.add(
        '$key cooldown ${before.cooldowns[key] ?? 0} -> ${after.cooldowns[key] ?? 0}',
      );
    }
  }
  if (before.clock.elapsedMinutes != after.clock.elapsedMinutes) {
    changes.add(
      'time ${before.clock.elapsedMinutes} -> ${after.clock.elapsedMinutes} minutes',
    );
  }
  if (changes.isEmpty) changes.add('turn ${before.turn} -> ${after.turn}');
  return changes;
}

String _unwrapJsonFence(String source) {
  final match = RegExp(
    r'^```(?:json)?\s*([\s\S]*?)\s*```$',
    caseSensitive: false,
  ).firstMatch(source);
  return match?.group(1)?.trim() ?? source;
}

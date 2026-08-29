import 'package:collection/collection.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';

enum RpgActionOutcome { succeeded, failedCheck }

class RpgDiceRoll {
  const RpgDiceRoll({
    required this.expression,
    required this.values,
    required this.modifier,
  });

  final String expression;
  final List<int> values;
  final int modifier;

  int get total => values.fold(modifier, (sum, value) => sum + value);

  Map<String, Object?> toJson() => {
        'expression': expression,
        'values': values,
        'modifier': modifier,
        'total': total,
      };
}

class RpgActionExecution {
  const RpgActionExecution({
    required this.actionId,
    required this.outcome,
    required this.previousState,
    required this.state,
    this.roll,
    this.checkTotal,
    this.difficulty,
  });

  final String actionId;
  final RpgActionOutcome outcome;
  final RpgRuntimeState previousState;
  final RpgRuntimeState state;
  final RpgDiceRoll? roll;
  final num? checkTotal;
  final num? difficulty;

  bool get succeeded => outcome == RpgActionOutcome.succeeded;
}

class RpgRuleViolation implements Exception {
  const RpgRuleViolation(this.code, this.message, {this.path});

  final String code;
  final String message;
  final String? path;

  @override
  String toString() => path == null
      ? 'RpgRuleViolation($code): $message'
      : 'RpgRuleViolation($code) at $path: $message';
}

/// Executes declarative scenario rules without wall-clock or platform inputs.
class RpgRuleEngine {
  const RpgRuleEngine({this.validator = const RpgScenarioValidator()});

  final RpgScenarioValidator validator;

  List<RpgActionDefinition> availableActions(
    RpgScenario scenario,
    RpgRuntimeState state,
  ) {
    _validateRuntimeState(scenario, state);
    return List.unmodifiable(
      scenario.actions.where(
        (action) =>
            (state.cooldowns[action.id] ?? 0) == 0 &&
            action.availability.every(
              (condition) => _evaluateCondition(condition, state),
            ) &&
            action.costs.every((cost) => _canPayCost(scenario, state, cost)),
      ),
    );
  }

  RpgActionExecution execute({
    required RpgScenario scenario,
    required RpgRuntimeState state,
    required String actionId,
  }) {
    _validateRuntimeState(scenario, state);
    final action = scenario.actions
        .where((candidate) => candidate.id == actionId)
        .firstOrNull;
    if (action == null) {
      throw RpgRuleViolation(
        'unknown_action',
        'Action `$actionId` is not defined by scenario `${scenario.metadata.id}`.',
        path: 'actionId',
      );
    }

    final cooldown = state.cooldowns[action.id] ?? 0;
    if (cooldown > 0) {
      throw RpgRuleViolation(
        'action_on_cooldown',
        'Action `${action.id}` is unavailable for $cooldown more turn(s).',
        path: 'cooldowns.${action.id}',
      );
    }
    for (var index = 0; index < action.availability.length; index++) {
      if (!_evaluateCondition(action.availability[index], state)) {
        throw RpgRuleViolation(
          'condition_not_met',
          'Action `${action.id}` does not satisfy availability condition $index.',
          path: 'actions.${action.id}.availability[$index]',
        );
      }
    }
    for (var index = 0; index < action.costs.length; index++) {
      if (!_canPayCost(scenario, state, action.costs[index])) {
        throw RpgRuleViolation(
          'insufficient_resource',
          'Action `${action.id}` cannot pay cost `${action.costs[index].path}`.',
          path: 'actions.${action.id}.costs[$index]',
        );
      }
    }

    final draft = _RpgStateDraft.fromState(state)..tickCooldowns();
    for (final cost in action.costs) {
      draft.adjustNumeric(cost.path, -cost.amount);
    }

    RpgDiceRoll? roll;
    num? checkTotal;
    var outcome = RpgActionOutcome.succeeded;
    final selectedEffects = <RpgEffect>[];
    if (action.check case final check?) {
      roll = draft.roll(check.dice);
      checkTotal = roll.total + (draft.attributes[check.attributeId] ?? 0);
      outcome = checkTotal >= check.difficulty
          ? RpgActionOutcome.succeeded
          : RpgActionOutcome.failedCheck;
      selectedEffects.addAll(
        outcome == RpgActionOutcome.succeeded
            ? check.successEffects
            : check.failureEffects,
      );
    }
    selectedEffects.addAll(action.effects);

    for (var index = 0; index < selectedEffects.length; index++) {
      try {
        draft.applyEffect(selectedEffects[index]);
      } on RpgRuleViolation catch (error) {
        throw RpgRuleViolation(
          error.code,
          error.message,
          path:
              'actions.${action.id}.effects[$index]${error.path == null ? '' : '.${error.path}'}',
        );
      }
    }

    draft.turn = state.turn + 1;
    draft.appendTurnRecord(
      action: action,
      outcome: outcome,
      costs: action.costs,
      roll: roll,
      checkTotal: checkTotal,
      difficulty: action.check?.difficulty,
      appliedEffects: selectedEffects,
    );
    final nextState = draft.build();
    _validateRuntimeState(scenario, nextState);

    return RpgActionExecution(
      actionId: action.id,
      outcome: outcome,
      previousState: state,
      state: nextState,
      roll: roll,
      checkTotal: checkTotal,
      difficulty: action.check?.difficulty,
    );
  }

  /// Applies a typed patch after enforcing its declared mutation source.
  /// This does not advance a turn; action execution owns turn progression.
  RpgRuntimeState applyPatch({
    required RpgScenario scenario,
    required RpgRuntimeState state,
    required RpgStatePatch patch,
  }) {
    _validateRuntimeState(scenario, state);
    final validation = validator.validatePatch(scenario, patch);
    if (!validation.isValid) {
      final issue = validation.issues.first;
      throw RpgRuleViolation(issue.code, issue.message, path: issue.path);
    }
    final draft = _RpgStateDraft.fromState(state);
    for (final effect in patch.effects) {
      draft.applyEffect(effect);
    }
    final nextState = draft.build();
    _validateRuntimeState(scenario, nextState);
    return nextState;
  }

  void _validateRuntimeState(RpgScenario scenario, RpgRuntimeState state) {
    final scenarioValidation = validator.validate(scenario);
    if (!scenarioValidation.isValid) {
      final issue = scenarioValidation.issues.first;
      throw RpgRuleViolation(
        'invalid_scenario',
        issue.message,
        path: issue.path,
      );
    }
    final stateValidation = validator.validateRuntimeState(scenario, state);
    if (!stateValidation.isValid) {
      final issue = stateValidation.issues.first;
      throw RpgRuleViolation('invalid_state', issue.message, path: issue.path);
    }
  }

  bool _canPayCost(
    RpgScenario scenario,
    RpgRuntimeState state,
    RpgActionCost cost,
  ) {
    final resolved = _resolvePath(state, cost.path);
    if (!resolved.exists || resolved.value is! num) return false;
    final nextValue = (resolved.value as num) - cost.amount;
    if (!nextValue.isFinite) return false;
    if (cost.path.startsWith('attributes.')) {
      final attributeId = cost.path.substring('attributes.'.length);
      final definition = scenario.attributes
          .where((attribute) => attribute.id == attributeId)
          .firstOrNull;
      return definition != null &&
          (definition.minimum == null || nextValue >= definition.minimum!);
    }
    return nextValue >= 0;
  }

  bool _evaluateCondition(RpgCondition condition, RpgRuntimeState state) {
    switch (condition.operator) {
      case RpgConditionOperator.all:
        return condition.conditions.every(
          (nested) => _evaluateCondition(nested, state),
        );
      case RpgConditionOperator.any:
        return condition.conditions.any(
          (nested) => _evaluateCondition(nested, state),
        );
      case RpgConditionOperator.not:
        return !_evaluateCondition(condition.conditions.single, state);
      case RpgConditionOperator.exists:
        return _resolvePath(state, condition.path!).exists;
      case RpgConditionOperator.equals:
        return const DeepCollectionEquality().equals(
          _resolvePath(state, condition.path!).value,
          condition.value,
        );
      case RpgConditionOperator.notEquals:
        return !const DeepCollectionEquality().equals(
          _resolvePath(state, condition.path!).value,
          condition.value,
        );
      case RpgConditionOperator.greaterThan:
        final comparison = _compare(
          _resolvePath(state, condition.path!).value,
          condition.value,
        );
        return comparison != null && comparison > 0;
      case RpgConditionOperator.greaterThanOrEqual:
        final comparison = _compare(
          _resolvePath(state, condition.path!).value,
          condition.value,
        );
        return comparison != null && comparison >= 0;
      case RpgConditionOperator.lessThan:
        final comparison = _compare(
          _resolvePath(state, condition.path!).value,
          condition.value,
        );
        return comparison != null && comparison < 0;
      case RpgConditionOperator.lessThanOrEqual:
        final comparison = _compare(
          _resolvePath(state, condition.path!).value,
          condition.value,
        );
        return comparison != null && comparison <= 0;
      case RpgConditionOperator.contains:
        return _contains(
          _resolvePath(state, condition.path!).value,
          condition.value,
        );
      case RpgConditionOperator.notContains:
        return !_contains(
          _resolvePath(state, condition.path!).value,
          condition.value,
        );
    }
  }
}

int? _compare(Object? left, Object? right) {
  if (left is num && right is num) return left.compareTo(right);
  if (left is String && right is String) return left.compareTo(right);
  return null;
}

bool _contains(Object? container, Object? value) {
  if (container is String && value is String) return container.contains(value);
  if (container is Iterable<Object?>) {
    return container.any(
      (item) => const DeepCollectionEquality().equals(item, value),
    );
  }
  if (container is Map<Object?, Object?>) return container.containsKey(value);
  return false;
}

class _ResolvedPath {
  const _ResolvedPath(this.exists, this.value);

  final bool exists;
  final Object? value;
}

_ResolvedPath _resolvePath(RpgRuntimeState state, String path) {
  switch (path) {
    case 'turn':
      return _ResolvedPath(true, state.turn);
    case 'random.initialSeed':
      return _ResolvedPath(true, state.random.initialSeed);
    case 'random.state':
      return _ResolvedPath(true, state.random.state);
    case 'random.rollsConsumed':
      return _ResolvedPath(true, state.random.rollsConsumed);
    case 'clock.elapsedMinutes':
      return _ResolvedPath(true, state.clock.elapsedMinutes);
    case 'clock.day':
      return _ResolvedPath(true, state.clock.day);
    case 'clock.minuteOfDay':
      return _ResolvedPath(true, state.clock.minuteOfDay);
    case 'locationId':
      return _ResolvedPath(true, state.locationId);
  }

  final segments = path.split('.');
  if (segments.length == 2) {
    final id = segments[1];
    return switch (segments.first) {
      'attributes' => _ResolvedPath(
          state.attributes.containsKey(id),
          state.attributes[id],
        ),
      'variables' => _ResolvedPath(
          state.variables.containsKey(id),
          state.variables[id],
        ),
      'cooldowns' => _ResolvedPath(
          state.cooldowns.containsKey(id),
          state.cooldowns[id],
        ),
      _ => const _ResolvedPath(false, null),
    };
  }
  if (segments.length == 3) {
    final id = segments[1];
    if (segments.first == 'inventory' && segments.last == 'quantity') {
      final entry =
          state.inventory.where((item) => item.itemId == id).firstOrNull;
      return _ResolvedPath(entry != null, entry?.quantity);
    }
    if (segments.first == 'relationships' && segments.last == 'score') {
      final entry = state.relationships
          .where((relationship) => relationship.actorId == id)
          .firstOrNull;
      return _ResolvedPath(entry != null, entry?.score);
    }
    if (segments.first == 'quests') {
      final entry =
          state.quests.where((quest) => quest.questId == id).firstOrNull;
      return switch (segments.last) {
        'status' => _ResolvedPath(entry != null, entry?.status.name),
        'stageId' => _ResolvedPath(entry != null, entry?.stageId),
        _ => const _ResolvedPath(false, null),
      };
    }
  }
  return const _ResolvedPath(false, null);
}

class _RpgStateDraft {
  _RpgStateDraft.fromState(RpgRuntimeState state)
      : scenarioId = state.scenarioId,
        scenarioVersion = state.scenarioVersion,
        turn = state.turn,
        initialSeed = state.random.initialSeed,
        randomState = state.random.state,
        rollsConsumed = state.random.rollsConsumed,
        attributes = Map.of(state.attributes),
        variables = Map.of(state.variables),
        inventory = {for (final entry in state.inventory) entry.itemId: entry},
        relationships = {
          for (final relationship in state.relationships)
            relationship.actorId: relationship,
        },
        clock = state.clock,
        locationId = state.locationId,
        quests = {for (final quest in state.quests) quest.questId: quest},
        cooldowns = Map.of(state.cooldowns),
        eventHistory = List.of(state.eventHistory);

  final String scenarioId;
  final String scenarioVersion;
  int turn;
  final int initialSeed;
  int randomState;
  int rollsConsumed;
  final Map<String, num> attributes;
  final Map<String, Object?> variables;
  final Map<String, RpgInventoryEntry> inventory;
  final Map<String, RpgRelationshipState> relationships;
  RpgClockState clock;
  String locationId;
  final Map<String, RpgQuestState> quests;
  final Map<String, int> cooldowns;
  final List<RpgEventRecord> eventHistory;

  void tickCooldowns() {
    for (final entry in cooldowns.entries.toList()) {
      final next = entry.value - 1;
      if (next <= 0) {
        cooldowns.remove(entry.key);
      } else {
        cooldowns[entry.key] = next;
      }
    }
  }

  RpgDiceRoll roll(RpgDiceSpec spec) {
    final match = RegExp(
      r'^(\d+)d(\d+)([+-]\d+)?$',
    ).firstMatch(spec.expression);
    if (match == null) {
      throw RpgRuleViolation(
        'invalid_dice_expression',
        'Cannot execute dice expression `${spec.expression}`.',
      );
    }
    final count = int.parse(match.group(1)!);
    final sides = int.parse(match.group(2)!);
    final modifier = int.tryParse(match.group(3) ?? '') ?? 0;
    final values = <int>[];
    for (var index = 0; index < count; index++) {
      randomState = _nextRandomState(randomState);
      rollsConsumed++;
      values.add((randomState % sides) + 1);
    }
    return RpgDiceRoll(
      expression: spec.expression,
      values: List.unmodifiable(values),
      modifier: modifier,
    );
  }

  void adjustNumeric(String path, num delta) {
    final segments = path.split('.');
    if (segments.length == 2 && segments.first == 'attributes') {
      final current = attributes[segments.last];
      if (current == null) _missingNumericPath(path);
      attributes[segments.last] = current + delta;
      return;
    }
    if (segments.length == 2 && segments.first == 'variables') {
      final current = variables[segments.last];
      if (current is! num) _missingNumericPath(path);
      variables[segments.last] = current + delta;
      return;
    }
    if (segments.length == 3 &&
        segments.first == 'relationships' &&
        segments.last == 'score') {
      final current = relationships[segments[1]];
      if (current == null) _missingNumericPath(path);
      relationships[segments[1]] = RpgRelationshipState(
        actorId: current.actorId,
        score: current.score + delta,
        tags: current.tags,
      );
      return;
    }
    _missingNumericPath(path);
  }

  Never _missingNumericPath(String path) => throw RpgRuleViolation(
        'invalid_numeric_state',
        'State path `$path` does not contain a numeric value.',
        path: path,
      );

  void applyEffect(RpgEffect effect) {
    switch (effect.type) {
      case RpgEffectType.setValue:
        final segments = effect.target.split('.');
        if (segments.first == 'attributes') {
          final value = effect.value;
          if (value is! num || !value.isFinite) {
            throw RpgRuleViolation(
              'invalid_attribute_value',
              'Attribute `${segments.last}` requires a finite number.',
            );
          }
          attributes[segments.last] = value;
        } else {
          variables[segments.last] = effect.value;
        }
      case RpgEffectType.incrementValue:
        adjustNumeric(effect.target, effect.amount!);
      case RpgEffectType.decrementValue:
        adjustNumeric(effect.target, -effect.amount!);
      case RpgEffectType.addItem:
        final quantity = effect.amount!.toInt();
        final current = inventory[effect.target];
        inventory[effect.target] = RpgInventoryEntry(
          itemId: effect.target,
          quantity: (current?.quantity ?? 0) + quantity,
          metadata: current?.metadata ?? const {},
        );
      case RpgEffectType.removeItem:
        final quantity = effect.amount!.toInt();
        final current = inventory[effect.target];
        if (current == null || current.quantity < quantity) {
          throw RpgRuleViolation(
            'insufficient_item',
            'Cannot remove $quantity `${effect.target}` item(s).',
          );
        }
        final remaining = current.quantity - quantity;
        if (remaining == 0) {
          inventory.remove(effect.target);
        } else {
          inventory[effect.target] = RpgInventoryEntry(
            itemId: current.itemId,
            quantity: remaining,
            metadata: current.metadata,
          );
        }
      case RpgEffectType.adjustRelationship:
        final current = relationships[effect.target];
        relationships[effect.target] = RpgRelationshipState(
          actorId: effect.target,
          score: (current?.score ?? 0) + effect.amount!,
          tags: current?.tags ?? const [],
        );
      case RpgEffectType.moveTo:
        locationId = effect.target;
      case RpgEffectType.setQuestStatus:
        final current = quests[effect.target];
        quests[effect.target] = RpgQuestState(
          questId: effect.target,
          status: RpgQuestStatus.fromJson(effect.value! as String),
          stageId: current?.stageId,
          objectiveProgress: current?.objectiveProgress ?? const {},
        );
      case RpgEffectType.setCooldown:
        final turns = effect.amount!.toInt();
        if (turns == 0) {
          cooldowns.remove(effect.target);
        } else {
          cooldowns[effect.target] = turns;
        }
      case RpgEffectType.appendEvent:
        final value = effect.value;
        eventHistory.add(
          RpgEventRecord(
            id: _nextEventId('event_${turn + 1}_${eventHistory.length + 1}'),
            turn: turn + 1,
            type: effect.target,
            data: value is Map<String, Object?>
                ? Map.unmodifiable(value)
                : <String, Object?>{'value': value},
          ),
        );
    }
  }

  void appendTurnRecord({
    required RpgActionDefinition action,
    required RpgActionOutcome outcome,
    required List<RpgActionCost> costs,
    required RpgDiceRoll? roll,
    required num? checkTotal,
    required num? difficulty,
    required List<RpgEffect> appliedEffects,
  }) {
    eventHistory.add(
      RpgEventRecord(
        id: _nextEventId('turn_$turn'),
        turn: turn,
        type: 'actionResolved',
        actionId: action.id,
        summary: outcome == RpgActionOutcome.succeeded
            ? 'Action succeeded.'
            : 'Skill check failed.',
        data: {
          'outcome': outcome.name,
          if (costs.isNotEmpty)
            'costs': costs.map((cost) => cost.toJson()).toList(),
          if (roll != null) 'roll': roll.toJson(),
          if (checkTotal != null) 'checkTotal': checkTotal,
          if (difficulty != null) 'difficulty': difficulty,
          if (appliedEffects.isNotEmpty)
            'effects': appliedEffects.map((effect) => effect.toJson()).toList(),
        },
      ),
    );
  }

  String _nextEventId(String base) {
    final ids = eventHistory.map((event) => event.id).toSet();
    if (!ids.contains(base)) return base;
    var suffix = 2;
    while (ids.contains('${base}_$suffix')) {
      suffix++;
    }
    return '${base}_$suffix';
  }

  RpgRuntimeState build() => RpgRuntimeState(
        scenarioId: scenarioId,
        scenarioVersion: scenarioVersion,
        turn: turn,
        random: RpgRandomState(
          initialSeed: initialSeed,
          state: randomState,
          rollsConsumed: rollsConsumed,
        ),
        attributes: Map.unmodifiable(attributes),
        variables: Map.unmodifiable(variables),
        inventory: List.unmodifiable(inventory.values),
        relationships: List.unmodifiable(relationships.values),
        clock: clock,
        locationId: locationId,
        quests: List.unmodifiable(quests.values),
        cooldowns: Map.unmodifiable(cooldowns),
        eventHistory: List.unmodifiable(eventHistory),
      );
}

int _nextRandomState(int current) {
  const modulus = 2147483647;
  const multiplier = 48271;
  var normalized = current % (modulus - 1);
  if (normalized <= 0) normalized += modulus - 1;
  return (normalized * multiplier) % modulus;
}

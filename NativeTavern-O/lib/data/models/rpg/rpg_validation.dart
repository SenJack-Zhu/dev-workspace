import 'rpg_rules.dart';
import 'rpg_scenario.dart';
import 'rpg_state.dart';

class RpgValidationIssue {
  final String path;
  final String code;
  final String message;

  const RpgValidationIssue({
    required this.path,
    required this.code,
    required this.message,
  });

  @override
  String toString() => '$path [$code]: $message';
}

class RpgValidationResult {
  final List<RpgValidationIssue> issues;

  const RpgValidationResult(this.issues);

  bool get isValid => issues.isEmpty;

  void throwIfInvalid() {
    if (!isValid) throw RpgContractValidationException(issues);
  }
}

class RpgContractValidationException implements Exception {
  final List<RpgValidationIssue> issues;

  const RpgContractValidationException(this.issues);

  @override
  String toString() => 'Invalid RPG contract:\n${issues.join('\n')}';
}

class RpgScenarioValidator {
  static final RegExp _stableId = RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$');
  static final RegExp _semanticVersion = RegExp(
    r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$',
  );
  static final RegExp _diceExpression = RegExp(
    r'^([1-9][0-9]*)d([1-9][0-9]*)(?:[+-][0-9]+)?$',
  );

  const RpgScenarioValidator();

  RpgValidationResult validate(RpgScenario scenario) {
    final collector = _ValidationCollector();

    if (scenario.schemaVersion <= 0) {
      collector.add(
        'schemaVersion',
        'invalid_schema_version',
        'Schema version must be a positive integer.',
      );
    } else if (scenario.schemaVersion > RpgScenario.currentSchemaVersion) {
      collector.add(
        'schemaVersion',
        'unsupported_schema_version',
        'Schema version ${scenario.schemaVersion} is newer than supported '
            'version ${RpgScenario.currentSchemaVersion}.',
      );
    }

    _requireId(collector, 'metadata.id', scenario.metadata.id);
    _requireText(collector, 'metadata.name', scenario.metadata.name);
    _requireText(collector, 'metadata.version', scenario.metadata.version);
    _validateCompatibility(collector, scenario.compatibility);

    final attributeIds = _validateDefinitionIds(
      collector,
      'attributes',
      scenario.attributes.map((attribute) => attribute.id).toList(),
    );
    final itemIds = _validateDefinitionIds(
      collector,
      'items',
      scenario.items.map((item) => item.id).toList(),
    );
    final actorIds = _validateDefinitionIds(
      collector,
      'actors',
      scenario.actors.map((actor) => actor.id).toList(),
    );
    final locationIds = _validateDefinitionIds(
      collector,
      'locations',
      scenario.locations.map((location) => location.id).toList(),
    );
    final questIds = _validateDefinitionIds(
      collector,
      'quests',
      scenario.quests.map((quest) => quest.id).toList(),
    );
    final actionIds = _validateDefinitionIds(
      collector,
      'actions',
      scenario.actions.map((action) => action.id).toList(),
    );

    for (var index = 0; index < scenario.attributes.length; index++) {
      final attribute = scenario.attributes[index];
      final path = 'attributes[$index]';
      _requireText(collector, '$path.label', attribute.label);
      _requireFinite(collector, '$path.initialValue', attribute.initialValue);
      if (attribute.minimum case final minimum?) {
        _requireFinite(collector, '$path.minimum', minimum);
      }
      if (attribute.maximum case final maximum?) {
        _requireFinite(collector, '$path.maximum', maximum);
      }
      if (attribute.minimum != null &&
          attribute.maximum != null &&
          attribute.minimum! > attribute.maximum!) {
        collector.add(
          path,
          'invalid_range',
          'Minimum must not be greater than maximum.',
        );
      }
      if (attribute.minimum != null &&
          attribute.initialValue < attribute.minimum!) {
        collector.add(
          '$path.initialValue',
          'out_of_range',
          'Initial value is below ${attribute.minimum}.',
        );
      }
      if (attribute.maximum != null &&
          attribute.initialValue > attribute.maximum!) {
        collector.add(
          '$path.initialValue',
          'out_of_range',
          'Initial value is above ${attribute.maximum}.',
        );
      }
    }

    for (var index = 0; index < scenario.items.length; index++) {
      _requireText(
        collector,
        'items[$index].label',
        scenario.items[index].label,
      );
    }
    for (var index = 0; index < scenario.actors.length; index++) {
      _requireText(
        collector,
        'actors[$index].label',
        scenario.actors[index].label,
      );
    }
    for (var index = 0; index < scenario.locations.length; index++) {
      _requireText(
        collector,
        'locations[$index].label',
        scenario.locations[index].label,
      );
    }

    final questStages = <String, Set<String>>{};
    final questObjectives = <String, Set<String>>{};
    for (var questIndex = 0;
        questIndex < scenario.quests.length;
        questIndex++) {
      final quest = scenario.quests[questIndex];
      final questPath = 'quests[$questIndex]';
      _requireText(collector, '$questPath.label', quest.label);
      final stageIds = _validateDefinitionIds(
        collector,
        '$questPath.stages',
        quest.stages.map((stage) => stage.id).toList(),
      );
      final objectiveIds = <String>{};
      for (var stageIndex = 0; stageIndex < quest.stages.length; stageIndex++) {
        final stage = quest.stages[stageIndex];
        final stagePath = '$questPath.stages[$stageIndex]';
        _requireText(collector, '$stagePath.label', stage.label);
        for (var objectiveIndex = 0;
            objectiveIndex < stage.objectiveIds.length;
            objectiveIndex++) {
          final objectiveId = stage.objectiveIds[objectiveIndex];
          final objectivePath = '$stagePath.objectiveIds[$objectiveIndex]';
          _requireId(collector, objectivePath, objectiveId);
          if (!objectiveIds.add(objectiveId)) {
            collector.add(
              objectivePath,
              'duplicate_id',
              'Objective ID `$objectiveId` is duplicated in quest `${quest.id}`.',
            );
          }
        }
      }
      questStages[quest.id] = stageIds;
      questObjectives[quest.id] = objectiveIds;
    }

    for (var index = 0; index < scenario.protectedFields.length; index++) {
      final field = scenario.protectedFields[index];
      if (!_isKnownStatePath(
        field,
        attributeIds: attributeIds,
        itemIds: itemIds,
        actorIds: actorIds,
        questIds: questIds,
        actionIds: actionIds,
        allowCollectionRoot: true,
      )) {
        collector.add(
          'protectedFields[$index]',
          'unknown_protected_field',
          'Protected field `$field` is not a recognized state path.',
        );
      }
    }

    for (var index = 0; index < scenario.actions.length; index++) {
      _validateAction(
        collector,
        scenario.actions[index],
        'actions[$index]',
        attributeIds: attributeIds,
        itemIds: itemIds,
        actorIds: actorIds,
        locationIds: locationIds,
        questIds: questIds,
        actionIds: actionIds,
      );
    }

    _validateRuntimeState(
      collector,
      scenario.initialState,
      'initialState',
      scenario: scenario,
      attributeIds: attributeIds,
      itemIds: itemIds,
      actorIds: actorIds,
      locationIds: locationIds,
      questIds: questIds,
      actionIds: actionIds,
      questStages: questStages,
      questObjectives: questObjectives,
    );

    return RpgValidationResult(List.unmodifiable(collector.issues));
  }

  RpgValidationResult validatePatch(RpgScenario scenario, RpgStatePatch patch) {
    final collector = _ValidationCollector();
    final attributeIds = scenario.attributes.map((item) => item.id).toSet();
    final itemIds = scenario.items.map((item) => item.id).toSet();
    final actorIds = scenario.actors.map((item) => item.id).toSet();
    final locationIds = scenario.locations.map((item) => item.id).toSet();
    final questIds = scenario.quests.map((item) => item.id).toSet();
    final actionIds = scenario.actions.map((item) => item.id).toSet();

    for (var index = 0; index < patch.effects.length; index++) {
      final effect = patch.effects[index];
      final path = 'effects[$index]';
      _validateEffect(
        collector,
        effect,
        path,
        attributeIds: attributeIds,
        itemIds: itemIds,
        actorIds: actorIds,
        locationIds: locationIds,
        questIds: questIds,
        actionIds: actionIds,
      );
      final statePath = _effectStatePath(effect);
      if (patch.source == RpgMutationSource.narrative &&
          scenario.protectedFields.any(
            (protected) => _pathsIntersect(protected, statePath),
          )) {
        collector.add(
          path,
          'protected_state_mutation',
          'Narrative patches cannot mutate protected state `$statePath`.',
        );
      }
    }
    return RpgValidationResult(List.unmodifiable(collector.issues));
  }

  /// Validates a resumed or newly produced runtime state against its scenario.
  RpgValidationResult validateRuntimeState(
    RpgScenario scenario,
    RpgRuntimeState state,
  ) {
    final collector = _ValidationCollector();
    final attributeIds = scenario.attributes.map((item) => item.id).toSet();
    final itemIds = scenario.items.map((item) => item.id).toSet();
    final actorIds = scenario.actors.map((item) => item.id).toSet();
    final locationIds = scenario.locations.map((item) => item.id).toSet();
    final questIds = scenario.quests.map((item) => item.id).toSet();
    final actionIds = scenario.actions.map((item) => item.id).toSet();
    final questStages = <String, Set<String>>{
      for (final quest in scenario.quests)
        quest.id: quest.stages.map((stage) => stage.id).toSet(),
    };
    final questObjectives = <String, Set<String>>{
      for (final quest in scenario.quests)
        quest.id: quest.stages.expand((stage) => stage.objectiveIds).toSet(),
    };

    _validateRuntimeState(
      collector,
      state,
      'state',
      scenario: scenario,
      attributeIds: attributeIds,
      itemIds: itemIds,
      actorIds: actorIds,
      locationIds: locationIds,
      questIds: questIds,
      actionIds: actionIds,
      questStages: questStages,
      questObjectives: questObjectives,
    );
    return RpgValidationResult(List.unmodifiable(collector.issues));
  }

  RpgValidationResult validateSnapshot(
    RpgScenario scenario,
    RpgStateSnapshot snapshot,
  ) {
    final collector = _ValidationCollector();
    final metadata = snapshot.metadata;
    _requireId(collector, 'metadata.id', metadata.id);
    _requireId(collector, 'metadata.branchId', metadata.branchId);
    if (metadata.parentSnapshotId == metadata.id) {
      collector.add(
        'metadata.parentSnapshotId',
        'self_reference',
        'A snapshot cannot be its own parent.',
      );
    }
    if (metadata.scenarioId != scenario.metadata.id ||
        metadata.scenarioVersion != scenario.metadata.version) {
      collector.add(
        'metadata',
        'scenario_mismatch',
        'Snapshot metadata must target `${scenario.metadata.id}` version '
            '`${scenario.metadata.version}`.',
      );
    }
    if (metadata.turn != snapshot.state.turn ||
        metadata.randomState != snapshot.state.random.state ||
        metadata.rollsConsumed != snapshot.state.random.rollsConsumed) {
      collector.add(
        'metadata',
        'determinism_mismatch',
        'Snapshot metadata must match the persisted turn and random state.',
      );
    }
    return RpgValidationResult(List.unmodifiable(collector.issues));
  }

  void _validateCompatibility(
    _ValidationCollector collector,
    RpgCompatibility compatibility,
  ) {
    if (!_semanticVersion.hasMatch(compatibility.minimumEngineVersion)) {
      collector.add(
        'compatibility.minimumEngineVersion',
        'invalid_version',
        'Minimum engine version must use semantic versioning (for example 1.0.0).',
      );
    }
    final maximum = compatibility.maximumEngineVersion;
    if (maximum != null && !_semanticVersion.hasMatch(maximum)) {
      collector.add(
        'compatibility.maximumEngineVersion',
        'invalid_version',
        'Maximum engine version must use semantic versioning.',
      );
    }
    _validateDefinitionIds(
      collector,
      'compatibility.requiredCapabilities',
      compatibility.requiredCapabilities,
    );
  }

  void _validateAction(
    _ValidationCollector collector,
    RpgActionDefinition action,
    String path, {
    required Set<String> attributeIds,
    required Set<String> itemIds,
    required Set<String> actorIds,
    required Set<String> locationIds,
    required Set<String> questIds,
    required Set<String> actionIds,
  }) {
    _requireText(collector, '$path.label', action.label);
    for (var index = 0; index < action.availability.length; index++) {
      _validateCondition(
        collector,
        action.availability[index],
        '$path.availability[$index]',
        attributeIds: attributeIds,
        itemIds: itemIds,
        actorIds: actorIds,
        questIds: questIds,
        actionIds: actionIds,
      );
    }
    for (var index = 0; index < action.costs.length; index++) {
      final cost = action.costs[index];
      final costPath = '$path.costs[$index]';
      if (!_isNumericPath(
        cost.path,
        attributeIds: attributeIds,
        actorIds: actorIds,
      )) {
        collector.add(
          '$costPath.path',
          'invalid_cost_path',
          'Cost path `${cost.path}` is not a known numeric state field.',
        );
      }
      if (!cost.amount.isFinite || cost.amount <= 0) {
        collector.add(
          '$costPath.amount',
          'invalid_cost',
          'Action cost must be a positive finite number.',
        );
      }
    }
    final check = action.check;
    if (check != null) {
      final checkPath = '$path.check';
      if (!attributeIds.contains(check.attributeId)) {
        collector.add(
          '$checkPath.attributeId',
          'invalid_reference',
          'Unknown attribute `${check.attributeId}`.',
        );
      }
      if (!_diceExpression.hasMatch(check.dice.expression)) {
        collector.add(
          '$checkPath.dice.expression',
          'invalid_dice_expression',
          'Use canonical NdM notation with an optional modifier, such as 2d6+3.',
        );
      }
      _requireFinite(collector, '$checkPath.difficulty', check.difficulty);
      _validateEffects(
        collector,
        check.successEffects,
        '$checkPath.successEffects',
        attributeIds: attributeIds,
        itemIds: itemIds,
        actorIds: actorIds,
        locationIds: locationIds,
        questIds: questIds,
        actionIds: actionIds,
      );
      _validateEffects(
        collector,
        check.failureEffects,
        '$checkPath.failureEffects',
        attributeIds: attributeIds,
        itemIds: itemIds,
        actorIds: actorIds,
        locationIds: locationIds,
        questIds: questIds,
        actionIds: actionIds,
      );
    }
    _validateEffects(
      collector,
      action.effects,
      '$path.effects',
      attributeIds: attributeIds,
      itemIds: itemIds,
      actorIds: actorIds,
      locationIds: locationIds,
      questIds: questIds,
      actionIds: actionIds,
    );
  }

  void _validateCondition(
    _ValidationCollector collector,
    RpgCondition condition,
    String path, {
    required Set<String> attributeIds,
    required Set<String> itemIds,
    required Set<String> actorIds,
    required Set<String> questIds,
    required Set<String> actionIds,
  }) {
    final isGroup = condition.operator == RpgConditionOperator.all ||
        condition.operator == RpgConditionOperator.any ||
        condition.operator == RpgConditionOperator.not;
    if (isGroup) {
      final expectedCount =
          condition.operator == RpgConditionOperator.not ? 1 : 0;
      if (condition.conditions.isEmpty ||
          (expectedCount == 1 && condition.conditions.length != 1)) {
        collector.add(
          '$path.conditions',
          'invalid_condition_group',
          condition.operator == RpgConditionOperator.not
              ? '`not` requires exactly one nested condition.'
              : '`${condition.operator.name}` requires nested conditions.',
        );
      }
      if (condition.path != null || condition.value != null) {
        collector.add(
          path,
          'invalid_condition_shape',
          'Grouped conditions cannot declare path or value.',
        );
      }
      for (var index = 0; index < condition.conditions.length; index++) {
        _validateCondition(
          collector,
          condition.conditions[index],
          '$path.conditions[$index]',
          attributeIds: attributeIds,
          itemIds: itemIds,
          actorIds: actorIds,
          questIds: questIds,
          actionIds: actionIds,
        );
      }
      return;
    }

    if (condition.conditions.isNotEmpty) {
      collector.add(
        '$path.conditions',
        'invalid_condition_shape',
        'Leaf conditions cannot have nested conditions.',
      );
    }
    final statePath = condition.path;
    if (statePath == null ||
        !_isKnownStatePath(
          statePath,
          attributeIds: attributeIds,
          itemIds: itemIds,
          actorIds: actorIds,
          questIds: questIds,
          actionIds: actionIds,
        )) {
      collector.add(
        '$path.path',
        'invalid_state_path',
        'Condition path `${statePath ?? ''}` is not recognized.',
      );
    }
    if (condition.operator != RpgConditionOperator.exists &&
        condition.value == null) {
      collector.add(
        '$path.value',
        'missing_condition_value',
        '`${condition.operator.name}` requires a comparison value.',
      );
    } else if (!_isJsonValue(condition.value)) {
      collector.add(
        '$path.value',
        'non_json_value',
        'Condition value must be JSON-compatible data.',
      );
    }
  }

  void _validateEffects(
    _ValidationCollector collector,
    List<RpgEffect> effects,
    String path, {
    required Set<String> attributeIds,
    required Set<String> itemIds,
    required Set<String> actorIds,
    required Set<String> locationIds,
    required Set<String> questIds,
    required Set<String> actionIds,
  }) {
    for (var index = 0; index < effects.length; index++) {
      _validateEffect(
        collector,
        effects[index],
        '$path[$index]',
        attributeIds: attributeIds,
        itemIds: itemIds,
        actorIds: actorIds,
        locationIds: locationIds,
        questIds: questIds,
        actionIds: actionIds,
      );
    }
  }

  void _validateEffect(
    _ValidationCollector collector,
    RpgEffect effect,
    String path, {
    required Set<String> attributeIds,
    required Set<String> itemIds,
    required Set<String> actorIds,
    required Set<String> locationIds,
    required Set<String> questIds,
    required Set<String> actionIds,
  }) {
    switch (effect.type) {
      case RpgEffectType.setValue:
        if (!_isWritableValuePath(effect.target, attributeIds)) {
          _invalidTarget(collector, path, effect);
        }
        if (effect.value == null || !_isJsonValue(effect.value)) {
          collector.add(
            '$path.value',
            'invalid_effect_value',
            '`setValue` requires a JSON-compatible value.',
          );
        }
      case RpgEffectType.incrementValue:
      case RpgEffectType.decrementValue:
        if (!_isNumericPath(
          effect.target,
          attributeIds: attributeIds,
          actorIds: actorIds,
        )) {
          _invalidTarget(collector, path, effect);
        }
        _requirePositiveAmount(collector, path, effect);
      case RpgEffectType.addItem:
      case RpgEffectType.removeItem:
        if (!itemIds.contains(effect.target)) {
          _invalidReference(collector, path, 'item', effect.target);
        }
        _requirePositiveIntegerAmount(collector, path, effect);
      case RpgEffectType.adjustRelationship:
        if (!actorIds.contains(effect.target)) {
          _invalidReference(collector, path, 'actor', effect.target);
        }
        _requireFiniteAmount(collector, path, effect);
      case RpgEffectType.moveTo:
        if (!locationIds.contains(effect.target)) {
          _invalidReference(collector, path, 'location', effect.target);
        }
      case RpgEffectType.setQuestStatus:
        if (!questIds.contains(effect.target)) {
          _invalidReference(collector, path, 'quest', effect.target);
        }
        final status = effect.value;
        if (status is! String ||
            !RpgQuestStatus.values.any((item) => item.name == status)) {
          collector.add(
            '$path.value',
            'invalid_quest_status',
            'Quest status must be one of: '
                '${RpgQuestStatus.values.map((item) => item.name).join(', ')}.',
          );
        }
      case RpgEffectType.setCooldown:
        if (!actionIds.contains(effect.target)) {
          _invalidReference(collector, path, 'action', effect.target);
        }
        final amount = effect.amount;
        if (amount == null || amount != amount.toInt() || amount < 0) {
          collector.add(
            '$path.amount',
            'invalid_cooldown',
            'Cooldown must be a non-negative integer.',
          );
        }
      case RpgEffectType.appendEvent:
        if (effect.target.trim().isEmpty) {
          collector.add(
            '$path.target',
            'missing_event_type',
            'Appended events require a non-empty event type.',
          );
        }
        if (!_isJsonValue(effect.value)) {
          collector.add(
            '$path.value',
            'non_json_value',
            'Event data must be JSON-compatible.',
          );
        }
    }
  }

  void _validateRuntimeState(
    _ValidationCollector collector,
    RpgRuntimeState state,
    String path, {
    required RpgScenario scenario,
    required Set<String> attributeIds,
    required Set<String> itemIds,
    required Set<String> actorIds,
    required Set<String> locationIds,
    required Set<String> questIds,
    required Set<String> actionIds,
    required Map<String, Set<String>> questStages,
    required Map<String, Set<String>> questObjectives,
  }) {
    if (state.scenarioId != scenario.metadata.id) {
      collector.add(
        '$path.scenarioId',
        'scenario_mismatch',
        'Expected scenario ID `${scenario.metadata.id}`.',
      );
    }
    if (state.scenarioVersion != scenario.metadata.version) {
      collector.add(
        '$path.scenarioVersion',
        'scenario_version_mismatch',
        'Expected scenario version `${scenario.metadata.version}`.',
      );
    }
    if (state.turn < 0) {
      collector.add('$path.turn', 'negative_value', 'Turn cannot be negative.');
    }
    if (state.random.initialSeed != scenario.initialSeed) {
      collector.add(
        '$path.random.initialSeed',
        'seed_mismatch',
        'Runtime seed must match scenario initialSeed ${scenario.initialSeed}.',
      );
    }
    if (state.random.rollsConsumed < 0) {
      collector.add(
        '$path.random.rollsConsumed',
        'negative_value',
        'Consumed roll count cannot be negative.',
      );
    }

    final definitions = {for (final item in scenario.attributes) item.id: item};
    for (final entry in state.attributes.entries) {
      final valuePath = '$path.attributes.${entry.key}';
      final definition = definitions[entry.key];
      if (definition == null) {
        _invalidReference(collector, valuePath, 'attribute', entry.key);
        continue;
      }
      _requireFinite(collector, valuePath, entry.value);
      if (definition.minimum != null && entry.value < definition.minimum!) {
        collector.add(
          valuePath,
          'out_of_range',
          'Value is below ${definition.minimum}.',
        );
      }
      if (definition.maximum != null && entry.value > definition.maximum!) {
        collector.add(
          valuePath,
          'out_of_range',
          'Value is above ${definition.maximum}.',
        );
      }
    }
    for (final entry in state.variables.entries) {
      if (!_stableId.hasMatch(entry.key)) {
        collector.add(
          '$path.variables.${entry.key}',
          'invalid_id',
          'Variable keys must use stable ID syntax.',
        );
      }
      if (!_isJsonValue(entry.value)) {
        collector.add(
          '$path.variables.${entry.key}',
          'non_json_value',
          'Variable value must be JSON-compatible.',
        );
      }
    }

    final inventoryIds = <String>{};
    final itemDefinitions = {for (final item in scenario.items) item.id: item};
    for (var index = 0; index < state.inventory.length; index++) {
      final entry = state.inventory[index];
      final entryPath = '$path.inventory[$index]';
      final definition = itemDefinitions[entry.itemId];
      if (definition == null) {
        _invalidReference(collector, '$entryPath.itemId', 'item', entry.itemId);
      }
      if (!inventoryIds.add(entry.itemId)) {
        collector.add(
          '$entryPath.itemId',
          'duplicate_id',
          'Inventory item `${entry.itemId}` appears more than once.',
        );
      }
      if (entry.quantity < 0) {
        collector.add(
          '$entryPath.quantity',
          'negative_quantity',
          'Inventory quantity cannot be negative.',
        );
      }
      if (definition != null && !definition.stackable && entry.quantity > 1) {
        collector.add(
          '$entryPath.quantity',
          'non_stackable_quantity',
          'Non-stackable item `${entry.itemId}` cannot have quantity above 1.',
        );
      }
      if (!_isJsonValue(entry.metadata)) {
        collector.add(
          '$entryPath.metadata',
          'non_json_value',
          'Item metadata must be JSON-compatible.',
        );
      }
    }

    final relationshipIds = <String>{};
    for (var index = 0; index < state.relationships.length; index++) {
      final relationship = state.relationships[index];
      final relationshipPath = '$path.relationships[$index]';
      if (!actorIds.contains(relationship.actorId)) {
        _invalidReference(
          collector,
          '$relationshipPath.actorId',
          'actor',
          relationship.actorId,
        );
      }
      if (!relationshipIds.add(relationship.actorId)) {
        collector.add(
          '$relationshipPath.actorId',
          'duplicate_id',
          'Relationship actor `${relationship.actorId}` appears more than once.',
        );
      }
      _requireFinite(collector, '$relationshipPath.score', relationship.score);
    }

    if (state.clock.elapsedMinutes < 0 ||
        state.clock.day < 1 ||
        state.clock.minuteOfDay < 0 ||
        state.clock.minuteOfDay >= 1440) {
      collector.add(
        '$path.clock',
        'invalid_clock',
        'Clock requires non-negative elapsed minutes, day >= 1, and '
            'minuteOfDay from 0 through 1439.',
      );
    }
    if (state.locationId.isNotEmpty &&
        !locationIds.contains(state.locationId)) {
      _invalidReference(
        collector,
        '$path.locationId',
        'location',
        state.locationId,
      );
    }

    final runtimeQuestIds = <String>{};
    for (var index = 0; index < state.quests.length; index++) {
      final quest = state.quests[index];
      final questPath = '$path.quests[$index]';
      if (!questIds.contains(quest.questId)) {
        _invalidReference(
          collector,
          '$questPath.questId',
          'quest',
          quest.questId,
        );
      }
      if (!runtimeQuestIds.add(quest.questId)) {
        collector.add(
          '$questPath.questId',
          'duplicate_id',
          'Quest state `${quest.questId}` appears more than once.',
        );
      }
      if (quest.stageId != null &&
          !(questStages[quest.questId]?.contains(quest.stageId) ?? false)) {
        _invalidReference(
          collector,
          '$questPath.stageId',
          'quest stage',
          quest.stageId!,
        );
      }
      for (final objective in quest.objectiveProgress.entries) {
        final objectivePath = '$questPath.objectiveProgress.${objective.key}';
        if (!(questObjectives[quest.questId]?.contains(objective.key) ??
            false)) {
          _invalidReference(
            collector,
            objectivePath,
            'quest objective',
            objective.key,
          );
        }
        if (objective.value < 0) {
          collector.add(
            objectivePath,
            'negative_quantity',
            'Objective progress cannot be negative.',
          );
        }
      }
    }

    for (final cooldown in state.cooldowns.entries) {
      final cooldownPath = '$path.cooldowns.${cooldown.key}';
      if (!actionIds.contains(cooldown.key)) {
        _invalidReference(collector, cooldownPath, 'action', cooldown.key);
      }
      if (cooldown.value < 0) {
        collector.add(
          cooldownPath,
          'negative_quantity',
          'Cooldown turns cannot be negative.',
        );
      }
    }

    final eventIds = <String>{};
    for (var index = 0; index < state.eventHistory.length; index++) {
      final event = state.eventHistory[index];
      final eventPath = '$path.eventHistory[$index]';
      _requireId(collector, '$eventPath.id', event.id);
      if (!eventIds.add(event.id)) {
        collector.add(
          '$eventPath.id',
          'duplicate_id',
          'Event ID `${event.id}` appears more than once.',
        );
      }
      if (event.turn < 0 || event.turn > state.turn) {
        collector.add(
          '$eventPath.turn',
          'invalid_event_turn',
          'Event turn must be between 0 and the current turn ${state.turn}.',
        );
      }
      if (event.actionId != null && !actionIds.contains(event.actionId)) {
        _invalidReference(
          collector,
          '$eventPath.actionId',
          'action',
          event.actionId!,
        );
      }
      _requireText(collector, '$eventPath.type', event.type);
      if (!_isJsonValue(event.data)) {
        collector.add(
          '$eventPath.data',
          'non_json_value',
          'Event data must be JSON-compatible.',
        );
      }
    }
  }

  Set<String> _validateDefinitionIds(
    _ValidationCollector collector,
    String path,
    List<String> ids,
  ) {
    final seen = <String>{};
    for (var index = 0; index < ids.length; index++) {
      final id = ids[index];
      _requireId(collector, '$path[$index].id', id);
      if (!seen.add(id)) {
        collector.add(
          '$path[$index].id',
          'duplicate_id',
          'Stable ID `$id` is duplicated in `$path`.',
        );
      }
    }
    return seen;
  }

  bool _isKnownStatePath(
    String path, {
    required Set<String> attributeIds,
    required Set<String> itemIds,
    required Set<String> actorIds,
    required Set<String> questIds,
    required Set<String> actionIds,
    bool allowCollectionRoot = false,
  }) {
    const scalarPaths = <String>{
      'turn',
      'random.initialSeed',
      'random.state',
      'random.rollsConsumed',
      'clock.elapsedMinutes',
      'clock.day',
      'clock.minuteOfDay',
      'locationId',
    };
    if (scalarPaths.contains(path)) return true;
    if (allowCollectionRoot &&
        const <String>{
          'attributes',
          'variables',
          'inventory',
          'relationships',
          'clock',
          'quests',
          'cooldowns',
          'eventHistory',
        }.contains(path)) {
      return true;
    }
    final segments = path.split('.');
    if (segments.length == 2) {
      return switch (segments.first) {
        'attributes' => attributeIds.contains(segments.last),
        'variables' => _stableId.hasMatch(segments.last),
        'cooldowns' => actionIds.contains(segments.last),
        _ => false,
      };
    }
    if (segments.length == 3) {
      return switch (segments.first) {
        'inventory' =>
          itemIds.contains(segments[1]) && segments.last == 'quantity',
        'relationships' =>
          actorIds.contains(segments[1]) && segments.last == 'score',
        'quests' => questIds.contains(segments[1]) &&
            const <String>{'status', 'stageId'}.contains(segments.last),
        _ => false,
      };
    }
    return false;
  }

  bool _isNumericPath(
    String path, {
    required Set<String> attributeIds,
    required Set<String> actorIds,
  }) {
    final segments = path.split('.');
    if (segments.length == 2) {
      return (segments.first == 'attributes' &&
              attributeIds.contains(segments.last)) ||
          (segments.first == 'variables' && _stableId.hasMatch(segments.last));
    }
    return segments.length == 3 &&
        segments.first == 'relationships' &&
        actorIds.contains(segments[1]) &&
        segments.last == 'score';
  }

  bool _isWritableValuePath(String path, Set<String> attributeIds) {
    final segments = path.split('.');
    return segments.length == 2 &&
        ((segments.first == 'attributes' &&
                attributeIds.contains(segments.last)) ||
            (segments.first == 'variables' &&
                _stableId.hasMatch(segments.last)));
  }

  String _effectStatePath(RpgEffect effect) => switch (effect.type) {
        RpgEffectType.setValue ||
        RpgEffectType.incrementValue ||
        RpgEffectType.decrementValue =>
          effect.target,
        RpgEffectType.addItem ||
        RpgEffectType.removeItem =>
          'inventory.${effect.target}.quantity',
        RpgEffectType.adjustRelationship =>
          'relationships.${effect.target}.score',
        RpgEffectType.moveTo => 'locationId',
        RpgEffectType.setQuestStatus => 'quests.${effect.target}.status',
        RpgEffectType.setCooldown => 'cooldowns.${effect.target}',
        RpgEffectType.appendEvent => 'eventHistory',
      };

  bool _pathsIntersect(String protected, String target) =>
      protected == target ||
      target.startsWith('$protected.') ||
      protected.startsWith('$target.');

  bool _isJsonValue(Object? value) {
    if (value == null || value is String || value is bool) return true;
    if (value is num) return value.isFinite;
    if (value is List<Object?>) return value.every(_isJsonValue);
    if (value is Map<String, Object?>) {
      return value.values.every(_isJsonValue);
    }
    return false;
  }

  void _requireId(_ValidationCollector collector, String path, String id) {
    if (!_stableId.hasMatch(id)) {
      collector.add(
        path,
        'invalid_id',
        'Stable IDs must start with a letter and contain only letters, '
            'digits, `_`, or `-`.',
      );
    }
  }

  void _requireText(_ValidationCollector collector, String path, String value) {
    if (value.trim().isEmpty) {
      collector.add(path, 'required', 'A non-empty value is required.');
    }
  }

  void _requireFinite(_ValidationCollector collector, String path, num value) {
    if (!value.isFinite) {
      collector.add(path, 'not_finite', 'Value must be a finite number.');
    }
  }

  void _requirePositiveAmount(
    _ValidationCollector collector,
    String path,
    RpgEffect effect,
  ) {
    final amount = effect.amount;
    if (amount == null || !amount.isFinite || amount <= 0) {
      collector.add(
        '$path.amount',
        'invalid_amount',
        'Effect amount must be a positive finite number.',
      );
    }
  }

  void _requireFiniteAmount(
    _ValidationCollector collector,
    String path,
    RpgEffect effect,
  ) {
    if (effect.amount == null || !effect.amount!.isFinite) {
      collector.add(
        '$path.amount',
        'invalid_amount',
        'Effect amount must be a finite number.',
      );
    }
  }

  void _requirePositiveIntegerAmount(
    _ValidationCollector collector,
    String path,
    RpgEffect effect,
  ) {
    final amount = effect.amount;
    if (amount == null || amount != amount.toInt() || amount <= 0) {
      collector.add(
        '$path.amount',
        'invalid_quantity',
        'Item quantity must be a positive integer.',
      );
    }
  }

  void _invalidTarget(
    _ValidationCollector collector,
    String path,
    RpgEffect effect,
  ) {
    collector.add(
      '$path.target',
      'invalid_effect_target',
      '`${effect.target}` is not valid for `${effect.type.name}`.',
    );
  }

  void _invalidReference(
    _ValidationCollector collector,
    String path,
    String kind,
    String id,
  ) {
    collector.add(path, 'invalid_reference', 'Unknown $kind ID `$id`.');
  }
}

class _ValidationCollector {
  final List<RpgValidationIssue> issues = [];

  void add(String path, String code, String message) {
    issues.add(RpgValidationIssue(path: path, code: code, message: message));
  }
}

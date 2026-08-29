import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';

void main() {
  const validator = RpgScenarioValidator();

  group('RPG scenario JSON contract', () {
    test('minimal scenario round-trips with compatibility defaults', () {
      final original = _minimalScenario();
      final decoded = RpgScenario.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.toJson(), original.toJson());
      expect(decoded.schemaVersion, RpgScenario.currentSchemaVersion);
      expect(
        decoded.compatibility.minimumEngineVersion,
        RpgCompatibility.defaultEngineVersion,
      );
      expect(decoded.compatibility.requiredCapabilities, isEmpty);
      expect(validator.validate(decoded).isValid, isTrue);
    });

    test('representative full scenario preserves every deterministic input',
        () {
      final original = _fullScenario();
      final decoded = RpgScenario.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      final result = validator.validate(decoded);

      expect(result.issues, isEmpty);
      expect(decoded.toJson(), original.toJson());
      expect(decoded.initialState.random.initialSeed, 424242);
      expect(decoded.initialState.random.state, 918273645);
      expect(decoded.initialState.random.rollsConsumed, 7);
      expect(decoded.initialState.turn, 12);
      expect(decoded.initialState.inventory.single.quantity, 2);
      expect(decoded.initialState.relationships.single.score, 15);
      expect(decoded.initialState.quests.single.status, RpgQuestStatus.active);
      expect(decoded.initialState.cooldowns['explore'], 2);
    });

    test('actions serialize only typed declarative conditions and effects', () {
      final action = _fullScenario().actions.single;
      final encoded = action.toJson();
      final condition = (encoded['availability'] as List<dynamic>).single
          as Map<String, dynamic>;
      final effect =
          (encoded['effects'] as List<dynamic>).single as Map<String, dynamic>;

      expect(condition.keys, unorderedEquals(['operator', 'path', 'value']));
      expect(effect.keys, unorderedEquals(['type', 'target', 'amount']));
      expect(jsonEncode(encoded), isNot(contains('script')));
      expect(jsonEncode(encoded), isNot(contains('source')));
    });
  });

  group('RPG scenario validation', () {
    test('reports duplicate IDs, invalid references, quantities, and dice', () {
      const invalid = RpgScenario(
        metadata: RpgScenarioMetadata(
          id: 'invalid_scenario',
          name: 'Invalid scenario',
          version: '1.0.0',
        ),
        initialSeed: 7,
        protectedFields: ['random.state', 'madeUpField'],
        attributes: [
          RpgAttributeDefinition(id: 'power', label: 'Power'),
          RpgAttributeDefinition(id: 'power', label: 'Power again'),
        ],
        items: [RpgItemDefinition(id: 'potion', label: 'Potion')],
        actions: [
          RpgActionDefinition(
            id: 'roll',
            label: 'Roll',
            check: RpgSkillCheck(
              attributeId: 'missing_attribute',
              dice: RpgDiceSpec('twenty-sided-die'),
              difficulty: 10,
            ),
            effects: [
              RpgEffect(
                type: RpgEffectType.addItem,
                target: 'missing_item',
                amount: 1,
              ),
            ],
          ),
        ],
        initialState: RpgRuntimeState(
          scenarioId: 'invalid_scenario',
          scenarioVersion: '1.0.0',
          random: RpgRandomState(initialSeed: 7, state: 7),
          inventory: [
            RpgInventoryEntry(itemId: 'missing_item', quantity: -1),
          ],
          relationships: [RpgRelationshipState(actorId: 'missing_actor')],
          locationId: 'missing_location',
          quests: [RpgQuestState(questId: 'missing_quest')],
          cooldowns: {'missing_action': -3},
        ),
      );

      final result = validator.validate(invalid);
      final codes = result.issues.map((issue) => issue.code).toSet();

      expect(result.isValid, isFalse);
      expect(codes, contains('duplicate_id'));
      expect(codes, contains('invalid_reference'));
      expect(codes, contains('negative_quantity'));
      expect(codes, contains('invalid_dice_expression'));
      expect(codes, contains('unknown_protected_field'));
      expect(
        result.issues.any(
          (issue) =>
              issue.path == 'actions[0].check.dice.expression' &&
              issue.message.contains('2d6+3'),
        ),
        isTrue,
      );
    });

    test('requires stable scenario and definition IDs', () {
      const invalid = RpgScenario(
        metadata: RpgScenarioMetadata(
          id: '',
          name: 'No IDs',
          version: '1.0.0',
        ),
        initialSeed: 1,
        attributes: [
          RpgAttributeDefinition(id: 'not valid', label: 'Broken'),
        ],
        initialState: RpgRuntimeState(
          scenarioId: '',
          scenarioVersion: '1.0.0',
          random: RpgRandomState(initialSeed: 1, state: 1),
        ),
      );

      final issues = validator.validate(invalid).issues;

      expect(
        issues.where((issue) => issue.code == 'invalid_id'),
        hasLength(greaterThanOrEqualTo(2)),
      );
    });

    test('rejects narrative changes to protected state', () {
      final scenario = _fullScenario();
      const patch = RpgStatePatch(
        source: RpgMutationSource.narrative,
        effects: [
          RpgEffect(
            type: RpgEffectType.removeItem,
            target: 'potion',
            amount: 1,
          ),
        ],
      );

      final result = validator.validatePatch(scenario, patch);

      expect(result.isValid, isFalse);
      expect(result.issues.single.code, 'protected_state_mutation');
      expect(
          result.issues.single.message, contains('inventory.potion.quantity'));
    });

    test('allows the rule engine to apply a valid protected-state effect', () {
      final scenario = _fullScenario();
      const patch = RpgStatePatch(
        source: RpgMutationSource.ruleEngine,
        effects: [
          RpgEffect(
            type: RpgEffectType.removeItem,
            target: 'potion',
            amount: 1,
          ),
        ],
      );

      expect(validator.validatePatch(scenario, patch).issues, isEmpty);
    });
  });

  group('RPG snapshots', () {
    test('round-trip keeps rollback and branch inheritance metadata', () {
      final scenario = _fullScenario();
      final snapshot = RpgStateSnapshot(
        metadata: RpgSnapshotMetadata(
          id: 'snapshot_12',
          scenarioId: scenario.metadata.id,
          scenarioVersion: scenario.metadata.version,
          branchId: 'main_branch',
          parentSnapshotId: 'snapshot_08',
          turn: scenario.initialState.turn,
          randomState: scenario.initialState.random.state,
          rollsConsumed: scenario.initialState.random.rollsConsumed,
          createdAt: DateTime.utc(2026, 8, 7, 10, 30),
          stateHash: 'sha256:example',
        ),
        state: scenario.initialState,
      );
      final decoded = RpgStateSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.toJson(), snapshot.toJson());
      expect(decoded.metadata.parentSnapshotId, 'snapshot_08');
      expect(validator.validateSnapshot(scenario, decoded).isValid, isTrue);
    });

    test('detects snapshot metadata that diverges from runtime state', () {
      final scenario = _fullScenario();
      final snapshot = RpgStateSnapshot(
        metadata: RpgSnapshotMetadata(
          id: 'snapshot_12',
          scenarioId: scenario.metadata.id,
          scenarioVersion: scenario.metadata.version,
          branchId: 'main_branch',
          turn: 99,
          randomState: 0,
          rollsConsumed: 0,
          createdAt: DateTime.utc(2026, 8, 7),
        ),
        state: scenario.initialState,
      );

      expect(
        validator.validateSnapshot(scenario, snapshot).issues.single.code,
        'determinism_mismatch',
      );
    });
  });
}

RpgScenario _minimalScenario() => const RpgScenario(
      metadata: RpgScenarioMetadata(
        id: 'minimal_scenario',
        name: 'Minimal scenario',
        version: '1.0.0',
      ),
      initialSeed: 11,
      initialState: RpgRuntimeState(
        scenarioId: 'minimal_scenario',
        scenarioVersion: '1.0.0',
        random: RpgRandomState(initialSeed: 11, state: 11),
      ),
    );

RpgScenario _fullScenario() => const RpgScenario(
      metadata: RpgScenarioMetadata(
        id: 'lost_relic',
        name: 'The Lost Relic',
        version: '1.2.0',
        description: 'Recover the relic from the old ruins.',
        author: 'NativeTavern',
        tags: ['adventure'],
      ),
      initialSeed: 424242,
      compatibility: RpgCompatibility(
        minimumEngineVersion: '1.0.0',
        maximumEngineVersion: '2.0.0',
        requiredCapabilities: ['core_rules'],
      ),
      protectedFields: [
        'random.state',
        'random.rollsConsumed',
        'turn',
        'inventory',
        'quests',
        'cooldowns',
        'eventHistory',
      ],
      attributes: [
        RpgAttributeDefinition(
          id: 'strength',
          label: 'Strength',
          initialValue: 4,
          minimum: 0,
          maximum: 10,
        ),
        RpgAttributeDefinition(
          id: 'stamina',
          label: 'Stamina',
          initialValue: 8,
          minimum: 0,
          maximum: 10,
        ),
      ],
      items: [
        RpgItemDefinition(id: 'potion', label: 'Potion'),
      ],
      actors: [RpgActorDefinition(id: 'guide', label: 'Village Guide')],
      locations: [
        RpgLocationDefinition(id: 'village', label: 'Village'),
        RpgLocationDefinition(id: 'ruins', label: 'Old Ruins'),
      ],
      quests: [
        RpgQuestDefinition(
          id: 'find_relic',
          label: 'Find the relic',
          stages: [
            RpgQuestStageDefinition(
              id: 'search_ruins',
              label: 'Search the ruins',
              objectiveIds: ['inspect_altar'],
            ),
          ],
        ),
      ],
      actions: [
        RpgActionDefinition(
          id: 'explore',
          label: 'Explore the ruins',
          availability: [
            RpgCondition(
              operator: RpgConditionOperator.greaterThanOrEqual,
              path: 'attributes.stamina',
              value: 2,
            ),
          ],
          costs: [RpgActionCost(path: 'attributes.stamina', amount: 2)],
          check: RpgSkillCheck(
            attributeId: 'strength',
            dice: RpgDiceSpec('1d20+2'),
            difficulty: 12,
            successEffects: [
              RpgEffect(
                type: RpgEffectType.setQuestStatus,
                target: 'find_relic',
                value: 'completed',
              ),
            ],
            failureEffects: [
              RpgEffect(
                type: RpgEffectType.setCooldown,
                target: 'explore',
                amount: 1,
              ),
            ],
          ),
          effects: [
            RpgEffect(
              type: RpgEffectType.decrementValue,
              target: 'attributes.stamina',
              amount: 2,
            ),
          ],
        ),
      ],
      initialState: RpgRuntimeState(
        scenarioId: 'lost_relic',
        scenarioVersion: '1.2.0',
        turn: 12,
        random: RpgRandomState(
          initialSeed: 424242,
          state: 918273645,
          rollsConsumed: 7,
        ),
        attributes: {'strength': 4, 'stamina': 8},
        variables: {
          'weather': 'rain',
          'tutorialSeen': true,
          'clues': ['map', 'rune'],
        },
        inventory: [
          RpgInventoryEntry(
            itemId: 'potion',
            quantity: 2,
            metadata: {'quality': 'common'},
          ),
        ],
        relationships: [
          RpgRelationshipState(actorId: 'guide', score: 15, tags: ['trusted']),
        ],
        clock: RpgClockState(
          elapsedMinutes: 780,
          day: 2,
          minuteOfDay: 540,
        ),
        locationId: 'ruins',
        quests: [
          RpgQuestState(
            questId: 'find_relic',
            status: RpgQuestStatus.active,
            stageId: 'search_ruins',
            objectiveProgress: {'inspect_altar': 1},
          ),
        ],
        cooldowns: {'explore': 2},
        eventHistory: [
          RpgEventRecord(
            id: 'event_12',
            turn: 12,
            type: 'actionResolved',
            actionId: 'explore',
            summary: 'The party entered the ruins.',
            data: {'roll': 14},
          ),
        ],
      ),
    );

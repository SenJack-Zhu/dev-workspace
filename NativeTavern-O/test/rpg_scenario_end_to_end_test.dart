import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';

void main() {
  test('scenario package flows from JSON through policy and snapshot checks',
      () {
    final packageJson = <String, dynamic>{
      'schemaVersion': 1,
      'metadata': {
        'id': 'vault_run',
        'name': 'Vault Run',
        'version': '1.0.0',
      },
      'initialSeed': 99,
      'attributes': [
        {
          'id': 'luck',
          'label': 'Luck',
          'initialValue': 3,
          'minimum': 0,
          'maximum': 10,
        },
      ],
      'items': [
        {'id': 'vault_key', 'label': 'Vault Key', 'stackable': false},
      ],
      'actors': [
        {'id': 'guardian', 'label': 'Guardian'},
      ],
      'locations': [
        {'id': 'gate', 'label': 'Gate'},
        {'id': 'vault', 'label': 'Vault'},
      ],
      'quests': [
        {
          'id': 'open_vault',
          'label': 'Open the vault',
          'stages': [
            {
              'id': 'unlock',
              'label': 'Unlock the gate',
              'objectiveIds': ['find_key'],
            },
          ],
        },
      ],
      'actions': [
        {
          'id': 'enter_vault',
          'label': 'Enter the vault',
          'availability': [
            {
              'operator': 'greaterThanOrEqual',
              'path': 'inventory.vault_key.quantity',
              'value': 1,
            },
          ],
          'check': {
            'attributeId': 'luck',
            'dice': {'expression': '1d20'},
            'difficulty': 10,
            'successEffects': [
              {'type': 'moveTo', 'target': 'vault'},
            ],
          },
          'effects': [
            {'type': 'setCooldown', 'target': 'enter_vault', 'amount': 2},
          ],
        },
      ],
      'initialState': {
        'scenarioId': 'vault_run',
        'scenarioVersion': '1.0.0',
        'turn': 3,
        'random': {'initialSeed': 99, 'state': 123456, 'rollsConsumed': 1},
        'attributes': {'luck': 3},
        'variables': {'gateOpen': false},
        'inventory': [
          {'itemId': 'vault_key', 'quantity': 1},
        ],
        'relationships': [
          {'actorId': 'guardian', 'score': -2},
        ],
        'clock': {'elapsedMinutes': 30, 'day': 1, 'minuteOfDay': 510},
        'locationId': 'gate',
        'quests': [
          {
            'questId': 'open_vault',
            'status': 'active',
            'stageId': 'unlock',
            'objectiveProgress': {'find_key': 1},
          },
        ],
        'cooldowns': {'enter_vault': 0},
        'eventHistory': [
          {
            'id': 'found_key',
            'turn': 2,
            'type': 'itemFound',
            'actionId': 'enter_vault',
          },
        ],
      },
    };

    final transported =
        jsonDecode(jsonEncode(packageJson)) as Map<String, dynamic>;
    final scenario = RpgScenario.fromJson(transported);
    const validator = RpgScenarioValidator();

    expect(validator.validate(scenario).issues, isEmpty);
    expect(scenario.toJson()['initialState'], packageJson['initialState']);

    final narrativePatch = RpgStatePatch.fromJson({
      'source': 'narrative',
      'effects': [
        {'type': 'removeItem', 'target': 'vault_key', 'amount': 1},
      ],
    });
    expect(
      validator.validatePatch(scenario, narrativePatch).issues.single.code,
      'protected_state_mutation',
    );

    final enginePatch = RpgStatePatch.fromJson({
      'source': 'ruleEngine',
      'effects': [
        {
          'type': 'setQuestStatus',
          'target': 'open_vault',
          'value': 'completed',
        },
      ],
    });
    expect(validator.validatePatch(scenario, enginePatch).issues, isEmpty);

    final snapshot = RpgStateSnapshot(
      metadata: RpgSnapshotMetadata(
        id: 'after_key',
        scenarioId: scenario.metadata.id,
        scenarioVersion: scenario.metadata.version,
        branchId: 'main_branch',
        turn: scenario.initialState.turn,
        randomState: scenario.initialState.random.state,
        rollsConsumed: scenario.initialState.random.rollsConsumed,
        createdAt: DateTime.utc(2026, 8, 7, 12),
      ),
      state: scenario.initialState,
    );
    final restoredSnapshot = RpgStateSnapshot.fromJson(
      jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>,
    );

    expect(
        validator.validateSnapshot(scenario, restoredSnapshot).issues, isEmpty);
    expect(restoredSnapshot.toJson(), snapshot.toJson());
  });
}

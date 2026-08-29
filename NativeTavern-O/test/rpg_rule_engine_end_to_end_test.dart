import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/rpg/rpg.dart';
import 'package:native_tavern/data/repositories/drift_rpg_persistence_repository.dart';
import 'package:native_tavern/domain/services/rpg_game_session_service.dart';
import 'package:native_tavern/domain/services/rpg_rule_engine.dart';

void main() {
  group('deterministic RPG rule engine', () {
    const engine = RpgRuleEngine();
    final scenario = _scenario();

    test('same seed and action sequence produces identical state', () {
      final first = engine.execute(
        scenario: scenario,
        state: scenario.initialState,
        actionId: 'enter_vault',
      );
      final second = engine.execute(
        scenario: scenario,
        state: scenario.initialState,
        actionId: 'enter_vault',
      );

      expect(first.outcome, RpgActionOutcome.succeeded);
      expect(second.state.toJson(), first.state.toJson());
      expect(first.roll?.values, second.roll?.values);
      expect(first.state.turn, 1);
      expect(first.state.random.rollsConsumed, 2);
      expect(first.state.attributes, {'courage': 3, 'energy': 3});
      expect(first.state.variables, {
        'score': 3,
        'ready': false,
        'clues': ['map'],
      });
      expect(first.state.inventory.single.itemId, 'gem');
      expect(first.state.inventory.single.quantity, 2);
      expect(first.state.relationships.single.score, 3);
      expect(first.state.locationId, 'vault');
      expect(first.state.quests.single.status, RpgQuestStatus.completed);
      expect(first.state.cooldowns, {'enter_vault': 2});
      expect(
        first.state.eventHistory.map((event) => event.type),
        ['vaultEntered', 'actionResolved'],
      );
      expect(scenario.initialState.turn, 0);
      expect(scenario.initialState.inventory.single.itemId, 'key');
    });

    test('failed checks use failure effects and still consume one atomic turn',
        () {
      final result = engine.execute(
        scenario: scenario,
        state: scenario.initialState,
        actionId: 'impossible_check',
      );

      expect(result.outcome, RpgActionOutcome.failedCheck);
      expect(result.checkTotal, lessThan(1000));
      expect(result.state.turn, 1);
      expect(result.state.cooldowns, {'impossible_check': 1});
      expect(result.state.random.rollsConsumed, 1);
      expect(
        result.state.eventHistory.single.data['outcome'],
        RpgActionOutcome.failedCheck.name,
      );
    });

    test('protected narrative mutation and invalid effects leave input intact',
        () {
      final before = scenario.initialState.toJson();

      expect(
        () => engine.applyPatch(
          scenario: scenario,
          state: scenario.initialState,
          patch: const RpgStatePatch(
            source: RpgMutationSource.narrative,
            effects: [
              RpgEffect(
                type: RpgEffectType.incrementValue,
                target: 'attributes.courage',
                amount: 1,
              ),
            ],
          ),
        ),
        throwsA(
          isA<RpgRuleViolation>().having(
            (error) => error.code,
            'code',
            'protected_state_mutation',
          ),
        ),
      );
      expect(
        () => engine.applyPatch(
          scenario: scenario,
          state: scenario.initialState,
          patch: const RpgStatePatch(
            source: RpgMutationSource.ruleEngine,
            effects: [
              RpgEffect(
                type: RpgEffectType.addItem,
                target: 'key',
                amount: 1,
              ),
            ],
          ),
        ),
        throwsA(
          isA<RpgRuleViolation>().having(
            (error) => error.code,
            'code',
            'invalid_state',
          ),
        ),
      );
      expect(scenario.initialState.toJson(), before);
    });

    test('unavailable actions and resource underflow do not advance state', () {
      final before = scenario.initialState.toJson();

      expect(
        () => engine.execute(
          scenario: scenario,
          state: scenario.initialState,
          actionId: 'too_expensive',
        ),
        throwsA(
          isA<RpgRuleViolation>().having(
            (error) => error.code,
            'code',
            'insufficient_resource',
          ),
        ),
      );
      expect(scenario.initialState.toJson(), before);
      expect(
        engine
            .availableActions(scenario, scenario.initialState)
            .map((action) => action.id),
        containsAll(['enter_vault', 'wait', 'impossible_check']),
      );
      expect(
        engine
            .availableActions(scenario, scenario.initialState)
            .map((action) => action.id),
        isNot(contains('too_expensive')),
      );
    });
  });

  group('RPG session with real SQLite persistence', () {
    late Directory temporaryDirectory;
    late File databaseFile;
    late AppDatabase database;
    late DriftRpgPersistenceRepository repository;
    late RpgGameSessionService service;
    late int idCounter;
    late int clockMinute;

    DateTime now() =>
        DateTime.utc(2026, 8, 8, 12).add(Duration(minutes: clockMinute++));
    String nextId() => 'id_${++idCounter}';

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp('rpg-engine-');
      databaseFile = File('${temporaryDirectory.path}/rpg.sqlite');
      database = AppDatabase.forTesting(NativeDatabase(databaseFile));
      await database.customSelect('SELECT 1').get();
      await _seedChat(database);
      repository = DriftRpgPersistenceRepository(database);
      idCounter = 0;
      clockMinute = 0;
      service = RpgGameSessionService(
        repository: repository,
        now: now,
        idFactory: nextId,
      );
    });

    tearDown(() async {
      await database.close();
      await temporaryDirectory.delete(recursive: true);
    });

    test('commits turns, survives restart, and records source lineage',
        () async {
      final scenario = _scenario();
      final initial = await service.initialize(
        chatId: 'chat-1',
        scenario: scenario,
        branchId: 'main',
      );
      final committed = await service.executeAction(
        chatId: 'chat-1',
        actionId: 'enter_vault',
      );

      expect(committed.snapshot.metadata.parentSnapshotId,
          initial.snapshot.metadata.id);
      expect(committed.snapshot.metadata.stateHash, startsWith('sha256:'));
      expect(await repository.getCurrentSnapshotId('chat-1'),
          committed.snapshot.metadata.id);
      expect((await service.getTurnLog('chat-1')).last.actionId, 'enter_vault');
      final persistedState = await repository.getCurrentState('chat-1');
      expect(persistedState?.toJson(), committed.execution.state.toJson());

      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(databaseFile));
      await database.customSelect('SELECT 1').get();
      repository = DriftRpgPersistenceRepository(database);
      service = RpgGameSessionService(
        repository: repository,
        now: now,
        idFactory: nextId,
      );

      final restored = await service.load('chat-1');
      expect(restored?.snapshot.metadata.id, committed.snapshot.metadata.id);
      expect(restored?.state.toJson(), committed.execution.state.toJson());
      expect(await _foreignKeyViolations(database), isEmpty);
    });

    test('rollback replay is deterministic and branches remain isolated',
        () async {
      final initial = await service.initialize(
        chatId: 'chat-1',
        scenario: _scenario(),
        branchId: 'main',
      );
      final first = await service.executeAction(
        chatId: 'chat-1',
        actionId: 'enter_vault',
      );
      await service.rollback(
        chatId: 'chat-1',
        snapshotId: initial.snapshot.metadata.id,
      );
      final replay = await service.executeAction(
        chatId: 'chat-1',
        actionId: 'enter_vault',
      );

      expect(replay.execution.state.toJson(), first.execution.state.toJson());
      expect(replay.snapshot.metadata.parentSnapshotId,
          initial.snapshot.metadata.id);

      final alternate = await service.forkBranch(
        chatId: 'chat-1',
        fromSnapshotId: first.snapshot.metadata.id,
        branchId: 'alternate',
      );
      expect(alternate.snapshot.metadata.parentSnapshotId,
          first.snapshot.metadata.id);
      expect(alternate.snapshot.metadata.turn, first.snapshot.metadata.turn);
      final alternateTurn = await service.executeAction(
        chatId: 'chat-1',
        actionId: 'wait',
      );
      expect(alternateTurn.snapshot.metadata.branchId, 'alternate');
      expect(alternateTurn.execution.state.variables['route'], 'alternate');

      final mainSnapshots = await repository.listSnapshots(
        scenarioId: 'vault_run',
        branchId: 'main',
      );
      final alternateSnapshots = await repository.listSnapshots(
        scenarioId: 'vault_run',
        branchId: 'alternate',
      );
      expect(mainSnapshots, hasLength(3));
      expect(alternateSnapshots, hasLength(2));
      expect(
        mainSnapshots.every(
          (snapshot) => !snapshot.state.variables.containsKey('route'),
        ),
        isTrue,
      );

      final restoredMain = await service.rollback(
        chatId: 'chat-1',
        snapshotId: first.snapshot.metadata.id,
      );
      expect(restoredMain.branchId, 'main');
      expect(restoredMain.state.variables.containsKey('route'), isFalse);
      expect(await _foreignKeyViolations(database), isEmpty);
    });

    test('rejected actions and failed chat commits leave no partial writes',
        () async {
      final initial = await service.initialize(
        chatId: 'chat-1',
        scenario: _scenario(),
        branchId: 'main',
      );
      final advanced = await service.executeAction(
        chatId: 'chat-1',
        actionId: 'wait',
      );
      final beforeState = await repository.getCurrentState('chat-1');
      final beforeSnapshotId = await repository.getCurrentSnapshotId('chat-1');
      final beforeSnapshots = await repository.listSnapshots(
        scenarioId: 'vault_run',
      );

      await expectLater(
        service.executeAction(
          chatId: 'chat-1',
          actionId: 'too_expensive',
        ),
        throwsA(
          isA<RpgRuleViolation>().having(
            (error) => error.code,
            'code',
            'insufficient_resource',
          ),
        ),
      );
      expect((await repository.getCurrentState('chat-1'))?.toJson(),
          beforeState?.toJson());
      expect(await repository.getCurrentSnapshotId('chat-1'), beforeSnapshotId);
      expect(
        await repository.listSnapshots(scenarioId: 'vault_run'),
        hasLength(beforeSnapshots.length),
      );

      final staleSnapshot = RpgStateSnapshot(
        metadata: RpgSnapshotMetadata(
          id: 'snapshot_stale',
          scenarioId: 'vault_run',
          scenarioVersion: '1.0.0',
          branchId: 'main',
          parentSnapshotId: initial.snapshot.metadata.id,
          turn: advanced.execution.state.turn,
          randomState: advanced.execution.state.random.state,
          rollsConsumed: advanced.execution.state.random.rollsConsumed,
          createdAt: now(),
        ),
        state: advanced.execution.state,
      );
      await expectLater(
        repository.commitSnapshotAndCurrentState(
          chatId: 'chat-1',
          snapshot: staleSnapshot,
          expectedCurrentSnapshotId: initial.snapshot.metadata.id,
          updatedAt: now(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await repository.getSnapshot(staleSnapshot.metadata.id), isNull);
      expect(
        await repository.getCurrentSnapshotId('chat-1'),
        advanced.snapshot.metadata.id,
      );

      final changedJson = _scenario().toJson();
      (changedJson['metadata'] as Map<String, dynamic>)['name'] = 'Changed';
      final changedScenario = RpgScenario.fromJson(changedJson);
      await expectLater(
        repository.saveScenario(changedScenario),
        throwsA(isA<StateError>()),
      );
      expect(
        (await repository.getScenario('vault_run'))?.metadata.name,
        'Vault Run',
      );

      final orphanService = RpgGameSessionService(
        repository: repository,
        now: now,
        idFactory: () => 'orphan',
      );
      await expectLater(
        orphanService.initialize(
          chatId: 'missing-chat',
          scenario: _scenario(),
          branchId: 'orphan_branch',
        ),
        throwsA(anything),
      );
      expect(await repository.getSnapshot('snapshot_orphan'), isNull);
      expect(
        await repository.listSnapshots(
          scenarioId: 'vault_run',
          branchId: 'orphan_branch',
        ),
        isEmpty,
      );
      expect(await _foreignKeyViolations(database), isEmpty);
    });

    test('a chat cannot roll back to another session snapshot', () async {
      final firstSession = await service.initialize(
        chatId: 'chat-1',
        scenario: _scenario(),
        branchId: 'main',
      );
      final secondSession = await service.initialize(
        chatId: 'chat-2',
        scenario: _scenario(),
      );

      expect(secondSession.branchId, 'chat_chat-2_main');
      await expectLater(
        service.rollback(
          chatId: 'chat-1',
          snapshotId: secondSession.snapshot.metadata.id,
        ),
        throwsA(
          isA<RpgSessionException>().having(
            (error) => error.code,
            'code',
            'snapshot_session_mismatch',
          ),
        ),
      );
      expect(
        await repository.getCurrentSnapshotId('chat-1'),
        firstSession.snapshot.metadata.id,
      );
    });
  });
}

Future<void> _seedChat(AppDatabase database) async {
  await database.customStatement(
    'INSERT INTO characters (id, name, created_at, modified_at) '
    "VALUES ('character-1', 'Character', 1, 1)",
  );
  await database.customStatement(
    'INSERT INTO chats (id, character_id, created_at, updated_at) '
    "VALUES ('chat-1', 'character-1', 1, 1)",
  );
  await database.customStatement(
    'INSERT INTO chats (id, character_id, created_at, updated_at) '
    "VALUES ('chat-2', 'character-1', 1, 1)",
  );
}

Future<List<Map<String, Object?>>> _foreignKeyViolations(
  AppDatabase database,
) async {
  final rows = await database.customSelect('PRAGMA foreign_key_check').get();
  return rows.map((row) => row.data).toList();
}

RpgScenario _scenario() => const RpgScenario(
      metadata: RpgScenarioMetadata(
        id: 'vault_run',
        name: 'Vault Run',
        version: '1.0.0',
      ),
      initialSeed: 12345,
      protectedFields: [
        'random.initialSeed',
        'random.state',
        'random.rollsConsumed',
        'turn',
        'attributes',
        'inventory',
        'quests',
        'cooldowns',
        'eventHistory',
      ],
      attributes: [
        RpgAttributeDefinition(
          id: 'courage',
          label: 'Courage',
          initialValue: 4,
          minimum: 0,
          maximum: 10,
        ),
        RpgAttributeDefinition(
          id: 'energy',
          label: 'Energy',
          initialValue: 5,
          minimum: 0,
          maximum: 10,
        ),
      ],
      items: [
        RpgItemDefinition(id: 'key', label: 'Key', stackable: false),
        RpgItemDefinition(id: 'gem', label: 'Gem'),
      ],
      actors: [RpgActorDefinition(id: 'guide', label: 'Guide')],
      locations: [
        RpgLocationDefinition(id: 'camp', label: 'Camp'),
        RpgLocationDefinition(id: 'vault', label: 'Vault'),
      ],
      quests: [
        RpgQuestDefinition(
          id: 'open_vault',
          label: 'Open the vault',
          stages: [
            RpgQuestStageDefinition(
              id: 'unlock',
              label: 'Unlock the door',
              objectiveIds: ['door'],
            ),
          ],
        ),
      ],
      actions: [
        RpgActionDefinition(
          id: 'enter_vault',
          label: 'Enter the vault',
          availability: [
            RpgCondition(
              operator: RpgConditionOperator.all,
              conditions: [
                RpgCondition(
                  operator: RpgConditionOperator.greaterThanOrEqual,
                  path: 'attributes.energy',
                  value: 2,
                ),
                RpgCondition(
                  operator: RpgConditionOperator.greaterThanOrEqual,
                  path: 'inventory.key.quantity',
                  value: 1,
                ),
                RpgCondition(
                  operator: RpgConditionOperator.any,
                  conditions: [
                    RpgCondition(
                      operator: RpgConditionOperator.equals,
                      path: 'variables.ready',
                      value: true,
                    ),
                    RpgCondition(
                      operator: RpgConditionOperator.equals,
                      path: 'locationId',
                      value: 'vault',
                    ),
                  ],
                ),
              ],
            ),
          ],
          costs: [RpgActionCost(path: 'attributes.energy', amount: 2)],
          check: RpgSkillCheck(
            attributeId: 'courage',
            dice: RpgDiceSpec('2d6+1'),
            difficulty: 1,
            successEffects: [
              RpgEffect(
                type: RpgEffectType.setValue,
                target: 'variables.ready',
                value: false,
              ),
              RpgEffect(
                type: RpgEffectType.incrementValue,
                target: 'variables.score',
                amount: 2,
              ),
              RpgEffect(
                type: RpgEffectType.decrementValue,
                target: 'attributes.courage',
                amount: 1,
              ),
              RpgEffect(
                type: RpgEffectType.addItem,
                target: 'gem',
                amount: 2,
              ),
              RpgEffect(
                type: RpgEffectType.removeItem,
                target: 'key',
                amount: 1,
              ),
              RpgEffect(
                type: RpgEffectType.adjustRelationship,
                target: 'guide',
                amount: 3,
              ),
              RpgEffect(type: RpgEffectType.moveTo, target: 'vault'),
              RpgEffect(
                type: RpgEffectType.setQuestStatus,
                target: 'open_vault',
                value: 'completed',
              ),
              RpgEffect(
                type: RpgEffectType.setCooldown,
                target: 'enter_vault',
                amount: 2,
              ),
              RpgEffect(
                type: RpgEffectType.appendEvent,
                target: 'vaultEntered',
                value: {'source': 'rule'},
              ),
            ],
          ),
        ),
        RpgActionDefinition(
          id: 'wait',
          label: 'Wait',
          effects: [
            RpgEffect(
              type: RpgEffectType.setValue,
              target: 'variables.route',
              value: 'alternate',
            ),
          ],
        ),
        RpgActionDefinition(
          id: 'impossible_check',
          label: 'Impossible check',
          check: RpgSkillCheck(
            attributeId: 'courage',
            dice: RpgDiceSpec('1d6'),
            difficulty: 1000,
            failureEffects: [
              RpgEffect(
                type: RpgEffectType.setCooldown,
                target: 'impossible_check',
                amount: 1,
              ),
            ],
          ),
        ),
        RpgActionDefinition(
          id: 'too_expensive',
          label: 'Too expensive',
          costs: [RpgActionCost(path: 'attributes.energy', amount: 99)],
        ),
      ],
      initialState: RpgRuntimeState(
        scenarioId: 'vault_run',
        scenarioVersion: '1.0.0',
        random: RpgRandomState(initialSeed: 12345, state: 12345),
        attributes: {'courage': 4, 'energy': 5},
        variables: {
          'score': 1,
          'ready': true,
          'clues': ['map'],
        },
        inventory: [RpgInventoryEntry(itemId: 'key', quantity: 1)],
        locationId: 'camp',
        quests: [
          RpgQuestState(
            questId: 'open_vault',
            status: RpgQuestStatus.active,
            stageId: 'unlock',
            objectiveProgress: {'door': 0},
          ),
        ],
      ),
    );

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/repositories/world_info_repository.dart';
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/capability_registry.dart';
import 'package:native_tavern/domain/services/image_generation_service.dart';
import 'package:native_tavern/domain/services/tool_calling/built_in_tool_service.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_execution_audit_service.dart';
import 'package:native_tavern/domain/services/variables_service.dart';

void main() {
  test('all built-ins execute end to end through security and audit boundaries',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('built_in_tool_e2e_');
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final worldRepository = WorldInfoRepository(database);
    final variables = VariablesService.instance;
    const chatId = 'tool-e2e-chat';
    addTearDown(() async {
      variables.clearLocalVariables(chatId);
      await database.close();
      await directory.delete(recursive: true);
    });

    variables.setLocalVariable(chatId, 'quest_stage', 'two');
    final book = await worldRepository.createWorldInfo(
      name: 'Tool E2E Lore',
      isGlobal: true,
    );
    await worldRepository.addEntry(
      worldInfoId: book.id,
      keys: const ['obsidian gate'],
      content: 'The obsidian gate opens only under a new moon.',
    );

    final imageGenerator = _EndToEndImageGenerator();
    final registry = BuiltInToolRegistry.nativeTavern(
      imageGenerator: imageGenerator,
      variableReader: VariablesServiceToolVariableReader(variables),
      worldInfoSource: WorldInfoRepositoryToolWorldInfoSource(worldRepository),
      random: math.Random(11),
    );
    final audit = FileToolExecutionAuditRepository(dataPath: directory.path);
    final service = BuiltInToolExecutionService(
      registry: registry,
      auditRepository: audit,
    );
    final permissions = ToolPermissionSnapshot.fromUserSettings(
      registry.definitions.map((definition) => definition.name),
    );
    final capabilities = ToolCapabilitySnapshot.available(
      const {CapabilityId.imageGeneration},
    );

    final results = <ToolResultMessage>[];
    results.add(await service.execute(
      service.prepare(_call(
        RollDiceToolExecutor.toolName,
        const {'count': 2, 'sides': 8},
      )),
      permissions: permissions,
    ));
    results.add(await service.execute(
      service.prepare(_call(
        ReadVariableToolExecutor.toolName,
        const {
          'scope': 'local',
          'chat_id': chatId,
          'name': 'quest_stage',
        },
      )),
      permissions: permissions,
    ));
    results.add(await service.execute(
      service.prepare(_call(
        SearchWorldInfoToolExecutor.toolName,
        const {'query': 'obsidian gate'},
      )),
      permissions: permissions,
    ));
    results.add(await service.execute(
      service.prepare(_call(
        GenerateImageToolExecutor.toolName,
        const {'prompt': 'private obsidian gate illustration'},
      )),
      permissions: permissions,
      capabilities: capabilities,
      requestApproval: (_) async => ToolApprovalDecision.approveOnce,
    ));

    expect(
      results.every((result) => result.status == ToolResultStatus.succeeded),
      isTrue,
    );
    expect(_output(results[1]), containsPair('value', 'two'));
    expect(_output(results[2]), containsPair('match_count', 1));
    expect(_output(results[3]), containsPair('image_count', 1));
    expect(imageGenerator.callCount, 1);

    final records = await audit.readRecent();
    expect(records, hasLength(4));
    expect(
      records.map((record) => record.toolName).toSet(),
      registry.definitions.map((definition) => definition.name).toSet(),
    );
    final raw = await File(
      '${directory.path}/audit/tool_executions.jsonl',
    ).readAsString();
    expect(raw, isNot(contains('private obsidian gate illustration')));
    expect(raw, isNot(contains('quest_stage')));
    expect(raw, isNot(contains('obsidian gate')));
  });
}

ToolCall _call(String name, Map<String, dynamic> arguments) {
  return ToolCall.ready(
    id: 'e2e_${name}_${arguments.length}',
    name: name,
    arguments: arguments,
    rawArguments: jsonEncode(arguments),
  );
}

Map<String, dynamic> _output(ToolResultMessage result) {
  return result.output! as Map<String, dynamic>;
}

final class _EndToEndImageGenerator implements ToolImageGenerator {
  int callCount = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<ImageGenResult?> generate(
    ImageGenRequest request,
    ToolCancellationToken cancellationToken,
  ) async {
    cancellationToken.throwIfCancelled();
    callCount++;
    return ImageGenResult(
      images: [
        Uint8List.fromList(const [137, 80, 78, 71])
      ],
      prompt: request.prompt,
      seed: 101,
      format: 'png',
    );
  }
}

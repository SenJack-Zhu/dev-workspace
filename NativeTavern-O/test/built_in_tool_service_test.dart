import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/world_info.dart';
import 'package:native_tavern/domain/models/built_in_tool.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';
import 'package:native_tavern/domain/services/capability_registry.dart';
import 'package:native_tavern/domain/services/image_generation_service.dart';
import 'package:native_tavern/domain/services/tool_calling/built_in_tool_service.dart';
import 'package:native_tavern/domain/services/tool_calling/tool_execution_audit_service.dart';

void main() {
  group('built-in tool registry', () {
    test('declares tools, access levels, capabilities, and data scopes', () {
      final registry = _registry();
      final descriptors = {
        for (final descriptor in registry.descriptors)
          descriptor.definition.name: descriptor,
      };

      expect(
        registry.definitions.map((definition) => definition.name),
        containsAll(const [
          GenerateImageToolExecutor.toolName,
          RollDiceToolExecutor.toolName,
          ReadVariableToolExecutor.toolName,
          SearchWorldInfoToolExecutor.toolName,
        ]),
      );
      expect(
        descriptors[GenerateImageToolExecutor.toolName]?.accessLevel,
        ToolAccessLevel.externalSideEffect,
      );
      expect(
        descriptors[GenerateImageToolExecutor.toolName]?.requiredCapabilities,
        {CapabilityId.imageGeneration},
      );
      expect(
        descriptors[GenerateImageToolExecutor.toolName]?.supportsDryRun,
        isTrue,
      );
      expect(
        descriptors[ReadVariableToolExecutor.toolName]?.dataScopes,
        contains(ToolDataScope.variableValue),
      );
      expect(
        descriptors[SearchWorldInfoToolExecutor.toolName]?.dataScopes,
        contains(ToolDataScope.worldInfoContent),
      );
      expect(
        registry.definitions.every(
          (definition) =>
              definition.inputSchema['additionalProperties'] == false,
        ),
        isTrue,
      );
    });

    test('rejects duplicate tool names', () {
      expect(
        () => BuiltInToolRegistry([
          RollDiceToolExecutor(random: math.Random(1)),
          RollDiceToolExecutor(random: math.Random(2)),
        ]),
        throwsArgumentError,
      );
    });
  });

  group('authorization and argument boundaries', () {
    test('denies every tool by default and audits the denial', () async {
      final audit = MemoryToolExecutionAuditRepository();
      final service = BuiltInToolExecutionService(
        registry: _registry(),
        auditRepository: audit,
      );
      final plan = service.prepare(_call(
        RollDiceToolExecutor.toolName,
        const {'sides': 6},
      ));

      final result = await service.execute(plan);

      expect(result.status, ToolResultStatus.failed);
      expect(_errorCode(result), 'permission_denied');
      final record = (await audit.readRecent()).single;
      expect(record.result, ToolExecutionOutcome.denied);
      expect(record.authorizationSource, ToolAuthorizationSource.none);
    });

    test('rejects unknown fields, path-like IDs, and permission injection', () {
      final service = BuiltInToolExecutionService(registry: _registry());

      expect(
        () => service.prepare(_call(
          GenerateImageToolExecutor.toolName,
          const {
            'prompt': 'safe prompt',
            'api_key': 'sk-do-not-accept',
          },
        )),
        _builtInError('invalid_arguments'),
      );
      expect(
        () => service.prepare(_call(
          ReadVariableToolExecutor.toolName,
          const {
            'scope': 'local',
            'name': 'hp',
            'chat_id': '../../settings.json',
          },
        )),
        _builtInError('invalid_arguments'),
      );
      expect(
        () => service.prepare(_call(
          SearchWorldInfoToolExecutor.toolName,
          const {
            'query': 'castle',
            'permission': 'allow',
          },
        )),
        _builtInError('invalid_arguments'),
      );
    });

    test('read-only tools run after an explicit settings grant', () async {
      final approvals = <ToolExecutionPreview>[];
      final audit = MemoryToolExecutionAuditRepository();
      final variables = _FakeVariableReader(
        globalValues: const {'hp': 12},
      );
      final worldInfo = _worldInfo(
        id: 'global-book',
        name: 'Places',
        content: 'The moon castle stands above the silver lake.',
      );
      final service = BuiltInToolExecutionService(
        registry: _registry(
          variableReader: variables,
          worldInfoSource: _FakeWorldInfoSource([worldInfo]),
        ),
        auditRepository: audit,
      );
      final permissions = ToolPermissionSnapshot.fromUserSettings(const {
        RollDiceToolExecutor.toolName,
        ReadVariableToolExecutor.toolName,
        SearchWorldInfoToolExecutor.toolName,
      });

      final dice = await service.execute(
        service.prepare(_call(
          RollDiceToolExecutor.toolName,
          const {'count': 2, 'sides': 6, 'modifier': 1},
        )),
        permissions: permissions,
        requestApproval: (preview) async {
          approvals.add(preview);
          return ToolApprovalDecision.approveOnce;
        },
      );
      final variable = await service.execute(
        service.prepare(_call(
          ReadVariableToolExecutor.toolName,
          const {'scope': 'global', 'name': 'hp'},
        )),
        permissions: permissions,
      );
      final search = await service.execute(
        service.prepare(_call(
          SearchWorldInfoToolExecutor.toolName,
          const {'query': 'moon castle'},
        )),
        permissions: permissions,
      );

      expect(dice.status, ToolResultStatus.succeeded);
      expect(_output(dice)['rolls'], hasLength(2));
      expect(_output(variable), containsPair('value', 12));
      expect(_output(search)['match_count'], 1);
      expect(approvals, isEmpty);
      final records = await audit.readRecent();
      expect(records, hasLength(3));
      expect(
        records.every(
          (record) =>
              record.authorizationSource ==
              ToolAuthorizationSource.userSettings,
        ),
        isTrue,
      );
    });

    test('write tools require one-time approval and cannot self-authorize',
        () async {
      final executor = _WriteToolExecutor();
      final service = BuiltInToolExecutionService(
        registry: BuiltInToolRegistry([executor]),
      );
      final permissions = ToolPermissionSnapshot.fromUserSettings(
        const {_WriteToolExecutor.toolName},
      );
      final plan = service.prepare(_call(
        _WriteToolExecutor.toolName,
        const {'value': 7},
      ));

      final withoutApproval = await service.execute(
        plan,
        permissions: permissions,
      );
      expect(withoutApproval.status, ToolResultStatus.failed);
      expect(_errorCode(withoutApproval), 'approval_required');
      expect(executor.writeCount, 0);

      final approved = await service.execute(
        plan,
        permissions: permissions,
        requestApproval: (_) async => ToolApprovalDecision.approveOnce,
      );
      expect(approved.status, ToolResultStatus.succeeded);
      expect(executor.writeCount, 1);

      expect(
        () => service.prepare(_call(
          _WriteToolExecutor.toolName,
          const {'value': 8, 'authorized': true},
        )),
        _builtInError('invalid_arguments'),
      );
    });
  });

  group('external effects, dry-run, and cancellation', () {
    test('never invokes image generation without one-time approval', () async {
      final imageGenerator = _FakeImageGenerator();
      final audit = MemoryToolExecutionAuditRepository();
      final service = BuiltInToolExecutionService(
        registry: _registry(imageGenerator: imageGenerator),
        auditRepository: audit,
      );
      final permissions = ToolPermissionSnapshot.fromUserSettings(
        const {GenerateImageToolExecutor.toolName},
      );
      final capabilities = ToolCapabilitySnapshot.available(
        const {CapabilityId.imageGeneration},
      );
      final plan = service.prepare(_call(
        GenerateImageToolExecutor.toolName,
        const {'prompt': 'private portrait prompt'},
      ));

      final missingApproval = await service.execute(
        plan,
        permissions: permissions,
        capabilities: capabilities,
      );
      final denied = await service.execute(
        plan,
        permissions: permissions,
        capabilities: capabilities,
        requestApproval: (_) async => ToolApprovalDecision.deny,
      );
      final cancelled = await service.execute(
        plan,
        permissions: permissions,
        capabilities: capabilities,
        requestApproval: (_) async => ToolApprovalDecision.cancel,
      );

      expect(_errorCode(missingApproval), 'approval_required');
      expect(_errorCode(denied), 'approval_denied');
      expect(cancelled.status, ToolResultStatus.cancelled);
      expect(imageGenerator.callCount, 0);
      expect(
        (await audit.readRecent()).map((record) => record.result),
        containsAll(const [
          ToolExecutionOutcome.denied,
          ToolExecutionOutcome.cancelled,
        ]),
      );
    });

    test('dry-run previews parameters without capability or external work',
        () async {
      final imageGenerator = _FakeImageGenerator(available: false);
      final audit = MemoryToolExecutionAuditRepository();
      final service = BuiltInToolExecutionService(
        registry: _registry(imageGenerator: imageGenerator),
        auditRepository: audit,
      );
      final plan = service.prepare(
        _call(
          GenerateImageToolExecutor.toolName,
          const {
            'prompt': 'a private scene',
            'width': 512,
            'height': 768,
          },
        ),
        dryRun: true,
      );

      final result = await service.execute(
        plan,
        permissions: ToolPermissionSnapshot.fromUserSettings(
          const {GenerateImageToolExecutor.toolName},
        ),
      );

      expect(plan.preview.parameters['prompt'], 'a private scene');
      expect(plan.preview.requiresConfirmation, isFalse);
      expect(result.status, ToolResultStatus.succeeded);
      expect(_output(result), containsPair('would_execute', false));
      expect(imageGenerator.callCount, 0);
      final record = (await audit.readRecent()).single;
      expect(record.result, ToolExecutionOutcome.dryRun);
      expect(record.authorizationSource, ToolAuthorizationSource.dryRun);
      expect(jsonEncode(record.toJson()), isNot(contains('a private scene')));
    });

    test('approved execution succeeds but provider failures stay failed',
        () async {
      final successGenerator = _FakeImageGenerator();
      final successAudit = MemoryToolExecutionAuditRepository();
      final successService = BuiltInToolExecutionService(
        registry: _registry(imageGenerator: successGenerator),
        auditRepository: successAudit,
      );
      final permissions = ToolPermissionSnapshot.fromUserSettings(
        const {GenerateImageToolExecutor.toolName},
      );
      final capabilities = ToolCapabilitySnapshot.available(
        const {CapabilityId.imageGeneration},
      );
      final plan = successService.prepare(_call(
        GenerateImageToolExecutor.toolName,
        const {'prompt': 'portrait'},
      ));

      final success = await successService.execute(
        plan,
        permissions: permissions,
        capabilities: capabilities,
        requestApproval: (_) async => ToolApprovalDecision.approveOnce,
      );
      expect(success.status, ToolResultStatus.succeeded);
      expect(_output(success), containsPair('image_count', 1));
      expect(successGenerator.callCount, 1);
      expect(
        (await successAudit.readRecent()).single.authorizationSource,
        ToolAuthorizationSource.oneTimeApproval,
      );

      final failingGenerator = _FakeImageGenerator(
        error: StateError('provider leaked sk-sensitive-key'),
      );
      final failingService = BuiltInToolExecutionService(
        registry: _registry(imageGenerator: failingGenerator),
      );
      final failure = await failingService.execute(
        failingService.prepare(_call(
          GenerateImageToolExecutor.toolName,
          const {'prompt': 'portrait'},
        )),
        permissions: permissions,
        capabilities: capabilities,
        requestApproval: (_) async => ToolApprovalDecision.approveOnce,
      );
      expect(failure.status, ToolResultStatus.failed);
      expect(_errorCode(failure), 'execution_failed');
      expect(jsonEncode(failure.output), isNot(contains('sk-sensitive-key')));
    });

    test('in-flight cancellation never returns a forged success', () async {
      final blocker = Completer<void>();
      final started = Completer<void>();
      final generator = _FakeImageGenerator(
        blocker: blocker,
        started: started,
      );
      final audit = MemoryToolExecutionAuditRepository();
      final service = BuiltInToolExecutionService(
        registry: _registry(imageGenerator: generator),
        auditRepository: audit,
      );
      final controller = ToolCancellationController();
      final execution = service.execute(
        service.prepare(_call(
          GenerateImageToolExecutor.toolName,
          const {'prompt': 'cancel me'},
        )),
        permissions: ToolPermissionSnapshot.fromUserSettings(
          const {GenerateImageToolExecutor.toolName},
        ),
        capabilities: ToolCapabilitySnapshot.available(
          const {CapabilityId.imageGeneration},
        ),
        invocationContext: ToolInvocationContext(
          maxDepth: 1,
          cancellationToken: controller.token,
        ),
        requestApproval: (_) async => ToolApprovalDecision.approveOnce,
      );

      await started.future;
      controller.cancel('private cancellation reason');
      blocker.complete();
      final result = await execution;

      expect(result.status, ToolResultStatus.cancelled);
      expect(_errorCode(result), 'cancelled');
      expect(jsonEncode(result.output),
          isNot(contains('private cancellation reason')));
      expect((await audit.readRecent()).single.result,
          ToolExecutionOutcome.cancelled);
    });

    test('image service gateway aborts the underlying HTTP request', () async {
      final adapter = _BlockingHttpAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final imageService = ImageGenerationService(dio: dio)
        ..updateSettings(const ImageGenSettings(
          enabled: true,
          provider: ImageGenProvider.pollinations,
        ));
      addTearDown(imageService.dispose);
      final gateway = ImageGenerationServiceToolImageGenerator(imageService);
      final controller = ToolCancellationController();

      final execution = gateway.generate(
        const ImageGenRequest(prompt: 'cancel transport'),
        controller.token,
      );
      await adapter.started.future;
      controller.cancel('user cancelled');

      await expectLater(execution, _protocolError('cancelled'));
      await expectLater(adapter.cancelled.future, completes);
    });
  });

  test('file audit persists redacted structured summaries', () async {
    final directory = await Directory.systemTemp.createTemp('tool_audit_');
    addTearDown(() => directory.delete(recursive: true));
    final repository = FileToolExecutionAuditRepository(
      dataPath: directory.path,
    );
    final service = BuiltInToolExecutionService(
      registry: _registry(),
      auditRepository: repository,
    );
    final plan = service.prepare(
      _call(
        GenerateImageToolExecutor.toolName,
        const {'prompt': 'secret body with sk-private-key'},
      ),
      dryRun: true,
    );

    await service.execute(
      plan,
      permissions: ToolPermissionSnapshot.fromUserSettings(
        const {GenerateImageToolExecutor.toolName},
      ),
    );
    final raw = await File(
      '${directory.path}/audit/tool_executions.jsonl',
    ).readAsString();
    final record = (await repository.readRecent()).single;

    expect(raw, contains(GenerateImageToolExecutor.toolName));
    expect(raw, contains('configured:image-generation-provider'));
    expect(raw, isNot(contains('secret body')));
    expect(raw, isNot(contains('sk-private-key')));
    expect(record.parameterSummary['prompt'], containsPair('redacted', true));
    expect(record.callIdFingerprint, startsWith('sha256:'));
  });
}

BuiltInToolRegistry _registry({
  ToolImageGenerator? imageGenerator,
  ToolVariableReader? variableReader,
  ToolWorldInfoSource? worldInfoSource,
}) {
  return BuiltInToolRegistry.nativeTavern(
    imageGenerator: imageGenerator ?? _FakeImageGenerator(),
    variableReader: variableReader ?? _FakeVariableReader(),
    worldInfoSource: worldInfoSource ?? const _FakeWorldInfoSource([]),
    random: math.Random(7),
  );
}

ToolCall _call(String name, Map<String, dynamic> arguments) {
  return ToolCall.ready(
    id: 'call_${name}_${arguments.length}',
    name: name,
    arguments: arguments,
    rawArguments: jsonEncode(arguments),
  );
}

Map<String, dynamic> _output(ToolResultMessage result) {
  return result.output! as Map<String, dynamic>;
}

String _errorCode(ToolResultMessage result) {
  final error = _output(result)['error']! as Map<String, dynamic>;
  return error['code']! as String;
}

Matcher _builtInError(String code) {
  return throwsA(
    isA<BuiltInToolException>().having(
      (error) => error.code,
      'code',
      code,
    ),
  );
}

Matcher _protocolError(String code) {
  return throwsA(
    isA<ToolProtocolException>().having(
      (error) => error.code,
      'code',
      code,
    ),
  );
}

WorldInfo _worldInfo({
  required String id,
  required String name,
  required String content,
}) {
  final now = DateTime.utc(2026, 8, 8);
  return WorldInfo(
    id: id,
    name: name,
    isGlobal: true,
    createdAt: now,
    modifiedAt: now,
    entries: [
      WorldInfoEntry(
        id: '$id-entry',
        worldInfoId: id,
        keys: const ['moon castle'],
        content: content,
        enabled: true,
      ),
    ],
  );
}

final class _FakeImageGenerator implements ToolImageGenerator {
  @override
  final bool isAvailable;
  final Object? error;
  final Completer<void>? blocker;
  final Completer<void>? started;
  int callCount = 0;

  _FakeImageGenerator({
    bool available = true,
    this.error,
    this.blocker,
    this.started,
  }) : isAvailable = available;

  @override
  Future<ImageGenResult?> generate(
    ImageGenRequest request,
    ToolCancellationToken cancellationToken,
  ) async {
    callCount++;
    if (!(started?.isCompleted ?? true)) started?.complete();
    if (blocker != null) await blocker!.future;
    if (error != null) throw error!;
    return ImageGenResult(
      images: [
        Uint8List.fromList(const [1, 2, 3])
      ],
      prompt: request.prompt,
      seed: request.seed ?? 42,
    );
  }
}

final class _FakeVariableReader implements ToolVariableReader {
  final Map<String, Object?> globalValues;
  final Map<String, Map<String, Object?>> localValues = const {};

  _FakeVariableReader({
    this.globalValues = const {},
  });

  @override
  Future<ToolVariableReadResult> readGlobal(
    String name, {
    String? index,
  }) async {
    return ToolVariableReadResult(
      found: globalValues.containsKey(name),
      value: globalValues[name],
    );
  }

  @override
  Future<ToolVariableReadResult> readLocal(
    String chatId,
    String name, {
    String? index,
  }) async {
    return ToolVariableReadResult(
      found: localValues[chatId]?.containsKey(name) ?? false,
      value: localValues[chatId]?[name],
    );
  }
}

final class _FakeWorldInfoSource implements ToolWorldInfoSource {
  final List<WorldInfo> worldInfos;

  const _FakeWorldInfoSource(this.worldInfos);

  @override
  Future<List<WorldInfo>> readAllowedWorldInfos({
    String? worldInfoId,
    String? characterId,
  }) async {
    return worldInfos
        .where(
          (worldInfo) => worldInfoId == null || worldInfo.id == worldInfoId,
        )
        .toList(growable: false);
  }
}

final class _WriteToolExecutor extends BuiltInToolExecutor {
  static const toolName = 'write_test';
  int writeCount = 0;

  @override
  BuiltInToolDescriptor get descriptor => BuiltInToolDescriptor(
        definition: ToolDefinition(
          name: toolName,
          description: 'Test a local write permission boundary.',
          inputSchema: const {
            'type': 'object',
            'additionalProperties': false,
            'properties': {
              'value': {'type': 'integer'},
            },
            'required': ['value'],
          },
        ),
        accessLevel: ToolAccessLevel.write,
        target: 'local:test-state',
      );

  @override
  Map<String, dynamic> validateArguments(Map<String, dynamic> arguments) {
    if (arguments.length != 1 || arguments['value'] is! int) {
      throw const BuiltInToolException(
        'invalid_arguments',
        'Only an integer value is accepted.',
      );
    }
    return {'value': arguments['value']};
  }

  @override
  Future<Object?> execute(
    Map<String, dynamic> arguments,
    ToolInvocationContext context,
  ) async {
    context.cancellationToken.throwIfCancelled();
    writeCount++;
    return {'written': arguments['value']};
  }
}

final class _BlockingHttpAdapter implements HttpClientAdapter {
  final Completer<void> started = Completer<void>();
  final Completer<void> cancelled = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!started.isCompleted) started.complete();
    await cancelFuture;
    if (!cancelled.isCompleted) cancelled.complete();
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.cancel,
      message: 'cancelled',
    );
  }

  @override
  void close({bool force = false}) {}
}

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/ai_data_sharing_consent_service.dart';
import 'package:native_tavern/domain/services/external_call_audit_service.dart';

void main() {
  group('FileExternalCallAuditRepository', () {
    late Directory directory;
    late FileExternalCallAuditRepository repository;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('native_tavern_audit_');
      repository = FileExternalCallAuditRepository(dataPath: directory.path);
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test('persists only structured, redacted request metadata', () async {
      final record = ExternalCallAuditRecord.forRequest(
        requestUri: Uri.parse(
          'https://user:password@example.com/v1/chat/completions'
          '?key=super-secret',
        ),
        capabilityId: 'llm',
        dataTypes: const {
          ExternalDataType.prompt,
          ExternalDataType.chatText,
        },
        outcome: ExternalCallOutcome.succeeded,
        costAttribution: ExternalCostAttribution.userServiceAccount,
        statusCode: 200,
      );

      await repository.record(record);
      final records = await repository.readRecent();
      final raw = await File(
        '${directory.path}/audit/external_calls.jsonl',
      ).readAsString();

      expect(records.single.targetDomain, 'example.com');
      expect(raw, contains('example.com'));
      expect(raw, isNot(contains('super-secret')));
      expect(raw, isNot(contains('password')));
      expect(raw, isNot(contains('/v1/chat/completions')));
      expect(raw, isNot(contains('prompt text')));
    });

    test('serializes concurrent writes without losing records', () async {
      await Future.wait([
        for (var index = 0; index < 25; index++)
          repository.record(ExternalCallAuditRecord.forRequest(
            requestUri: Uri.parse('https://api$index.example.com/request'),
            capabilityId: 'imageGeneration',
            dataTypes: const {ExternalDataType.image},
            outcome: ExternalCallOutcome.succeeded,
            costAttribution: ExternalCostAttribution.userServiceAccount,
          )),
      ]);

      expect(await repository.readRecent(limit: 50), hasLength(25));
    });
  });

  test('Dio interceptor records outcome without inspecting request bodies',
      () async {
    final repository = MemoryExternalCallAuditRepository();
    final dio = Dio()..httpClientAdapter = _SuccessAdapter();
    dio.interceptors.add(ExternalCallAuditInterceptor(
      repository: repository,
      capabilityId: 'embedding',
      classifyData: (request) => const {ExternalDataType.documentText},
    ));

    await dio.post<void>(
      'https://api.example.com/v1/embeddings?key=hidden',
      data: {'input': 'private document body'},
    );

    final record = (await repository.readRecent()).single;
    expect(record.targetDomain, 'api.example.com');
    expect(record.outcome, ExternalCallOutcome.succeeded);
    expect(record.statusCode, 200);
    expect(record.dataTypes, {ExternalDataType.documentText});
    expect(
      record.costAttribution,
      ExternalCostAttribution.userServiceAccount,
    );
  });

  test('Dio interceptor records local cost and connection failures', () async {
    final localRepository = MemoryExternalCallAuditRepository();
    final localDio = Dio()..httpClientAdapter = _SuccessAdapter();
    localDio.interceptors.add(ExternalCallAuditInterceptor(
      repository: localRepository,
      capabilityId: 'llm',
      classifyData: (request) => const {ExternalDataType.chatText},
    ));
    await localDio.post<void>('http://localhost:11434/api/chat');

    final localRecord = (await localRepository.readRecent()).single;
    expect(
      localRecord.costAttribution,
      ExternalCostAttribution.noExternalCharge,
    );

    final failureRepository = MemoryExternalCallAuditRepository();
    final failingDio = Dio()..httpClientAdapter = _FailureAdapter();
    failingDio.interceptors.add(ExternalCallAuditInterceptor(
      repository: failureRepository,
      capabilityId: 'imageGeneration',
      classifyData: (request) => const {ExternalDataType.prompt},
    ));
    await expectLater(
      failingDio.post<void>('https://images.example.com/generate'),
      throwsA(isA<DioException>()),
    );

    final failureRecord = (await failureRepository.readRecent()).single;
    expect(failureRecord.outcome, ExternalCallOutcome.failed);
    expect(failureRecord.statusCode, isNull);
  });

  test('blocks remote requests before the network when consent is off',
      () async {
    final auditRepository = MemoryExternalCallAuditRepository();
    final consentRepository = MemoryAiDataSharingConsentRepository(
      choice: AiDataSharingChoice.localOnly,
    );
    final adapter = _CountingSuccessAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(ExternalCallAuditInterceptor(
      repository: auditRepository,
      capabilityId: 'llm',
      classifyData: (_) => const {ExternalDataType.chatText},
      consentRepository: consentRepository,
    ));

    await expectLater(
      dio.post<void>('https://fcloud.example.com/v1/chat'),
      throwsA(
        isA<DioException>().having(
          (error) => error.error,
          'consent error',
          isA<AiDataSharingConsentRequiredException>(),
        ),
      ),
    );

    expect(adapter.requestCount, 0);
    final record = (await auditRepository.readRecent()).single;
    expect(record.outcome, ExternalCallOutcome.cancelled);
    expect(record.targetDomain, 'fcloud.example.com');
  });

  test('local endpoints remain available without remote AI consent', () async {
    final consentRepository = MemoryAiDataSharingConsentRepository(
      choice: AiDataSharingChoice.localOnly,
    );
    final adapter = _CountingSuccessAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(ExternalCallAuditInterceptor(
      repository: MemoryExternalCallAuditRepository(),
      capabilityId: 'llm',
      classifyData: (_) => const {ExternalDataType.chatText},
      consentRepository: consentRepository,
    ));

    await dio.post<void>('http://192.168.1.20:11434/api/chat');
    expect(adapter.requestCount, 1);
  });

  test('allows remote requests after consent is granted', () async {
    final consentRepository = MemoryAiDataSharingConsentRepository(
      choice: AiDataSharingChoice.localOnly,
    );
    final adapter = _CountingSuccessAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(ExternalCallAuditInterceptor(
      repository: MemoryExternalCallAuditRepository(),
      capabilityId: 'llm',
      classifyData: (_) => const {ExternalDataType.chatText},
      consentRepository: consentRepository,
    ));

    await consentRepository.setChoice(AiDataSharingChoice.allowed);
    await dio.post<void>('https://api.example.com/v1/chat');
    expect(adapter.requestCount, 1);
  });
}

class _SuccessAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FailureAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: 'offline',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _CountingSuccessAdapter implements HttpClientAdapter {
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

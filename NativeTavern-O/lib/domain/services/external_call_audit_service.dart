import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:native_tavern/domain/services/ai_data_sharing_consent_service.dart';
import 'package:path/path.dart' as p;

enum ExternalDataType {
  metadata,
  prompt,
  chatText,
  documentText,
  image,
  audio,
  characterCard,
  toolArguments,
}

enum ExternalCallOutcome { succeeded, failed, cancelled }

enum ExternalCostAttribution { userServiceAccount, noExternalCharge, unknown }

class ExternalCallAuditRecord {
  final DateTime timestamp;
  final String targetDomain;
  final String capabilityId;
  final Set<ExternalDataType> dataTypes;
  final ExternalCallOutcome outcome;
  final ExternalCostAttribution costAttribution;
  final int? statusCode;
  final int durationMilliseconds;

  const ExternalCallAuditRecord({
    required this.timestamp,
    required this.targetDomain,
    required this.capabilityId,
    required this.dataTypes,
    required this.outcome,
    required this.costAttribution,
    this.statusCode,
    this.durationMilliseconds = 0,
  });

  factory ExternalCallAuditRecord.forRequest({
    required Uri requestUri,
    required String capabilityId,
    required Set<ExternalDataType> dataTypes,
    required ExternalCallOutcome outcome,
    required ExternalCostAttribution costAttribution,
    int? statusCode,
    int durationMilliseconds = 0,
    DateTime? timestamp,
  }) {
    return ExternalCallAuditRecord(
      timestamp: timestamp ?? DateTime.now().toUtc(),
      targetDomain: _targetDomain(requestUri),
      capabilityId: capabilityId,
      dataTypes: Set.unmodifiable(dataTypes),
      outcome: outcome,
      costAttribution: costAttribution,
      statusCode: statusCode,
      durationMilliseconds: durationMilliseconds,
    );
  }

  factory ExternalCallAuditRecord.fromJson(Map<String, dynamic> json) {
    return ExternalCallAuditRecord(
      timestamp: DateTime.parse(json['timestamp'] as String),
      targetDomain: json['targetDomain'] as String,
      capabilityId: json['capabilityId'] as String,
      dataTypes: (json['dataTypes'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .map(
            (value) => ExternalDataType.values.firstWhere(
              (candidate) => candidate.name == value,
            ),
          )
          .toSet(),
      outcome: ExternalCallOutcome.values.firstWhere(
        (candidate) => candidate.name == json['outcome'],
      ),
      costAttribution: ExternalCostAttribution.values.firstWhere(
        (candidate) => candidate.name == json['costAttribution'],
      ),
      statusCode: json['statusCode'] as int?,
      durationMilliseconds: json['durationMilliseconds'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toUtc().toIso8601String(),
        'targetDomain': targetDomain,
        'capabilityId': capabilityId,
        'dataTypes': dataTypes.map((type) => type.name).toList()..sort(),
        'outcome': outcome.name,
        'costAttribution': costAttribution.name,
        'statusCode': statusCode,
        'durationMilliseconds': durationMilliseconds,
      };

  static String _targetDomain(Uri uri) {
    if (uri.host.isEmpty) return 'local';
    final host = uri.host.toLowerCase();
    return uri.hasPort ? '$host:${uri.port}' : host;
  }
}

abstract class ExternalCallAuditRepository {
  Future<void> record(ExternalCallAuditRecord record);

  Future<List<ExternalCallAuditRecord>> readRecent({int limit = 100});
}

class NoopExternalCallAuditRepository implements ExternalCallAuditRepository {
  const NoopExternalCallAuditRepository();

  @override
  Future<void> record(ExternalCallAuditRecord record) async {}

  @override
  Future<List<ExternalCallAuditRecord>> readRecent({int limit = 100}) async {
    return const [];
  }
}

class MemoryExternalCallAuditRepository implements ExternalCallAuditRepository {
  final List<ExternalCallAuditRecord> _records = [];

  @override
  Future<void> record(ExternalCallAuditRecord record) async {
    _records.add(record);
  }

  @override
  Future<List<ExternalCallAuditRecord>> readRecent({int limit = 100}) async {
    final start = (_records.length - limit).clamp(0, _records.length);
    return _records.sublist(start).reversed.toList(growable: false);
  }
}

class FileExternalCallAuditRepository implements ExternalCallAuditRepository {
  static const _relativePath = 'audit/external_calls.jsonl';

  final String dataPath;
  Future<void> _writeTail = Future.value();

  FileExternalCallAuditRepository({required this.dataPath});

  File get _file => File(p.join(dataPath, _relativePath));

  @override
  Future<void> record(ExternalCallAuditRecord record) {
    final operation = _writeTail.then((_) async {
      final file = _file;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(record.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    _writeTail = operation.catchError((_) {});
    return operation;
  }

  @override
  Future<List<ExternalCallAuditRecord>> readRecent({int limit = 100}) async {
    if (limit <= 0) return const [];
    await _writeTail;
    final file = _file;
    if (!file.existsSync()) return const [];

    final lines = await file.readAsLines();
    final records = <ExternalCallAuditRecord>[];
    for (final line in lines.reversed) {
      if (records.length >= limit) break;
      if (line.trim().isEmpty) continue;
      try {
        records.add(
          ExternalCallAuditRecord.fromJson(
            jsonDecode(line) as Map<String, dynamic>,
          ),
        );
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      } on StateError {
        continue;
      }
    }
    return records;
  }
}

typedef ExternalDataClassifier = Set<ExternalDataType> Function(
    RequestOptions request);

class ExternalCallAuditInterceptor extends Interceptor {
  static const _startKey = 'nativeTavernAuditStartedAt';

  final ExternalCallAuditRepository repository;
  final String capabilityId;
  final ExternalCostAttribution costAttribution;
  final ExternalDataClassifier classifyData;
  final AiDataSharingConsentRepository consentRepository;
  final DateTime Function() _clock;

  ExternalCallAuditInterceptor({
    required this.repository,
    required this.capabilityId,
    required this.classifyData,
    this.costAttribution = ExternalCostAttribution.userServiceAccount,
    this.consentRepository = const AllowAllAiDataSharingConsentRepository(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startKey] = _clock().toUtc().toIso8601String();
    if (!_isLocalRequest(options.uri) &&
        !consentRepository.current.allowsRemoteAi) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          error: const AiDataSharingConsentRequiredException(),
          message:
              'Remote AI data sharing is disabled. Enable it in Settings > Privacy.',
        ),
      );
      return;
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _record(
      response.requestOptions,
      outcome: ExternalCallOutcome.succeeded,
      statusCode: response.statusCode,
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _record(
      err.requestOptions,
      outcome: err.type == DioExceptionType.cancel
          ? ExternalCallOutcome.cancelled
          : ExternalCallOutcome.failed,
      statusCode: err.response?.statusCode,
    );
    handler.next(err);
  }

  void _record(
    RequestOptions request, {
    required ExternalCallOutcome outcome,
    int? statusCode,
  }) {
    final now = _clock().toUtc();
    final startedAt = DateTime.tryParse(
      request.extra[_startKey] as String? ?? '',
    );
    final duration = startedAt == null
        ? 0
        : now.difference(startedAt).inMilliseconds.clamp(0, 1 << 31);

    final record = ExternalCallAuditRecord.forRequest(
      requestUri: request.uri,
      capabilityId: capabilityId,
      dataTypes: classifyData(request),
      outcome: outcome,
      costAttribution: _isLocalRequest(request.uri)
          ? ExternalCostAttribution.noExternalCharge
          : costAttribution,
      statusCode: statusCode,
      durationMilliseconds: duration,
      timestamp: now,
    );
    unawaited(repository.record(record).catchError((_) {}));
  }

  bool _isLocalRequest(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final address = InternetAddress.tryParse(host);
    if (address == null) return false;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 127 ||
          bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168);
    }

    final isLoopback =
        bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
    final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
    final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
    return isLoopback || isUniqueLocal || isLinkLocal;
  }
}

Set<ExternalDataType> metadataForGet(
  RequestOptions request,
  Set<ExternalDataType> transmittedData,
) {
  return request.method.toUpperCase() == 'GET'
      ? const {ExternalDataType.metadata}
      : transmittedData;
}

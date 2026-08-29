import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/domain/services/external_call_audit_service.dart';

final externalCallAuditRepositoryProvider =
    Provider<ExternalCallAuditRepository>((ref) {
  return FileExternalCallAuditRepository(
    dataPath: ref.watch(dataPathProvider),
  );
});

final recentExternalCallsProvider =
    FutureProvider<List<ExternalCallAuditRecord>>((ref) {
  return ref.watch(externalCallAuditRepositoryProvider).readRecent(limit: 20);
});

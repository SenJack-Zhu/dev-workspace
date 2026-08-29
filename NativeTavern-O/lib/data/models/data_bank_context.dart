import 'package:native_tavern/data/models/data_bank.dart';

const dataBankContextsMetadataKey = 'dataBankContexts';

enum DataBankRetrievalMode { localFts, semanticReranked, semanticFallback }

final class DataBankContextSettings {
  final bool enabled;
  final bool queryRewriteEnabled;
  final bool semanticRerankingEnabled;
  final int topK;
  final int maxTokens;
  final int maxChunksPerDocument;
  final double semanticWeight;

  const DataBankContextSettings({
    this.enabled = true,
    this.queryRewriteEnabled = false,
    this.semanticRerankingEnabled = false,
    this.topK = 6,
    this.maxTokens = 1200,
    this.maxChunksPerDocument = 2,
    this.semanticWeight = 0.65,
  });

  factory DataBankContextSettings.fromJson(Map<String, dynamic> json) {
    return DataBankContextSettings(
      enabled: json['enabled'] as bool? ?? true,
      queryRewriteEnabled: json['queryRewriteEnabled'] as bool? ?? false,
      semanticRerankingEnabled:
          json['semanticRerankingEnabled'] as bool? ?? false,
      topK: _boundedInt(json['topK'], fallback: 6, minimum: 1, maximum: 20),
      maxTokens: _boundedInt(
        json['maxTokens'],
        fallback: 1200,
        minimum: 128,
        maximum: 4096,
      ),
      maxChunksPerDocument: _boundedInt(
        json['maxChunksPerDocument'],
        fallback: 2,
        minimum: 1,
        maximum: 10,
      ),
      semanticWeight: ((json['semanticWeight'] as num?)?.toDouble() ?? 0.65)
          .clamp(0.0, 1.0),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'queryRewriteEnabled': queryRewriteEnabled,
        'semanticRerankingEnabled': semanticRerankingEnabled,
        'topK': topK,
        'maxTokens': maxTokens,
        'maxChunksPerDocument': maxChunksPerDocument,
        'semanticWeight': semanticWeight,
      };

  DataBankContextSettings copyWith({
    bool? enabled,
    bool? queryRewriteEnabled,
    bool? semanticRerankingEnabled,
    int? topK,
    int? maxTokens,
    int? maxChunksPerDocument,
    double? semanticWeight,
  }) {
    return DataBankContextSettings.fromJson({
      'enabled': enabled ?? this.enabled,
      'queryRewriteEnabled': queryRewriteEnabled ?? this.queryRewriteEnabled,
      'semanticRerankingEnabled':
          semanticRerankingEnabled ?? this.semanticRerankingEnabled,
      'topK': topK ?? this.topK,
      'maxTokens': maxTokens ?? this.maxTokens,
      'maxChunksPerDocument': maxChunksPerDocument ?? this.maxChunksPerDocument,
      'semanticWeight': semanticWeight ?? this.semanticWeight,
    });
  }
}

final class DataBankContextSource {
  final String label;
  final String documentName;
  final String snippet;
  final String injectedText;
  final DataBankCitation citation;

  const DataBankContextSource({
    required this.label,
    required this.documentName,
    required this.snippet,
    required this.injectedText,
    required this.citation,
  });

  factory DataBankContextSource.fromJson(Map<String, dynamic> json) {
    return DataBankContextSource(
      label: json['label'] as String,
      documentName: json['documentName'] as String,
      snippet: json['snippet'] as String,
      injectedText: json['injectedText'] as String,
      citation: DataBankCitation.fromJson(
        Map<String, dynamic>.from(json['citation'] as Map),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'documentName': documentName,
        'snippet': snippet,
        'injectedText': injectedText,
        'citation': citation.toJson(),
      };

  String get locationLabel {
    final locator = citation.locator;
    final details = [
      if (locator.chapter != null) locator.chapter!,
      if (locator.pageStart != null)
        locator.effectivePageEnd == locator.pageStart
            ? 'p. ${locator.pageStart}'
            : 'pp. ${locator.pageStart}-${locator.effectivePageEnd}',
      if (locator.startOffset != null)
        'chars ${locator.startOffset}-${locator.endOffset}',
    ];
    if (details.isNotEmpty) return details.join(' | ');
    return locator.sectionId == null ? '' : 'Section ${locator.sectionId}';
  }
}

final class DataBankContextSnapshot {
  final String sessionId;
  final String originalQuery;
  final List<String> queries;
  final DataBankRetrievalMode mode;
  final List<DataBankContextSource> sources;
  final String? fallbackReason;

  const DataBankContextSnapshot({
    required this.sessionId,
    required this.originalQuery,
    required this.queries,
    required this.mode,
    required this.sources,
    this.fallbackReason,
  });

  factory DataBankContextSnapshot.fromJson(Map<String, dynamic> json) {
    return DataBankContextSnapshot(
      sessionId: json['sessionId'] as String? ?? '',
      originalQuery: json['originalQuery'] as String? ?? '',
      queries: (json['queries'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      mode: DataBankRetrievalMode.values.firstWhere(
        (value) => value.name == json['mode'],
        orElse: () => DataBankRetrievalMode.localFts,
      ),
      sources: (json['sources'] as List<dynamic>? ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => DataBankContextSource.fromJson(
              Map<String, dynamic>.from(value),
            ),
          )
          .toList(growable: false),
      fallbackReason: json['fallbackReason'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'originalQuery': originalQuery,
        'queries': queries,
        'mode': mode.name,
        'sources': sources.map((source) => source.toJson()).toList(),
        if (fallbackReason != null) 'fallbackReason': fallbackReason,
      };
}

DataBankContextSnapshot? dataBankContextForSwipe(
  Map<String, dynamic> metadata,
  int swipeIndex,
) {
  final contexts = metadata[dataBankContextsMetadataKey];
  if (contexts is! List || swipeIndex < 0 || swipeIndex >= contexts.length) {
    return null;
  }
  final value = contexts[swipeIndex];
  if (value is! Map) return null;
  try {
    return DataBankContextSnapshot.fromJson(Map<String, dynamic>.from(value));
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> appendDataBankContextMetadata({
  required Map<String, dynamic> metadata,
  required int existingSwipeCount,
  required DataBankContextSnapshot? snapshot,
}) {
  final updated = Map<String, dynamic>.from(metadata);
  final existing = updated[dataBankContextsMetadataKey];
  final contexts =
      existing is List ? List<dynamic>.from(existing) : <dynamic>[];
  while (contexts.length < existingSwipeCount) {
    contexts.add(null);
  }
  contexts.add(snapshot?.toJson());
  if (contexts.any((value) => value != null)) {
    updated[dataBankContextsMetadataKey] = contexts;
  } else {
    updated.remove(dataBankContextsMetadataKey);
  }
  return updated;
}

Map<String, dynamic> removeDataBankContextMetadataAt({
  required Map<String, dynamic> metadata,
  required int swipeIndex,
}) {
  final updated = Map<String, dynamic>.from(metadata);
  final existing = updated[dataBankContextsMetadataKey];
  if (existing is! List || swipeIndex < 0 || swipeIndex >= existing.length) {
    return updated;
  }
  final contexts = List<dynamic>.from(existing)..removeAt(swipeIndex);
  if (contexts.any((value) => value != null)) {
    updated[dataBankContextsMetadataKey] = contexts;
  } else {
    updated.remove(dataBankContextsMetadataKey);
  }
  return updated;
}

int _boundedInt(
  Object? value, {
  required int fallback,
  required int minimum,
  required int maximum,
}) {
  return (value is num ? value.toInt() : fallback).clamp(minimum, maximum);
}

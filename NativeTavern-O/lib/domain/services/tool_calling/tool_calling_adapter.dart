import 'dart:convert';

import 'package:native_tavern/domain/models/tool_calling.dart';

abstract interface class ToolCallingAdapter {
  Map<String, dynamic> decorateRequest(
    Map<String, dynamic> baseRequest,
    ToolCallingConfiguration configuration,
  );

  ToolAssistantMessage parseResponse(Map<String, dynamic> response);

  ToolCallingStreamParser createStreamParser();

  Map<String, dynamic> encodeResult(ToolResultMessage result);
}

abstract interface class ToolCallingStreamParser {
  ToolStreamUpdate addChunk(Map<String, dynamic> chunk);

  ToolStreamUpdate finish({bool cancelled = false, String? reason});
}

String toolOutputAsText(Object? output) {
  return output is String ? output : jsonEncode(output);
}

Map<String, dynamic> toolOutputAsObject(ToolResultMessage result) {
  final output = result.output;
  if (result.isError) {
    return {'error': output};
  }
  if (output is Map<String, dynamic>) return output;
  return {'result': output};
}

Map<String, dynamic>? toolObject(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }
  return null;
}

List<Map<String, dynamic>> toolObjectList(Object? value) {
  if (value is! List) return const [];
  return value.map(toolObject).whereType<Map<String, dynamic>>().toList();
}

String toolString(Object? value) => value is String ? value : '';

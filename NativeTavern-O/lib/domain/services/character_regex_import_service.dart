import 'package:native_tavern/data/models/regex_script.dart';

/// Converts SillyTavern character-card regex extensions into NativeTavern
/// character-scoped scripts.
List<RegexScript> parseEmbeddedRegexScripts(
  Map<String, dynamic> extensions, {
  required String characterId,
  DateTime? importedAt,
}) {
  dynamic rawScripts =
      extensions['regex_scripts'] ?? extensions['regexScripts'];
  if (rawScripts is Map<String, dynamic>) {
    rawScripts = rawScripts['scripts'];
  }
  if (rawScripts is! List) return const [];

  final timestamp = importedAt ?? DateTime.now();
  final scripts = <RegexScript>[];
  for (var index = 0; index < rawScripts.length; index++) {
    final raw = rawScripts[index];
    if (raw is! Map) continue;
    final json = Map<String, dynamic>.from(raw);
    final findRegex = json['findRegex']?.toString() ?? '';
    if (findRegex.isEmpty) continue;

    final sourceId = json['id']?.toString();
    final idSuffix = sourceId?.isNotEmpty == true ? sourceId! : '$index';
    final placement = _parsePlacement(json['placement']);
    final markdownPlacement = _containsPlacement(json['placement'], 0);

    scripts.add(
      RegexScript(
        id: 'card:$characterId:$idSuffix',
        scriptName: json['scriptName']?.toString().trim().isNotEmpty == true
            ? json['scriptName'].toString().trim()
            : 'Imported Regex ${index + 1}',
        description: json['description']?.toString(),
        disabled: json['disabled'] == true,
        findRegex: findRegex,
        replaceString: json['replaceString']?.toString() ?? '',
        trimStrings: _stringList(json['trimStrings']),
        placement: placement,
        scriptType: RegexScriptType.character,
        markdownOnly: json['markdownOnly'] == true || markdownPlacement,
        promptOnly: json['promptOnly'] == true,
        runOnEdit: json['runOnEdit'] == true,
        substituteRegex: _parseSubstituteRegex(json['substituteRegex']),
        minDepth: _intValue(json['minDepth']),
        maxDepth: _intValue(json['maxDepth']),
        order: _intValue(json['order']) ?? index,
        characterId: characterId,
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );
  }
  return scripts;
}

List<RegexPlacement> _parsePlacement(dynamic value) {
  final raw = value is List ? value : const <dynamic>[];
  final placements = <RegexPlacement>[];
  for (final item in raw) {
    final placement = switch (item) {
      1 || 'userInput' => RegexPlacement.userInput,
      2 || 'aiOutput' => RegexPlacement.aiOutput,
      3 || 'slashCommand' => RegexPlacement.slashCommand,
      5 || 'worldInfo' => RegexPlacement.worldInfo,
      6 || 'reasoning' => RegexPlacement.reasoning,
      _ => null,
    };
    if (placement != null && !placements.contains(placement)) {
      placements.add(placement);
    }
  }
  return placements.isEmpty ? const [RegexPlacement.aiOutput] : placements;
}

bool _containsPlacement(dynamic value, int expected) =>
    value is List && value.any((item) => item == expected);

List<String> _stringList(dynamic value) => value is List
    ? value.whereType<Object>().map((item) => item.toString()).toList()
    : const [];

int? _intValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

SubstituteRegex _parseSubstituteRegex(dynamic value) => switch (value) {
      1 || 'raw' => SubstituteRegex.raw,
      2 || 'escaped' => SubstituteRegex.escaped,
      _ => SubstituteRegex.none,
    };

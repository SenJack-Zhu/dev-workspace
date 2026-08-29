import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/regex_script.dart';
import 'package:native_tavern/domain/services/character_regex_import_service.dart';

void main() {
  test('maps SillyTavern embedded regex fields and placements', () {
    final importedAt = DateTime.utc(2026, 8, 7);
    final scripts = parseEmbeddedRegexScripts(
      {
        'regex_scripts': [
          {
            'id': 'status-card',
            'scriptName': 'Status card',
            'findRegex': r'/<status>([\s\S]*?)<\/status>/gi',
            'replaceString': r'$1',
            'trimStrings': ['```'],
            'placement': [0, 1, 2, 3, 5, 6],
            'disabled': false,
            'runOnEdit': true,
            'substituteRegex': 2,
            'minDepth': '1',
            'maxDepth': 8,
          },
        ],
      },
      characterId: 'character-1',
      importedAt: importedAt,
    );

    expect(scripts, hasLength(1));
    final script = scripts.single;
    expect(script.id, 'card:character-1:status-card');
    expect(script.scriptType, RegexScriptType.character);
    expect(script.characterId, 'character-1');
    expect(script.markdownOnly, isTrue);
    expect(script.placement, containsAll(RegexPlacement.values));
    expect(script.substituteRegex, SubstituteRegex.escaped);
    expect(script.minDepth, 1);
    expect(script.maxDepth, 8);
    expect(script.createdAt, importedAt);
  });

  test('ignores malformed entries and supports wrapped script lists', () {
    final scripts = parseEmbeddedRegexScripts({
      'regexScripts': {
        'scripts': [
          {'scriptName': 'Missing pattern'},
          {
            'findRegex': 'hello',
            'replaceString': 'world',
            'placement': ['aiOutput'],
          },
        ],
      },
    }, characterId: 'character-2');

    expect(scripts, hasLength(1));
    expect(scripts.single.scriptName, 'Imported Regex 2');
    expect(scripts.single.placement, [RegexPlacement.aiOutput]);
  });
}

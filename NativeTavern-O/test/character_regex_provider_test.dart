import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/regex_script.dart';
import 'package:native_tavern/presentation/providers/regex_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('embedded import waits for existing character scripts to load',
      () async {
    final timestamp = DateTime.utc(2026, 8, 7);
    final existing = _script(
      id: 'existing',
      characterId: 'character-1',
      timestamp: timestamp,
    );
    SharedPreferences.setMockInitialValues({
      'character_regex_scripts_character-1': jsonEncode([existing.toJson()]),
    });
    final notifier = CharacterRegexScriptsNotifier('character-1');

    final imported = _script(
      id: 'card:character-1:embedded',
      characterId: 'character-1',
      timestamp: timestamp,
    );
    await notifier.importEmbeddedScripts([imported]);

    expect(notifier.state.map((script) => script.id), [
      'existing',
      'card:character-1:embedded',
    ]);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(
      prefs.getString('character_regex_scripts_character-1')!,
    ) as List<dynamic>;
    expect(saved, hasLength(2));
    notifier.dispose();
  });
}

RegexScript _script({
  required String id,
  required String characterId,
  required DateTime timestamp,
}) {
  return RegexScript(
    id: id,
    scriptName: id,
    findRegex: 'before',
    replaceString: 'after',
    placement: const [RegexPlacement.aiOutput],
    scriptType: RegexScriptType.character,
    characterId: characterId,
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

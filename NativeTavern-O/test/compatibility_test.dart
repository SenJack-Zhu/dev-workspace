import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/ai_preset.dart';
import 'package:native_tavern/data/models/world_info.dart';
import 'package:native_tavern/domain/services/import_service.dart';
import 'package:native_tavern/domain/services/macro_service.dart';
import 'package:native_tavern/domain/services/world_info_import.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Fake path provider so avatar saving works in the test environment
class _FakePathProvider extends PathProviderPlatform {
  final String path;
  _FakePathProvider(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

/// End-to-end compatibility tests using REAL SillyTavern content:
/// - default_Seraphina.png: the character card shipped with SillyTavern
/// - Eldoria.json: Seraphina's world info book
/// - st_preset_default.json: SillyTavern's default OpenAI preset
void main() {
  group('Real ST character card (Seraphina PNG)', () {
    late ImportService importService;
    late Directory tempDir;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempDir = Directory.systemTemp.createTempSync('nt_compat_test');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      importService = ImportService(tempDir.path);
    });

    tearDownAll(() {
      tempDir.deleteSync(recursive: true);
    });

    test('imports from PNG tEXt chunk with all core fields', () async {
      final bytes =
          File('test/fixtures/default_Seraphina.png').readAsBytesSync();
      final character = await importService.importFromPngBytes(bytes);

      expect(character.name, 'Seraphina');
      expect(character.description, isNotEmpty);
      expect(character.firstMessage, isNotEmpty);
      // The card's texts reference the user via macros
      expect(character.description.contains('{{user}}'), isTrue);
      // Avatar was extracted and saved
      expect(character.assets?.avatarPath, isNotNull);
      expect(File(character.assets!.avatarPath!).existsSync(), isTrue);
    });

    test('card macros render with MacroService', () async {
      final bytes =
          File('test/fixtures/default_Seraphina.png').readAsBytesSync();
      final character = await importService.importFromPngBytes(bytes);

      const context = MacroContext(
        userName: 'Lucy',
        characterName: 'Seraphina',
      );
      // The description references {{user}}; the first message does not
      final rendered = MacroService(context).process(character.description);

      expect(rendered.contains('{{user}}'), isFalse);
      expect(rendered.contains('{{char}}'), isFalse);
      expect(rendered, contains('Lucy'));
    });

    test('imports compressed zTXt chara metadata', () async {
      final card = {
        'spec': 'chara_card_v2',
        'data': {
          'name': 'Compressed Card',
          'first_mes': 'Hello',
          'alternate_greetings': ['Hi again'],
        },
      };
      final payload = base64Encode(utf8.encode(jsonEncode(card)));
      final metadata = <int>[
        ...latin1.encode('chara'),
        0,
        0,
        ...zlib.encode(latin1.encode(payload)),
      ];

      final character = await importService.importFromPngBytes(
        _pngWithTextChunk('zTXt', metadata),
      );
      expect(character.name, 'Compressed Card');
      expect(character.alternateGreetings, ['Hi again']);
    });

    test('imports raw JSON from iTXt ccv3 metadata', () async {
      final card = {
        'spec': 'chara_card_v3',
        'data': {
          'name': 'V3 Card',
          'first_mes': 'Hello from V3',
        },
      };
      final metadata = <int>[
        ...latin1.encode('ccv3'),
        0,
        0,
        0,
        0,
        0,
        ...utf8.encode(jsonEncode(card)),
      ];

      final character = await importService.importFromPngBytes(
        _pngWithTextChunk('iTXt', metadata),
      );
      expect(character.name, 'V3 Card');
      expect(character.firstMessage, 'Hello from V3');
    });
  });

  group('Real ST world info book (Eldoria)', () {
    late Map<String, dynamic> json;

    setUpAll(() {
      json = jsonDecode(File('test/fixtures/Eldoria.json').readAsStringSync())
          as Map<String, dynamic>;
    });

    test('parses all entries with behavioral fields preserved', () {
      final entries = WorldInfoImport.parseEntries(json, 'wi-test');

      expect(entries, isNotEmpty);

      final eldoria = entries.firstWhere((e) => e.keys.contains('eldoria'));
      expect(eldoria.enabled, isTrue); // disable: false
      expect(eldoria.constant, isFalse);
      expect(eldoria.selective, isTrue);
      expect(eldoria.insertionOrder, 100); // order: 100
      expect(eldoria.position, WorldInfoPosition.before); // position: 0
      expect(eldoria.probability, 100);
      expect(eldoria.depth, 4);
      expect(eldoria.timedEffects.sticky, 0);
      expect(eldoria.content, contains('{{char}}'));
      expect(eldoria.keys, containsAll(['eldoria', 'forest', 'wood']));
    });

    test('entry content macros render correctly', () {
      final entries = WorldInfoImport.parseEntries(json, 'wi-test');
      const context = MacroContext(
        userName: 'Lucy',
        characterName: 'Seraphina',
      );
      final rendered = MacroService(context).process(entries.first.content);
      expect(rendered.contains('{{char}}'), isFalse);
      expect(rendered, contains('Seraphina'));
    });
  });

  group('Synthetic ST world info advanced fields', () {
    test('disable/position/depth/timed effects/role/recursion round-trip', () {
      final entry = WorldInfoImport.parseEntry({
        'uid': 7,
        'key': ['secret'],
        'keysecondary': ['password'],
        'content': 'The vault code is 4711.',
        'comment': 'vault',
        'constant': true,
        'selective': true,
        'order': 42,
        'position': 4, // atDepth
        'depth': 2,
        'disable': true,
        'probability': 50,
        'useProbability': true,
        'role': 2, // assistant
        'sticky': 3,
        'cooldown': 5,
        'delay': 2,
        'preventRecursion': true,
        'excludeRecursion': true,
        'caseSensitive': true,
        'group': 'vault-group',
        'groupWeight': 150,
      }, 'wi-test', 'entry-7');

      expect(entry.enabled, isFalse); // disable: true
      expect(entry.constant, isTrue);
      expect(entry.insertionOrder, 42);
      expect(entry.position, WorldInfoPosition.atDepth);
      expect(entry.depth, 2);
      expect(entry.probability, 50);
      expect(entry.useProbability, isTrue);
      expect(entry.role, WorldInfoRole.assistant);
      expect(entry.timedEffects.sticky, 3);
      expect(entry.timedEffects.cooldown, 5);
      expect(entry.timedEffects.delay, 2);
      expect(entry.preventRecursion, isTrue);
      expect(entry.excludeRecursion, isTrue);
      expect(entry.caseSensitive, isTrue);
      expect(entry.group, 'vault-group');
      expect(entry.groupWeight, 150);
      expect(entry.secondaryKeys, ['password']);
    });
  });

  group('Real ST preset (Default.json)', () {
    late Map<String, dynamic> json;

    setUpAll(() {
      json = jsonDecode(
              File('test/fixtures/st_preset_default.json').readAsStringSync())
          as Map<String, dynamic>;
    });

    test('imports generation settings and prompt manager config', () {
      final preset = AIPreset.fromSillyTavernJson(json, 'preset-test');

      expect(preset.generationSettings.temperature, 1.0);
      expect(preset.promptManagerConfig, isNotNull);

      final sections = preset.promptManagerConfig!.sections;
      expect(sections, isNotEmpty);

      // Core ST identifiers must be represented
      final identifiers =
          sections.map((s) => s.identifier).whereType<String>().toSet();
      expect(identifiers, contains('main'));
      expect(identifiers, contains('chatHistory'));
      expect(identifiers, contains('charDescription'));
      expect(identifiers, contains('worldInfoBefore'));

      // The main prompt content survives import
      final main = sections.firstWhere((s) => s.identifier == 'main');
      expect(main.content, contains("{{char}}'s next reply"));
    });

    test('prompt_order determines section order', () {
      final preset = AIPreset.fromSillyTavernJson(json, 'preset-test');
      final sorted = preset.promptManagerConfig!.sections.toList()
        ..sort((a, b) => a.order.compareTo(b.order));

      final orderedIds =
          sorted.map((s) => s.identifier).whereType<String>().toList();
      // In ST's default order, main comes before chatHistory,
      // and worldInfoBefore comes before charDescription
      expect(orderedIds.indexOf('main'),
          lessThan(orderedIds.indexOf('chatHistory')));
      expect(orderedIds.indexOf('worldInfoBefore'),
          lessThan(orderedIds.indexOf('charDescription')));
    });
  });

  group('Community status-bar card patterns', () {
    test('scoped if + variables + stable pick in one pass', () {
      const context = MacroContext(
        userName: 'Lucy',
        characterName: 'Nyx',
        chatId: 'compat-chat',
        characterDescription: 'A mysterious guide',
      );
      final service = MacroService(context);

      // Typical community card: conditional status header + variables
      const template = '{{if description}}'
          '[STATUS] HP: {{.hp??100}} | Mood: {{pick::calm::wary::playful}}'
          '{{else}}no card{{/if}}';
      final result = service.process(template);

      expect(result, startsWith('[STATUS] HP: 100 | Mood: '));
      // {{pick}} must be stable across re-renders in the same chat
      final again = service.process(template);
      expect(again, result);
    });
  });
}

Uint8List _pngWithTextChunk(String type, List<int> data) {
  List<int> chunk(String chunkType, List<int> chunkData) => [
        (chunkData.length >> 24) & 0xff,
        (chunkData.length >> 16) & 0xff,
        (chunkData.length >> 8) & 0xff,
        chunkData.length & 0xff,
        ...ascii.encode(chunkType),
        ...chunkData,
        0,
        0,
        0,
        0,
      ];

  return Uint8List.fromList([
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ...chunk(type, data),
    ...chunk('IEND', const []),
  ]);
}

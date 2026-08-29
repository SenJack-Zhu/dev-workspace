import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/macro_service.dart';
import 'package:native_tavern/domain/services/variables_service.dart';

void main() {
  group('Macros 2.0 - scoped {{if}}', () {
    const context = MacroContext(
      userName: 'Alice',
      characterName: 'Bob',
      characterDescription: 'A friendly bot',
      characterPersonality: '',
      characterVersion: '1.0',
    );
    final service = MacroService(context);

    test('truthy condition returns then-branch', () {
      expect(
        service.process('{{if description}}has desc{{/if}}'),
        'has desc',
      );
    });

    test('falsy condition returns empty', () {
      expect(
        service.process('{{if personality}}has personality{{/if}}'),
        '',
      );
    });

    test('else branch', () {
      expect(
        service.process('{{if personality}}yes{{else}}no{{/if}}'),
        'no',
      );
    });

    test('inverted condition', () {
      expect(
        service.process('{{if !personality}}empty{{/if}}'),
        'empty',
      );
    });

    test('nested blocks', () {
      expect(
        service.process(
            '{{if description}}outer {{if charVersion}}inner{{/if}}{{/if}}'),
        'outer inner',
      );
    });

    test('macros expand in chosen branch', () {
      expect(
        service.process('{{if description}}Hi {{user}}{{/if}}'),
        'Hi Alice',
      );
    });

    test('lazy: literal falsy value keeps else', () {
      expect(
        service.process('{{if 0}}then{{else}}other{{/if}}'),
        'other',
      );
      expect(
        service.process('{{if off}}then{{else}}other{{/if}}'),
        'other',
      );
      expect(
        service.process('{{if false}}then{{else}}other{{/if}}'),
        'other',
      );
    });

    test('inline if with :: still works', () {
      expect(service.process('{{if::x::yes}}'), 'yes');
      expect(service.process('{{if:: ::yes}}'), '');
      expect(service.process('{{if description::yes}}'), 'yes');
    });
  });

  group('Macros 2.0 - variable shorthands', () {
    const chatId = 'test-chat-macros';
    const context = MacroContext(chatId: chatId);
    final service = MacroService(context);
    final vars = VariablesService.instance;

    setUp(() {
      vars.clearLocalVariables(chatId);
    });

    test('assignment and get', () {
      expect(service.process('{{.hp=10}}'), '');
      expect(service.process('{{.hp}}'), '10');
    });

    test('add and subtract', () {
      service.process('{{.hp=10}}{{.hp+=5}}{{.hp-=3}}');
      expect(service.process('{{.hp}}'), '12');
    });

    test('increment and decrement', () {
      service.process('{{.n=1}}{{.n++}}{{.n++}}{{.n--}}');
      expect(service.process('{{.n}}'), '2');
    });

    test('comparison operators', () {
      service.process('{{.hp=10}}');
      expect(service.process('{{.hp==10}}'), 'true');
      expect(service.process('{{.hp!=10}}'), 'false');
      expect(service.process('{{.hp>5}}'), 'true');
      expect(service.process('{{.hp<5}}'), 'false');
      expect(service.process('{{.hp>=10}}'), 'true');
      expect(service.process('{{.hp<=9}}'), 'false');
    });

    test('fallback operators', () {
      expect(service.process('{{.missing??backup}}'), 'backup');
      service.process('{{.exists=val}}');
      expect(service.process('{{.exists??backup}}'), 'val');
      service.process('{{.empty=}}');
      expect(service.process('{{.empty||fallback}}'), 'fallback');
    });

    test('conditional assignment', () {
      service.process('{{.a??=first}}{{.a??=second}}');
      expect(service.process('{{.a}}'), 'first');
    });

    test('undefined variable renders empty', () {
      expect(service.process('{{.notset}}'), '');
    });

    test('shorthand in if condition', () {
      service.process('{{.flag=1}}');
      expect(service.process('{{if .flag}}on{{else}}off{{/if}}'), 'on');
      expect(service.process('{{if .nothere}}on{{else}}off{{/if}}'), 'off');
    });
  });

  group('Macros 2.0 - new macros', () {
    const context = MacroContext(
      characterName: 'Bob',
      characterFirstMessage: 'Hello!',
      alternateGreetings: ['Alt one', 'Alt two'],
      maxContextTokens: 32768,
      maxResponseTokens: 1024,
      groupCharacterNames: ['Bob', 'Carol'],
    );
    final service = MacroService(context);

    test('greeting with index', () {
      expect(service.process('{{greeting}}'), 'Hello!');
      expect(service.process('{{greeting::0}}'), 'Hello!');
      expect(service.process('{{greeting::1}}'), 'Alt one');
      expect(service.process('{{greeting::2}}'), 'Alt two');
      expect(service.process('{{greeting::3}}'), '');
      expect(service.process('{{charFirstMessage}}'), 'Hello!');
    });

    test('token limit macros', () {
      expect(service.process('{{maxContextTokens}}'), '32768');
      expect(service.process('{{maxContext}}'), '32768');
      expect(service.process('{{maxPromptTokens}}'), '32768');
      expect(service.process('{{maxResponseTokens}}'), '1024');
      expect(service.process('{{maxResponse}}'), '1024');
    });

    test('group macro', () {
      expect(service.process('{{group}}'), 'Bob, Carol');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/slash_command_service.dart';

void main() {
  group('/imagine command', () {
    final service = SlashCommandService();

    test('parses prompt and options', () {
      final result = service.parse('/imagine portrait --width 1024');

      expect(result.error, isNull);
      expect(result.command, SlashCommands.imagine);
      expect(result.argument, 'portrait --width 1024');
    });

    test('supports /sd alias', () {
      final result = service.parse('/sd landscape');

      expect(result.error, isNull);
      expect(result.command, SlashCommands.imagine);
      expect(result.argument, 'landscape');
    });

    test('requires a prompt', () {
      final result = service.parse('/imagine');

      expect(result.error, contains('requires an argument'));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/context_window_service.dart';

void main() {
  final service = ContextWindowService();

  test('leaves a request within its input budget unchanged', () {
    final messages = [
      {'role': 'system', 'content': 'Stay in character.'},
      {'role': 'user', 'content': 'Hello'},
    ];

    final result = service.fit(
      messages,
      contextLength: 4096,
      responseTokens: 512,
    );

    expect(result.messages, messages);
    expect(result.removedMessages, 0);
    expect(result.truncatedMessages, 0);
  });

  test('drops oldest history while preserving system and recent turns', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'Primary instructions'},
      for (var index = 0; index < 10; index++)
        {
          'role': index.isEven ? 'user' : 'assistant',
          'content': 'old-$index ${'x' * 500}',
        },
      {'role': 'user', 'content': 'latest request'},
    ];

    final result = service.fit(
      messages,
      contextLength: 1024,
      responseTokens: 256,
    );

    expect(result.estimatedTokens, lessThanOrEqualTo(result.inputBudget));
    expect(result.removedMessages, greaterThan(0));
    expect(result.messages.first['content'], 'Primary instructions');
    expect(result.messages.last['content'], 'latest request');
  });

  test(
    'truncates an oversized newest message instead of exceeding context',
    () {
      final result = service.fit(
        [
          {'role': 'system', 'content': 'Rules'},
          {'role': 'user', 'content': 'important-tail ${'x' * 10000}'},
        ],
        contextLength: 512,
        responseTokens: 128,
      );

      expect(result.estimatedTokens, lessThanOrEqualTo(result.inputBudget));
      expect(result.truncatedMessages, greaterThan(0));
      expect(result.messages.last['content'], startsWith('[truncated]'));
    },
  );

  test('caps requested output so input retains at least half the window', () {
    expect(
      service.effectiveResponseTokenLimit(
        contextLength: 4096,
        requestedTokens: 8192,
      ),
      2048,
    );
  });

  test('preserves the primary system prompt when it is not first', () {
    final result = service.fit(
      [
        {'role': 'user', 'content': 'old preamble ${'x' * 1000}'},
        {'role': 'system', 'content': 'Primary instructions'},
        for (var index = 0; index < 8; index++)
          {'role': 'user', 'content': 'history-$index ${'x' * 500}'},
        {'role': 'user', 'content': 'latest request'},
      ],
      contextLength: 768,
      responseTokens: 192,
    );

    expect(
      result.messages.any(
        (message) => message['content'] == 'Primary instructions',
      ),
      isTrue,
    );
    expect(result.messages.last['content'], 'latest request');
  });

  test('keeps output within half of very small context windows', () {
    expect(
      service.effectiveResponseTokenLimit(
        contextLength: 64,
        requestedTokens: 512,
      ),
      32,
    );
  });
}

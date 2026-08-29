import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/models/tool_calling.dart';

void main() {
  group('ToolDefinition and configuration', () {
    test('validates schemas, names, choices, and recursion limits', () {
      final weather = _weatherTool();
      final configuration = ToolCallingConfiguration.enabled(
        tools: [weather],
        choice: ToolChoice.named('weather'),
        maxRecursionDepth: 3,
      );

      expect(configuration.enabled, isTrue);
      expect(configuration.choice.toolName, 'weather');
      expect(configuration.maxRecursionDepth, 3);
      expect(
        () => ToolDefinition(
          name: 'bad name',
          description: 'Invalid',
          inputSchema: const {'type': 'object'},
        ),
        _protocolError('invalid_tool_name'),
      );
      expect(
        () => ToolCallingConfiguration.enabled(
          tools: [weather, weather],
        ),
        _protocolError('duplicate_tool_name'),
      );
      expect(
        () => ToolCallingConfiguration.enabled(
          tools: [weather],
          choice: ToolChoice.named('missing'),
        ),
        _protocolError('unknown_tool_choice'),
      );
    });
  });

  group('ToolCallStreamAccumulator', () {
    test('accumulates fragmented parallel calls without crossing slots', () {
      final accumulator = ToolCallStreamAccumulator();
      accumulator.add(const ToolCallDelta(
        slot: '0',
        id: 'call_weather',
        name: 'weather',
        argumentsFragment: '{"city":"',
      ));
      accumulator.add(const ToolCallDelta(
        slot: '1',
        id: 'call_time',
        name: 'time',
        argumentsFragment: '{"zone":"',
      ));
      accumulator.add(const ToolCallDelta(
        slot: '0',
        argumentsFragment: 'Singapore"}',
      ));
      accumulator.add(const ToolCallDelta(
        slot: '1',
        argumentsFragment: 'Asia/Singapore"}',
      ));

      final calls = accumulator.completeAll();

      expect(calls, hasLength(2));
      expect(calls[0].arguments, {'city': 'Singapore'});
      expect(calls[1].arguments, {'zone': 'Asia/Singapore'});
      expect(
          calls.every((call) => call.status == ToolCallStatus.ready), isTrue);
    });

    test('preserves malformed JSON as an explicit invalid call', () {
      final accumulator = ToolCallStreamAccumulator();
      final call = accumulator.add(const ToolCallDelta(
        slot: '0',
        id: 'call_broken',
        name: 'weather',
        argumentsFragment: '{"city":',
        isFinal: true,
      ));

      expect(call?.status, ToolCallStatus.invalidArguments);
      expect(call?.rawArguments, '{"city":');
      expect(call?.error, isNotEmpty);
    });

    test('rejects duplicate IDs across parallel stream slots', () {
      final accumulator = ToolCallStreamAccumulator();
      accumulator.add(const ToolCallDelta(
        slot: '0',
        id: 'duplicate',
        name: 'weather',
      ));

      expect(
        () => accumulator.add(const ToolCallDelta(
          slot: '1',
          id: 'duplicate',
          name: 'time',
        )),
        _protocolError('duplicate_call_id'),
      );
    });
  });

  test('recursion contexts honor cancellation and depth limits', () {
    final controller = ToolCancellationController();
    var cancellationReason = '';
    controller.token.whenCancelled((reason) {
      cancellationReason = reason.toString();
    });
    final root = ToolInvocationContext(
      maxDepth: 2,
      cancellationToken: controller.token,
    );
    final depthTwo = root.next().next();

    expect(depthTwo.depth, 2);
    expect(() => depthTwo.next(), _protocolError('recursion_limit'));

    controller.cancel('user stopped');
    expect(cancellationReason, 'user stopped');
    expect(controller.token.isCancelled, isTrue);
    expect(() => root.next(), _protocolError('cancelled'));
  });
}

ToolDefinition _weatherTool() {
  return ToolDefinition(
    name: 'weather',
    description: 'Read the weather for a city.',
    inputSchema: const {
      'type': 'object',
      'properties': {
        'city': {'type': 'string'},
      },
      'required': ['city'],
    },
  );
}

Matcher _protocolError(String code) {
  return throwsA(
    isA<ToolProtocolException>().having(
      (error) => error.code,
      'code',
      code,
    ),
  );
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/live2d_render_lifecycle.dart';

void main() {
  test('applies a background state that arrived before native attachment',
      () async {
    final applied = <bool>[];
    final lifecycle = Live2DRenderingLifecycle(
      initialPaused: true,
      applyPaused: (paused) async => applied.add(paused),
    );

    expect(applied, isEmpty);
    await lifecycle.setAttached(true);

    expect(applied, [true]);
    expect(lifecycle.appliedPaused, isTrue);
  });

  test('serializes rapid lifecycle changes and preserves the latest state',
      () async {
    final firstCall = Completer<void>();
    final applied = <bool>[];
    final lifecycle = Live2DRenderingLifecycle(
      applyPaused: (paused) async {
        applied.add(paused);
        if (applied.length == 1) await firstCall.future;
      },
    );

    final attach = lifecycle.setAttached(true);
    final pause = lifecycle.setAppActive(false);
    final resume = lifecycle.setAppActive(true);
    firstCall.complete();
    await Future.wait([attach, pause, resume]);

    expect(applied.last, isFalse);
    expect(lifecycle.desiredPaused, isFalse);
    expect(lifecycle.appliedPaused, isFalse);
  });

  test('pauses while the model route is covered', () async {
    final applied = <bool>[];
    final lifecycle = Live2DRenderingLifecycle(
      applyPaused: (paused) async => applied.add(paused),
    );

    await lifecycle.setAttached(true);
    await lifecycle.setViewVisible(false);

    expect(applied, [false, true]);
    expect(lifecycle.desiredPaused, isTrue);
    expect(lifecycle.appliedPaused, isTrue);
  });

  test('app resume cannot resume a model on a covered route', () async {
    final applied = <bool>[];
    final lifecycle = Live2DRenderingLifecycle(
      applyPaused: (paused) async => applied.add(paused),
    );

    await lifecycle.setAttached(true);
    await lifecycle.setViewVisible(false);
    await lifecycle.setAppActive(false);
    await lifecycle.setAppActive(true);

    expect(applied, [false, true]);
    expect(lifecycle.desiredPaused, isTrue);
    expect(lifecycle.appliedPaused, isTrue);
  });

  test('resumes after a covered route becomes visible again', () async {
    final applied = <bool>[];
    final lifecycle = Live2DRenderingLifecycle(
      applyPaused: (paused) async => applied.add(paused),
    );

    await lifecycle.setAttached(true);
    await lifecycle.setViewVisible(false);
    await lifecycle.setViewVisible(true);

    expect(applied, [false, true, false]);
    expect(lifecycle.desiredPaused, isFalse);
    expect(lifecycle.appliedPaused, isFalse);
  });

  test('detachment pauses the native renderer before Flutter unmounts',
      () async {
    final applied = <bool>[];
    final lifecycle = Live2DRenderingLifecycle(
      applyPaused: (paused) async => applied.add(paused),
    );

    await lifecycle.setAttached(true);
    await lifecycle.setAttached(false);

    expect(lifecycle.isAttached, isFalse);
    expect(applied, [false, true]);
    expect(lifecycle.appliedPaused, isTrue);
    expect(lifecycle.desiredPaused, isTrue);
  });

  test('teardown pause stops the native loop even before dispose', () async {
    final applied = <bool>[];
    final lifecycle = Live2DRenderingLifecycle(
      applyPaused: (paused) async => applied.add(paused),
    );

    await lifecycle.setAttached(true);
    await lifecycle.pauseForTeardown();

    expect(applied, [false, true]);
    expect(lifecycle.desiredPaused, isTrue);
    expect(lifecycle.appliedPaused, isTrue);
  });

  test('a failed native call can be retried', () async {
    var attempts = 0;
    final lifecycle = Live2DRenderingLifecycle(
      applyPaused: (_) async {
        attempts++;
        if (attempts == 1) throw StateError('native view unavailable');
      },
    );

    await expectLater(lifecycle.setAttached(true), throwsStateError);
    expect(lifecycle.lastError, isA<StateError>());

    await lifecycle.setAppActive(false);
    expect(attempts, 2);
    expect(lifecycle.appliedPaused, isTrue);
    expect(lifecycle.lastError, isNull);
  });

  test('dispose requests a final pause of the native renderer', () async {
    final applied = <bool>[];
    final lifecycle = Live2DRenderingLifecycle(
      applyPaused: (paused) async => applied.add(paused),
    );

    await lifecycle.setAttached(true);
    lifecycle.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(applied, [false, true]);
    expect(lifecycle.isAttached, isFalse);
  });
}

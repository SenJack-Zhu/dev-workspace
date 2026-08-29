import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/live2d_ios_render_scale_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(Live2DIOSRenderScaleService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('reports whether an iOS Live2D surface was synchronized', () async {
    MethodCall? receivedCall;
    messenger.setMockMethodCallHandler(channel, (call) async {
      receivedCall = call;
      return 1;
    });

    final synchronized = await const Live2DIOSRenderScaleService().synchronize(
      devicePixelRatio: 3,
    );

    expect(synchronized, isTrue);
    expect(receivedCall?.method, 'synchronizeContentScale');
    expect(receivedCall?.arguments, {'devicePixelRatio': 3.0});
  });

  test('reports false while the platform view is not mounted', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 0);

    final synchronized = await const Live2DIOSRenderScaleService().synchronize(
      devicePixelRatio: 2,
    );

    expect(synchronized, isFalse);
  });
}

import 'package:flutter/services.dart';

/// Synchronizes the iOS native Live2D surface with the device pixel ratio.
class Live2DIOSRenderScaleService {
  static const String channelName = 'com.nativetavern/live2d_render_scale';
  static const MethodChannel _channel = MethodChannel(channelName);

  const Live2DIOSRenderScaleService();

  Future<bool> synchronize({required double devicePixelRatio}) async {
    final matchedViews = await _channel.invokeMethod<int>(
          'synchronizeContentScale',
          {'devicePixelRatio': devicePixelRatio},
        ) ??
        0;
    return matchedViews > 0;
  }
}

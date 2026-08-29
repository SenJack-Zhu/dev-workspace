# NativeTavern Live2D macOS bridge

This local Flutter plugin uses the Live2D Cubism Native Framework and Cubism
Core to render Live2D models on macOS.

## Cubism Core setup

The Cubism Core header is proprietary SDK material and is intentionally not
tracked by this repository. Before building the macOS app:

1. Download Cubism SDK for Native from Live2D's official website and accept
   its license agreement.
2. Copy `Core/include/Live2DCubismCore.h` from the SDK into:

   `macos/CubismCore/include/Live2DCubismCore.h`

The bundled `macos/Libs/libLive2DCubismCore.dylib` is listed by Live2D as a
redistributable file. Applicable licenses and notices are retained under
`macos/licenses/`. It reports Cubism Core runtime version 6.0.1 and its digest
is pinned by the repository Live2D release manifest.

Official download: https://www.live2d.com/en/sdk/download/native/

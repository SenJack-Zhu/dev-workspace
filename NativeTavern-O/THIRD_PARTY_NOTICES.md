# Third-Party Notices

## Live2D runtime

NativeTavern currently integrates `flutter_live2d` 1.0.2 at upstream revision
`378b5b977df47672c78e12723f93854300a87e40` as a Flutter bridge to the Live2D
Cubism Native SDK on Android and iOS. The bundled
`native_tavern_live2d_macos` bridge uses the same Framework source snapshot on
macOS. The bundled Cubism Core reports runtime version 6.0.1.

- `flutter_live2d` source: BSD 3-Clause License
- Cubism Native Framework: Live2D Open Software License
- Cubism Core: Live2D Proprietary Software License
- Commercial distribution may require a Cubism SDK Release License

The macOS bridge retains the upstream license, notice, and redistributable
file list under `packages/native_tavern_live2d_macos/macos/licenses/`.

The Cubism licenses and release terms are maintained by Live2D Inc.:

- https://github.com/Live2D/CubismNativeFramework/blob/develop/LICENSE.md
- https://www.live2d.com/en/terms/
- https://www.live2d.com/en/download/cubism-sdk/release-license/

Live2D model files have their own creator or distributor terms. Inclusion of a
model in a development build does not establish redistribution rights. Verify
each model's license before including it in a public release.

## Hiyori Momose sample model

NativeTavern includes the runtime files from the Hiyori Momose FREE model,
downloaded from Live2D's official Sample Data Collection on 2026-08-07. The
editor source files from the archive are not included.

- Copyright: Live2D Inc.
- Illustration: Kani Biimu
- Modeling: Live2D
- Source: https://www.live2d.com/en/learn/sample/momose-hiyori/
- License: https://www.live2d.com/eula/live2d-free-material-license-agreement_en.html
- Additional terms: https://www.live2d.com/en/learn/sample/model-terms/
- Source archive SHA-256: `1e4254d561f2a151562aa67036d78e17e4ffee08869b8ce10ab6052a05e2b3a4`

Required notice:

> This content uses sample data owned and copyrighted by Live2D Inc. The
> sample data are utilized in accordance with terms and conditions set by
> Live2D Inc. This content itself is created at the author's sole discretion.

The individual Sample Data Terms prohibit changes of any kind to Hiyori
Momose's character design. Live2D sample data is licensed material, not public
domain or CC0 content.

Native runtime binaries, Framework sources, model assets, required notices,
and mobile validation evidence are checked by
`tool/live2d_release_gate.dart`. Commercial licensing decisions are handled
outside the engineering release gate.

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/presentation/widgets/chat/html_webview_widget.dart';

void main() {
  test('styled card HTML is treated as complex so WebView is used', () {
    const html = '''
<div style="background:#1c1c1e;border-radius:12px;padding:16px;overflow:hidden;height:240px">
  <h3>Status</h3>
  <p>Long card body that must stay fully visible after streaming ends.</p>
</div>
''';
    expect(isComplexHtml(html), isTrue);
  });

  test('webview height always grows to the latest measured content', () {
    expect(
      resolveHtmlWebViewHeight(
        currentHeight: 100,
        measuredHeight: 420,
        updateCount: 12,
      ),
      432,
    );
  });

  test('webview height ignores late shrinks that would crop content', () {
    expect(
      resolveHtmlWebViewHeight(
        currentHeight: 432,
        measuredHeight: 180,
        updateCount: 12,
      ),
      isNull,
    );
  });

  test('early layout may still correct an oversized first measurement', () {
    expect(
      resolveHtmlWebViewHeight(
        currentHeight: 800,
        measuredHeight: 240,
        updateCount: 2,
      ),
      252,
    );
  });
}

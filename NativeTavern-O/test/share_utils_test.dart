import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/utils/share_utils.dart';

void main() {
  testWidgets('returns a non-empty share popover anchor', (tester) async {
    Rect? anchor;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 80,
                height: 40,
                child: TextButton(
                  onPressed: () => anchor = sharePositionOrigin(context),
                  child: const Text('Share'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Share'));
    expect(anchor, isNotNull);
    expect(anchor!.isEmpty, isFalse);
    expect(anchor!.width, greaterThan(0));
    expect(anchor!.height, greaterThan(0));
  });
}

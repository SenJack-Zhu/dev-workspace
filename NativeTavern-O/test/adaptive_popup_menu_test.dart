import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/presentation/widgets/common/adaptive_popup_menu.dart';

void main() {
  testWidgets('anchored app bar menu survives a parent rebuild on iPad',
      (tester) async {
    tester.view.physicalSize = const Size(1640, 2360);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var rebuild = 0;
    String? selected;
    late StateSetter rebuildParent;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuildParent = setState;
            return Scaffold(
              appBar: AppBar(
                title: Text('rebuild-$rebuild'),
                actions: [
                  AdaptivePopupMenuButton<String>(
                    onSelected: (value) => selected = value,
                    itemBuilder: (context) => const [
                      PopupMenuItem<String>(
                        value: 'edit',
                        child: Text('Edit item'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Edit item'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.getTopLeft(find.text('Edit item')).dy, lessThan(200));

    rebuildParent(() => rebuild++);
    await tester.pump();
    expect(find.text('Edit item'), findsOneWidget);

    await tester.tap(find.text('Edit item'));
    await tester.pumpAndSettle();
    expect(selected, 'edit');
  });
}

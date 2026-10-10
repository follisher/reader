import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/epub_selection_toolbar_layout.dart';

void main() {
  testWidgets(
    'toolbar follows selection above, falling below at the top safe edge',
    (tester) async {
      final selection = ValueNotifier(const Rect.fromLTRB(30, 300, 280, 350));
      const toolbar = ValueKey('toolbar');
      var bodyTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 600,
              child: ValueListenableBuilder<Rect>(
                valueListenable: selection,
                builder: (_, rect, _) => Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => bodyTaps++,
                      ),
                    ),
                    Positioned.fill(
                      child: CustomSingleChildLayout(
                        delegate: EpubSelectionToolbarLayout(
                          selection: rect,
                          padding: const EdgeInsets.only(top: 24, bottom: 20),
                        ),
                        child: const SizedBox(
                          key: toolbar,
                          width: 300,
                          height: 60,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.getRect(find.byKey(toolbar)).bottom, 292);
      expect(tester.getRect(find.byKey(toolbar)).left, 50);
      selection.value = const Rect.fromLTRB(40, 430, 300, 480);
      await tester.pump();
      expect(tester.getRect(find.byKey(toolbar)).bottom, 422);
      selection.value = const Rect.fromLTRB(40, 30, 300, 55);
      await tester.pump();
      expect(tester.getRect(find.byKey(toolbar)).top, 63);
      await tester.tapAt(const Offset(30, 500));
      expect(bodyTaps, 1);
      await tester.pumpWidget(const SizedBox());
      selection.dispose();
    },
  );

  test('measured toolbar size remains inside safe screen bounds', () {
    const layout = EpubSelectionToolbarLayout(
      selection: Rect.fromLTRB(0, 10, 320, 590),
      padding: EdgeInsets.only(top: 24, bottom: 20),
    );
    final position = layout.getPositionForChild(
      const Size(400, 600),
      const Size(380, 110),
    );
    expect(position.dy, greaterThanOrEqualTo(28));
    expect(position.dy + 110, lessThanOrEqualTo(576));
  });
}

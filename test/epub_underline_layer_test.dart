import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/epub_underline_layer.dart';

void main() {
  testWidgets('note strokes stay two pixels thick on every wrapped line', (
    tester,
  ) async {
    for (final fontSize in [16.0, 24.0, 32.0]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 160,
              child: EpubUnderlineLayer(
                child: RichText(
                  text: TextSpan(
                    text:
                        'Selected words across several wrapped lines of text.',
                    style: TextStyle(
                      fontSize: fontSize,
                      color: Colors.black,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.red,
                      decorationThickness: 0,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byType(RichText),
      );
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: paragraph.text.toPlainText().length,
        ),
      );
      expect(boxes.length, greaterThan(1));
      final drawing = paints;
      for (final box in boxes) {
        drawing.rect(
          color: Colors.red,
          rect: Rect.fromLTRB(box.left, box.bottom - 2, box.right, box.bottom),
        );
      }
      expect(tester.renderObject(find.byType(EpubUnderlineLayer)), drawing);
    }
  });
}

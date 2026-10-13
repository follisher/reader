import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Fixed logical-pixel note strokes, matching the native EPUB 2px border.
/// A zero decoration thickness marks note spans only; publisher underlines
/// retain their normal font-based rendering.
class EpubUnderlineLayer extends SingleChildRenderObjectWidget {
  const EpubUnderlineLayer({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _UnderlineLayer();
}

class _UnderlineLayer extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        var position = 0;
        void visitSpan(InlineSpan span, TextStyle inherited) {
          final style = inherited.merge(span.style);
          if (span is TextSpan) {
            final start = position;
            position += span.text?.length ?? 0;
            if (position > start &&
                style.decorationThickness == 0 &&
                style.decoration?.contains(TextDecoration.underline) == true) {
              final paint = Paint()
                ..color = style.decorationColor ?? style.color ?? Colors.black;
              final origin = object.localToGlobal(Offset.zero, ancestor: this);
              for (final box in object.getBoxesForSelection(
                TextSelection(baseOffset: start, extentOffset: position),
              )) {
                context.canvas.drawRect(
                  Rect.fromLTRB(
                    box.left,
                    box.bottom - 2,
                    box.right,
                    box.bottom,
                  ).shift(offset + origin),
                  paint,
                );
              }
            }
            for (final child in span.children ?? const <InlineSpan>[]) {
              visitSpan(child, style);
            }
          } else if (span is PlaceholderSpan) {
            position++;
          }
        }

        visitSpan(object.text, const TextStyle());
      }
      object.visitChildren(visit);
    }

    if (child != null) visit(child!);
  }
}

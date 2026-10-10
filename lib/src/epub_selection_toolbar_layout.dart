import 'package:flutter/material.dart';

/// Positions the measured toolbar above the selection, falling below only when
/// the top safe area leaves insufficient room, like the TXT selection toolbar.
class EpubSelectionToolbarLayout extends SingleChildLayoutDelegate {
  const EpubSelectionToolbarLayout({
    required this.selection,
    required this.padding,
  });
  final Rect selection;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: (constraints.maxWidth - padding.horizontal - 16).clamp(
          0,
          double.infinity,
        ),
        maxHeight: (constraints.maxHeight - padding.vertical - 8).clamp(
          0,
          double.infinity,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minY = padding.top + 4;
    final maxY = (size.height - padding.bottom - childSize.height - 4).clamp(
      minY,
      double.infinity,
    );
    final above = selection.top - childSize.height - 8;
    final y = above >= minY ? above : selection.bottom + 8;
    return Offset(
      padding.left + (size.width - padding.horizontal - childSize.width) / 2,
      y.clamp(minY, maxY),
    );
  }

  @override
  bool shouldRelayout(EpubSelectionToolbarLayout oldDelegate) =>
      selection != oldDelegate.selection || padding != oldDelegate.padding;
}

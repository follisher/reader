import 'package:flutter/material.dart';

/// Shared inline paragraph-comment bubble for TXT and EPUB.
class ReaderCommentBadge extends StatelessWidget {
  const ReaderCommentBadge(
      {super.key, required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '$count 条段评',
        button: true,
        excludeSemantics: true,
        child: SizedBox(
          width: 34,
          height: 22,
          child: Stack(
            children: [
              Positioned.fill(
                  child: CustomPaint(painter: _CommentBubblePainter(color))),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 17,
                child: Center(
                  child: Text(
                    '$count',
                    style: TextStyle(
                        fontSize: 10,
                        height: 1,
                        color: color,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

/// 段尾「段评」角标的描边对话气泡（34×22，左下带小尾巴），仅描边不填充。
class _CommentBubblePainter extends CustomPainter {
  _CommentBubblePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = color;
    final Path path = Path()
      ..moveTo(9, 1.5)
      ..lineTo(26, 1.5)
      ..arcToPoint(const Offset(32.5, 8),
          radius: const Radius.circular(6.5), clockwise: true)
      ..lineTo(32.5, 9.5)
      ..arcToPoint(const Offset(26, 16),
          radius: const Radius.circular(6.5), clockwise: true)
      ..lineTo(13, 16)
      ..lineTo(8, 21)
      ..lineTo(10, 16)
      ..lineTo(9, 16)
      ..arcToPoint(const Offset(2.5, 9.5),
          radius: const Radius.circular(6.5), clockwise: true)
      ..lineTo(2.5, 8)
      ..arcToPoint(const Offset(9, 1.5),
          radius: const Radius.circular(6.5), clockwise: true)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CommentBubblePainter old) => old.color != color;
}

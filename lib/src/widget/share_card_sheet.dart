import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:share_plus/share_plus.dart';

class ShareCardSheet extends StatefulWidget {
  const ShareCardSheet({
    super.key,
    required this.bookTitle,
    required this.author,
    required this.coverPath,
    required this.chapterTitle,
    required this.quote,
    required this.readerTheme,
    required this.textStyle,
    required this.dateText,
  });

  final String bookTitle;
  final String author;
  final String? coverPath;
  final String chapterTitle;
  final String quote;
  final engine.ReaderTheme readerTheme;
  final TextStyle textStyle;
  final String dateText;

  static Future<void> show(
    BuildContext context, {
    required String bookTitle,
    required String author,
    required String? coverPath,
    required String chapterTitle,
    required String quote,
    required engine.ReaderTheme readerTheme,
    required TextStyle textStyle,
  }) {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ShareCardSheet(
        bookTitle: bookTitle,
        author: author,
        coverPath: coverPath,
        chapterTitle: chapterTitle,
        quote: quote,
        readerTheme: readerTheme,
        textStyle: textStyle,
        dateText: '${now.year}/${two(now.month)}/${two(now.day)}',
      ),
    );
  }

  @override
  State<ShareCardSheet> createState() => _ShareCardSheetState();
}

class _ShareCardSheetState extends State<ShareCardSheet> {
  final _cardKey = GlobalKey();
  bool _sharing = false;
  String? _error;

  engine.ReaderTheme get _theme => widget.readerTheme;

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    final box = context.findRenderObject() as RenderBox?;
    final sharePositionOrigin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      await WidgetsBinding.instance.endOfFrame;
      final object = _cardKey.currentContext?.findRenderObject();
      if (object is! RenderRepaintBoundary) {
        throw StateError('分享卡片尚未完成渲染');
      }
      final image = await object.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('无法生成分享图片');
      final Uint8List bytes = data.buffer.asUint8List();
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[
            XFile.fromData(bytes, mimeType: 'image/png', name: '摘录.png'),
          ],
          text: '《${widget.bookTitle}》 ${widget.chapterTitle}',
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
      if (mounted) Navigator.of(context).maybePop();
    } catch (_) {
      if (mounted) setState(() => _error = '生成分享图片失败，请重试');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 360.0);
    return ColoredBox(
      color: _theme.panelColor,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              RepaintBoundary(key: _cardKey, child: _card(width)),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              _actions(width),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(double width) => Container(
    width: width,
    decoration: BoxDecoration(
      color: _theme.paperColor,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _theme.borderColor),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: _theme.isDark ? 0.35 : 0.14),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _header(),
          const SizedBox(height: 28),
          _quote(),
          const SizedBox(height: 28),
          Divider(height: 1, color: _theme.dividerColor),
          const SizedBox(height: 14),
          _footer(),
        ],
      ),
    ),
  );

  Widget _header() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _cover(),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '《${widget.bookTitle}》',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: widget.textStyle.copyWith(
                color: _theme.textColor,
                fontSize: 16,
                height: 1.35,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (widget.chapterTitle.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 5),
              Text(
                widget.chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: widget.textStyle.copyWith(
                  color: _theme.subTextColor,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
            if (widget.author.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 5),
              Text(
                widget.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: widget.textStyle.copyWith(
                  color: _theme.subTextColor,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    ],
  );

  Widget _cover() {
    final path = widget.coverPath;
    final fallback = ColoredBox(
      color: _theme.accentColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            widget.bookTitle,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: widget.textStyle.copyWith(
              color: Colors.white,
              fontSize: 10,
              height: 1.3,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 52,
        height: 72,
        child: path == null || path.isEmpty
            ? fallback
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }

  Widget _quote() => Stack(
    clipBehavior: Clip.none,
    children: <Widget>[
      Positioned(
        left: -4,
        top: -22,
        child: Icon(
          Icons.format_quote_rounded,
          size: 44,
          color: _theme.accentColor.withValues(alpha: 0.22),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          widget.quote,
          maxLines: 12,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.justify,
          style: widget.textStyle.copyWith(
            color: _theme.textColor,
            fontSize: 18,
            height: 1.7,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ],
  );

  Widget _footer() => Row(
    children: <Widget>[
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: _theme.accentColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Icon(
          Icons.menu_book_rounded,
          size: 19,
          color: Colors.white,
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '阅读摘录',
              style: widget.textStyle.copyWith(
                color: _theme.textColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '摘录于 ${widget.dateText}',
              style: widget.textStyle.copyWith(
                color: _theme.subTextColor,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _actions(double width) => SizedBox(
    width: width,
    child: Row(
      children: <Widget>[
        IconButton.filledTonal(
          tooltip: '取消',
          onPressed: _sharing ? null : () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: _sharing ? null : _share,
            icon: _sharing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.ios_share_rounded),
            label: Text(_sharing ? '生成中' : '分享图片'),
            style: FilledButton.styleFrom(
              backgroundColor: _theme.accentColor,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
      ],
    ),
  );
}

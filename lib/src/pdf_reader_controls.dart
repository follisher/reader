import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_readium/flutter_readium.dart' as rd;

/// PDF actions inside the same menu used by EPUB and TXT.
class PdfReaderMenu extends StatelessWidget {
  const PdfReaderMenu({
    super.key,
    required this.visible,
    required this.title,
    required this.page,
    required this.progress,
    required this.bookmarked,
    required this.layout,
    required this.config,
    required this.onDismiss,
    required this.onBack,
    required this.onToggleBookmark,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onCatalog,
    required this.onLayoutChanged,
  });

  final bool visible, bookmarked;
  final String title;
  final int page;
  final double progress;
  final rd.PDFLayout layout;
  final engine.ReaderConfig config;
  final VoidCallback onDismiss, onBack, onToggleBookmark, onPrevious, onNext;
  final ValueChanged<double> onSeek;
  final VoidCallback onCatalog;
  final ValueChanged<rd.PDFLayout> onLayoutChanged;

  @override
  Widget build(BuildContext context) => engine.ReaderMenu(
    visible: visible,
    bookTitle: title,
    chapterTitle: '',
    chapterIndex: page - 1,
    chapterCount: 0,
    progress: progress,
    config: config,
    bookmarked: bookmarked,
    showDayNight: false,
    showSegmentComments: false,
    showTopCatalog: true,
    previousLabel: '上一页',
    nextLabel: '下一页',
    progressLabel: '第 $page 页 · ${(progress * 100).round()}%',
    canGoPrevious: page > 1,
    canGoNext: progress < 1,
    onRequestClose: onDismiss,
    onBack: onBack,
    onToggleBookmark: onToggleBookmark,
    onPrevChapter: onPrevious,
    onNextChapter: onNext,
    onSeekProgress: onSeek,
    onOpenCatalog: onCatalog,
    seekPreview: (_) =>
        engine.ReaderSeekPreview(page: page, totalPages: 0, title: '阅读进度'),
    seekPreviewLabel: (value) => '${(value * 100).round()}%',
    settingsBuilder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '翻页模式',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: config.theme.subTextColor,
            ),
          ),
          const SizedBox(height: 12),
          engine.ReaderChoiceRow<rd.PDFLayout>(
            values: const [
              rd.PDFLayout.scrollVertical,
              rd.PDFLayout.scrollHorizontal,
            ],
            selected: layout == rd.PDFLayout.paginated
                ? rd.PDFLayout.scrollHorizontal
                : layout,
            labelFor: (value) => switch (value) {
              rd.PDFLayout.paginated => '左右滚动',
              rd.PDFLayout.scrollVertical => '上下滚动',
              rd.PDFLayout.scrollHorizontal => '左右滚动',
            },
            onSelected: onLayoutChanged,
            theme: config.theme,
          ),
        ],
      ),
    ),
  );
}

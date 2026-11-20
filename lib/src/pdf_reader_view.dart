import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as pdf;

import 'bookshelf_view.dart' show readerError;
import 'models.dart';
import 'providers.dart';
import 'reader_comment_sheets.dart';
import 'repository.dart';
import 'widget/book_cover.dart';

/// Preserves PDF page layout, including scanned books, with zoom and resume.
class PdfReaderView extends ConsumerStatefulWidget {
  const PdfReaderView({
    super.key,
    required this.book,
    this.initialChapter,
    this.initialAnchor,
  });
  final Book book;
  final int? initialChapter;
  final ReaderAnchor? initialAnchor;

  @override
  ConsumerState<PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends ConsumerState<PdfReaderView> {
  final _controller = pdf.PdfViewerController();
  late final BookshelfRepository _repository;
  late final Future<String> _path;
  final _notes = <ReaderNoteKind, List<Map<String, dynamic>>>{};
  final _config = engine.ReaderConfig();
  List<pdf.PdfOutlineNode> _outline = const [];
  Future<void>? _outlineLoading;
  bool _outlineFailed = false;
  bool _menuVisible = false;
  bool _noteBusy = false;
  int _page = 1;
  int _pageCount = 0;
  Timer? _saveTimer;
  Future<void> _saving = Future.value();
  ReadingLocation? _pendingLocation;

  int get _initialPage {
    if (widget.initialChapter != null) return widget.initialChapter! + 1;
    final anchor = widget.initialAnchor ?? widget.book.location.anchor;
    final page = anchor?.type == 'pdf' ? anchor?.value['page'] : null;
    return page is int ? page : widget.book.location.chapter + 1;
  }

  @override
  void initState() {
    super.initState();
    _repository = ref.read(bookshelfRepositoryProvider);
    _config.addListener(_configChanged);
    _page = _initialPage;
    _path = _loadPath();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _config.setTheme(
      Theme.of(context).brightness == Brightness.dark
          ? engine.ReaderTheme.night
          : engine.ReaderTheme.white,
    );
  }

  void _configChanged() {
    if (!mounted) return;
    setState(() {});
    if (_controller.isReady) _controller.invalidate();
  }

  Future<String> _loadPath() async {
    if (_repository is! PublicationFileRepository) {
      throw const FormatException('当前书库不支持打开 PDF 原文件');
    }
    final path = await (_repository as PublicationFileRepository)
        .publicationPath(widget.book);
    if (!await File(path).exists()) {
      throw const FormatException('本地 PDF 文件不存在，请重新导入');
    }
    for (final kind in ReaderNoteKind.values) {
      _notes[kind] = await _repository.loadNotes(widget.book.id, kind);
    }
    return path;
  }

  Future<void> _loadOutline(pdf.PdfDocument document) async {
    try {
      final outline = await document.loadOutline();
      if (mounted) setState(() => _outline = outline);
    } catch (_) {
      // A broken outline must not prevent reading the PDF itself.
      if (mounted) setState(() => _outlineFailed = true);
    }
  }

  pdf.PdfDest? _outlineDestination(pdf.PdfOutlineNode node) {
    final dest = node.dest;
    if (dest != null && dest.pageNumber >= 1 && dest.pageNumber <= _pageCount) {
      return dest;
    }
    // Some PDFs use a title-only parent to group navigable subsections.
    for (final child in node.children) {
      final destination = _outlineDestination(child);
      if (destination != null) return destination;
    }
    return null;
  }

  String get _currentTitle {
    var title = '第 $_page 页';
    var nearestPage = 0;
    void visit(List<pdf.PdfOutlineNode> nodes) {
      for (final node in nodes) {
        final page = node.dest?.pageNumber;
        if (page != null &&
            page >= nearestPage &&
            page <= _page &&
            node.title.trim().isNotEmpty) {
          nearestPage = page;
          title = node.title.trim();
        }
        visit(node.children);
      }
    }

    visit(_outline);
    return title;
  }

  void _onPageChanged(int? page) {
    if (!mounted || page == null || _pageCount == 0) return;
    setState(() => _page = page);
    _pendingLocation = ReadingLocation(
      chapter: page - 1,
      progress: page / _pageCount,
      anchor: ReaderAnchor(type: 'pdf', value: {'page': page}),
    );
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _savePosition);
  }

  void _savePosition() {
    final location = _pendingLocation;
    if (location == null) return;
    _pendingLocation = null;
    _saving = _saving
        .then((_) => _repository.saveLocation(widget.book.id, location))
        .catchError((Object error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('阅读位置保存失败：${readerError(error)}')),
          );
        });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _savePosition();
    _config.removeListener(_configChanged);
    // ReaderMenu may still read this config while the route is unmounting.
    WidgetsBinding.instance.addPostFrameCallback((_) => _config.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _config.theme.paperColor,
    body: Stack(
      children: [
        Positioned.fill(
          child: FutureBuilder<String>(
            future: _path,
            builder: (context, snapshot) {
              if (snapshot.hasError) return _error(snapshot.error!);
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return pdf.PdfViewer.file(
                snapshot.data!,
                controller: _controller,
                initialPageNumber: _initialPage,
                params: pdf.PdfViewerParams(
                  backgroundColor: _config.theme.paperColor,
                  onViewerReady: (document, controller) {
                    if (!mounted) return;
                    setState(() => _pageCount = document.pages.length);
                    _outlineLoading = _loadOutline(document);
                    _onPageChanged(controller.pageNumber);
                  },
                  onPageChanged: _onPageChanged,
                  pagePaintCallbacks: [_paintNotes],
                  buildContextMenu: _selectionToolbar,
                  onGeneralTap: _onGeneralTap,
                  pageOverlaysBuilder: _commentOverlays,
                  errorBannerBuilder: (
                    context,
                    error,
                    stackTrace,
                    documentRef,
                  ) => _error(error),
                ),
              );
            },
          ),
        ),
        if (_pageCount > 0) ...[
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: SafeArea(
                top: false,
                child: Center(
                  child: Text(
                    '$_page / $_pageCount',
                    style: TextStyle(color: _config.theme.subTextColor),
                  ),
                ),
              ),
            ),
          ),
          engine.ReaderMenu(
            visible: _menuVisible,
            bookTitle: widget.book.title,
            chapterTitle: _currentTitle,
            chapterIndex: _page - 1,
            chapterCount: _pageCount,
            progress: _pageCount <= 1 ? 0 : (_page - 1) / (_pageCount - 1),
            config: _config,
            bookmarked: _hasBookmark,
            onToggleBookmark: () {
              if (!_noteBusy) unawaited(_toggleBookmark());
            },
            onBack: () => Navigator.maybePop(context),
            onOpenCatalog: () => _showNotes(initialTabIndex: 1),
            onPrevChapter: () {
              if (_page > 1) _controller.goToPage(pageNumber: _page - 1);
            },
            onNextChapter: () {
              if (_page < _pageCount) {
                _controller.goToPage(pageNumber: _page + 1);
              }
            },
            previousLabel: '上一页',
            nextLabel: '下一页',
            onSeekProgress: (value) => _controller.goToPage(
              pageNumber: (value * (_pageCount - 1)).round() + 1,
            ),
            seekPreview: (value) => engine.ReaderSeekPreview(
              page: (value * (_pageCount - 1)).round() + 1,
              totalPages: _pageCount,
              title: widget.book.title,
            ),
            onRequestClose: () => setState(() => _menuVisible = false),
            showAppearanceControls: false,
            onWriteComment: () {
              if (!_noteBusy) _writeComment(page: _page);
            },
          ),
        ],
      ],
    ),
  );

  Widget? _selectionToolbar(
    BuildContext context,
    pdf.PdfViewerContextMenuBuilderParams params,
  ) {
    final selection = params.textSelectionDelegate;
    if (!selection.hasSelectedText || !selection.isCopyAllowed) return null;
    final actions = [
      engine.ReaderSelectionToolbarAction(
        icon: Icons.content_copy_rounded,
        label: '复制',
        onTap: () async {
          if (await selection.copyTextSelection()) {
            await selection.clearTextSelection();
          }
        },
      ),
      engine.ReaderSelectionToolbarAction(
        icon: Icons.border_color_outlined,
        label: '划线',
        onTap: () => _markSelection(selection, false),
      ),
      engine.ReaderSelectionToolbarAction(
        icon: Icons.mode_comment_outlined,
        label: '评论',
        onTap: () => _markSelection(selection, true),
      ),
    ];
    // pdfrx measures and positions this toolbar beside the selection.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - 16,
      ),
      child: engine.ReaderSelectionToolbar(actions: actions),
    );
  }

  bool _onGeneralTap(
    BuildContext context,
    pdf.PdfViewerController controller,
    pdf.PdfViewerGeneralTapHandlerDetails details,
  ) {
    if (details.type != pdf.PdfViewerGeneralTapType.tap) return false;
    // Let a tap dismiss an existing selection before showing the reading menu.
    if (controller.textSelectionDelegate.hasSelectedText) return false;
    if (_config.showSegmentComments) {
      final hit = controller.getPdfPageHitTestResult(
        details.documentPosition,
        useDocumentLayoutCoordinates: true,
      );
      if (hit != null) {
        final rows = (_notes[ReaderNoteKind.comment] ?? []).where((row) {
          final ranges = ReaderAnchor.fromJson(row['anchor'])?.value['ranges'];
          if (ranges is! List) return false;
          return ranges.whereType<Map>().any(
            (range) =>
                range['page'] == hit.page.pageNumber &&
                range['rects'] is List &&
                (range['rects'] as List).whereType<List>().any(
                  (r) =>
                      r.length == 4 &&
                      pdf.PdfRect(
                        (r[0] as num).toDouble(),
                        (r[1] as num).toDouble(),
                        (r[2] as num).toDouble(),
                        (r[3] as num).toDouble(),
                      ).containsPoint(hit.offset),
                ),
          );
        }).toList();
        if (rows.isNotEmpty) {
          unawaited(_openComments(rows));
          return true;
        }
      }
    }
    setState(() => _menuVisible = !_menuVisible);
    return true;
  }

  List<Widget> _commentOverlays(
    BuildContext context,
    Rect rect,
    pdf.PdfPage page,
  ) {
    if (!_config.showSegmentComments) return const [];
    final rows = (_notes[ReaderNoteKind.comment] ?? []).where((row) {
      final anchor = ReaderAnchor.fromJson(row['anchor']);
      final ranges = anchor?.value['ranges'];
      return _notePage(row) == page.pageNumber ||
          (ranges is List &&
              ranges.whereType<Map>().any((r) => r['page'] == page.pageNumber));
    }).toList();
    if (rows.isEmpty) return const [];
    return [
      Positioned(
        right: 12,
        top: 12,
        child: pdf.PdfOverlayInteractionRegion(
          key: ValueKey('pdf-page-comments-${page.pageNumber}'),
          onTap: (_) {
            unawaited(_openComments(rows));
            return true;
          },
          child: engine.ReaderCommentBadge(
            count: rows.length,
            color: _config.theme.subTextColor,
          ),
        ),
      ),
    ];
  }

  Future<void> _openComments(List<Map<String, dynamic>> rows) async {
    setState(() => _menuVisible = false);
    final mapped = {
      for (var i = 0; i < rows.length; i++)
        engine.Comment(
          chapterIndex: _notePage(rows[i]) - 1,
          start: i,
          end: i + 1,
          quote: rows[i]['quote'] as String? ?? '',
          text: rows[i]['text'] as String? ?? '',
          chapterTitle: rows[i]['chapterTitle'] as String? ?? '',
          createdAt: rows[i]['createdAt'] as int? ?? 0,
        ): rows[i],
    };
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ReaderParagraphComments(
        comments: mapped.keys.toList(),
        onDelete: (comment) => _persistNotes(ReaderNoteKind.comment, [
          for (final row in _notes[ReaderNoteKind.comment]!)
            if (!identical(row, mapped[comment])) row,
        ]),
      ),
    );
  }

  int _notePage(Map<String, dynamic> row) =>
      (ReaderAnchor.fromJson(row['anchor'])?.value['page'] as int?) ??
      (row['chapterIndex'] as int? ?? 0) + 1;

  bool get _hasBookmark => (_notes[ReaderNoteKind.bookmark] ?? []).any(
    (row) => _notePage(row) == _page,
  );

  Map<String, dynamic> _newNote(
    int page,
    String quote, {
    List<Map<String, dynamic>> ranges = const [],
    String? comment,
  }) {
    final now = DateTime.now();
    return {
      'id': 'pdf:${now.microsecondsSinceEpoch}',
      'chapterIndex': page - 1,
      'chapterTitle': '第 $page 页',
      'charOffset': 0,
      'start': ranges.isEmpty ? 0 : ranges.first['start'],
      'end': ranges.isEmpty ? 0 : ranges.last['end'],
      'createdAt': now.millisecondsSinceEpoch,
      'text': comment ?? quote,
      'quote': quote,
      'excerpt': quote,
      'anchor': ReaderAnchor(
        type: 'pdf',
        value: {'page': page, 'ranges': ranges},
      ).toJson(),
    };
  }

  Future<void> _persistNotes(
    ReaderNoteKind kind,
    List<Map<String, dynamic>> rows,
  ) async {
    if (_noteBusy) throw StateError('笔记正在保存，请稍后重试');
    setState(() => _noteBusy = true);
    try {
      await _repository.saveNotes(widget.book.id, kind, rows);
      if (!mounted) return;
      setState(() => _notes[kind] = rows);
      if (_controller.isReady) _controller.invalidate();
    } finally {
      if (mounted) setState(() => _noteBusy = false);
    }
  }

  void _noteError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('笔记保存失败：${readerError(error)}')));
  }

  Future<void> _toggleBookmark() async {
    final page = _page;
    final rows = List<Map<String, dynamic>>.of(
      _notes[ReaderNoteKind.bookmark]!,
    );
    if (_hasBookmark) {
      rows.removeWhere((row) => _notePage(row) == page);
    } else {
      rows.add(_newNote(page, '第 $page 页'));
    }
    try {
      await _persistNotes(ReaderNoteKind.bookmark, rows);
    } catch (error) {
      _noteError(error);
    }
  }

  Future<void> _markSelection(
    pdf.PdfTextSelectionDelegate selection,
    bool comment,
  ) async {
    if (_noteBusy || !selection.isCopyAllowed) return;
    try {
      final selected = await selection.getSelectedTextRanges();
      if (!mounted || selected.isEmpty) return;
      // Store geometry in PDF coordinates so marks survive zoom and reopening.
      final ranges = [
        for (final range in selected)
          {
            'page': range.pageNumber,
            'start': range.start,
            'end': range.end,
            'rects': [
              for (final rect
                  in (range.pageText.fragments.isEmpty
                      ? [range.bounds]
                      : range.enumerateFragmentBoundingRects().map(
                          (f) => f.bounds,
                        )))
                [rect.left, rect.top, rect.right, rect.bottom],
            ],
          },
      ];
      final quote = selected.map((range) => range.text).join('\n');
      if (quote.trim().isEmpty) return;
      final page = selected.first.pageNumber;
      await selection.clearTextSelection();
      if (!mounted) return;
      if (comment) {
        await _writeComment(page: page, quote: quote, ranges: ranges);
      } else {
        final rows = List<Map<String, dynamic>>.of(
          _notes[ReaderNoteKind.underline]!,
        );
        rows.removeWhere((row) {
          final anchor = ReaderAnchor.fromJson(row['anchor']);
          return anchor?.type == 'pdf' &&
              anchor?.value['ranges'].toString() == ranges.toString();
        });
        rows.add(_newNote(page, quote, ranges: ranges));
        await _persistNotes(ReaderNoteKind.underline, rows);
      }
    } catch (error) {
      _noteError(error);
    }
  }

  Future<void> _writeComment({
    required int page,
    String? quote,
    List<Map<String, dynamic>> ranges = const [],
  }) async {
    setState(() => _menuVisible = false);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ReaderCommentInput(
        quote: quote ?? '第 $page 页（整页评论）',
        onSave: (text) => _persistNotes(ReaderNoteKind.comment, [
          ..._notes[ReaderNoteKind.comment]!,
          _newNote(page, quote ?? '第 $page 页', ranges: ranges, comment: text),
        ]),
      ),
    );
  }

  void _paintNotes(Canvas canvas, Rect pageRect, pdf.PdfPage page) {
    for (final kind in [ReaderNoteKind.underline, ReaderNoteKind.comment]) {
      if (kind == ReaderNoteKind.comment && !_config.showSegmentComments) {
        continue;
      }
      for (final row in _notes[kind] ?? <Map<String, dynamic>>[]) {
        final anchor = ReaderAnchor.fromJson(row['anchor']);
        if (anchor?.type != 'pdf') continue;
        final ranges = anchor!.value['ranges'];
        if (ranges is! List) continue;
        for (final range in ranges.whereType<Map>()) {
          if (range['page'] != page.pageNumber || range['rects'] is! List) {
            continue;
          }
          for (final coords in (range['rects'] as List).whereType<List>()) {
            if (coords.length != 4 || coords.any((n) => n is! num)) continue;
            final rect =
                pdf.PdfRect(
                      (coords[0] as num).toDouble(),
                      (coords[1] as num).toDouble(),
                      (coords[2] as num).toDouble(),
                      (coords[3] as num).toDouble(),
                    )
                    .toRect(page: page, scaledPageSize: pageRect.size)
                    .translate(pageRect.left, pageRect.top);
            if (kind == ReaderNoteKind.underline) {
              canvas.drawLine(
                rect.bottomLeft,
                rect.bottomRight,
                Paint()
                  ..color = _config.theme.underlineColor
                  ..strokeWidth = 2,
              );
            } else {
              canvas.drawRect(
                rect,
                Paint()
                  ..color = _config.theme.commentHighlightColor.withValues(
                    alpha: .4,
                  ),
              );
            }
          }
        }
      }
    }
  }

  Future<void> _showNotes({int initialTabIndex = 2}) async {
    setState(() => _menuVisible = false);
    await _outlineLoading;
    if (!mounted) return;
    if (_outlineFailed) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PDF 目录读取失败，暂按页码浏览')));
    }
    final outlineDestinations = <String, pdf.PdfDest>{};
    var offset = 0;
    List<engine.BookTocEntry> mapOutline(List<pdf.PdfOutlineNode> nodes) {
      final entries = <engine.BookTocEntry>[];
      for (final node in nodes) {
        final dest = _outlineDestination(node);
        if (dest == null) continue;
        final position = offset++;
        outlineDestinations['${dest.pageNumber - 1}:$position'] = dest;
        entries.add(
          engine.BookTocEntry(
            id: 'pdf-outline-$position',
            title: node.title.trim().isEmpty
                ? '第 ${dest.pageNumber} 页'
                : node.title.trim(),
            chapterIndex: dest.pageNumber - 1,
            charOffset: position,
            children: mapOutline(node.children),
          ),
        );
      }
      return entries;
    }

    final toc = mapOutline(_outline);
    final destinations = <String, Map<String, dynamic>>{};
    final bookmarks = <engine.Bookmark, Map<String, dynamic>>{};
    final underlines = <engine.Underline, Map<String, dynamic>>{};
    final comments = <engine.Comment, Map<String, dynamic>>{};
    for (final kind in ReaderNoteKind.values) {
      for (final row in _notes[kind]!) {
        final chapter = _notePage(row) - 1;
        final position = offset++;
        destinations['$chapter:$position'] = row;
        final title = row['chapterTitle'] as String? ?? '第 ${chapter + 1} 页';
        final createdAt = row['createdAt'] as int? ?? 0;
        switch (kind) {
          case ReaderNoteKind.bookmark:
            bookmarks[engine.Bookmark(
                  chapterIndex: chapter,
                  charOffset: position,
                  chapterTitle: title,
                  createdAt: createdAt,
                  excerpt: row['excerpt'] as String? ?? '',
                )] =
                row;
          case ReaderNoteKind.underline:
            underlines[engine.Underline(
                  chapterIndex: chapter,
                  start: position,
                  end: position + 1,
                  chapterTitle: title,
                  createdAt: createdAt,
                  text: row['text'] as String? ?? '',
                )] =
                row;
          case ReaderNoteKind.comment:
            comments[engine.Comment(
                  chapterIndex: chapter,
                  start: position,
                  end: position + 1,
                  chapterTitle: title,
                  createdAt: createdAt,
                  text: row['text'] as String? ?? '',
                  quote: row['quote'] as String? ?? '',
                )] =
                row;
        }
      }
    }
    Future<void> delete(ReaderNoteKind kind, Map<String, dynamic> row) =>
        _persistNotes(kind, [
          for (final note in _notes[kind]!)
            if (!identical(note, row)) note,
        ]);
    final picked = await showModalBottomSheet<engine.ReadingPosition>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .85,
        minChildSize: .5,
        maxChildSize: .92,
        builder: (context, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: ColoredBox(
            color: _config.theme.paperColor,
            child: engine.CatalogSheet(
              bookTitle: widget.book.title,
              author: widget.book.author,
              intro: '',
              coverColor: const Color(0xFFA6A6A6),
              coverBuilder: (_) =>
                  BookCover(book: widget.book, minimalThickness: true),
              chapterTitles: List.generate(_pageCount, (i) => '第 ${i + 1} 页'),
              toc: toc,
              catalogSummary: toc.isEmpty
                  ? '共 $_pageCount 页（${_outlineFailed ? '目录读取失败' : '文件无内置目录'}）'
                  : '共 ${outlineDestinations.length} 项',
              currentIndex: _page - 1,
              theme: _config.theme,
              bookmarks: bookmarks.keys.toList(),
              underlines: underlines.keys.toList(),
              comments: comments.keys.toList(),
              onDeleteBookmark: (note) =>
                  delete(ReaderNoteKind.bookmark, bookmarks[note]!),
              onDeleteUnderline: (note) =>
                  delete(ReaderNoteKind.underline, underlines[note]!),
              onDeleteComment: (note) =>
                  delete(ReaderNoteKind.comment, comments[note]!),
              scrollController: scrollController,
              initialTabIndex: initialTabIndex,
            ),
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    final key = '${picked.chapterIndex}:${picked.charOffset}';
    final outlineDest = outlineDestinations[key];
    if (outlineDest != null) {
      // Keep XYZ/Fit destinations, including same-page subsection positions.
      if (!await _controller.goToDest(outlineDest) && mounted) {
        await _controller.goToPage(pageNumber: outlineDest.pageNumber);
      }
      return;
    }
    final row = destinations[key];
    await _controller.goToPage(
      pageNumber: row == null ? picked.chapterIndex + 1 : _notePage(row),
    );
  }

  Widget _error(Object error) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('PDF 打开失败：${readerError(error)}', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.maybePop(context),
            child: const Text('返回书架'),
          ),
        ],
      ),
    ),
  );
}

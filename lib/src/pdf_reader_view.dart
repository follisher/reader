import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_readium/flutter_readium.dart' as rd;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'pdf_readium_adapter.dart';
import 'pdf_bookmark_chapter.dart';
import 'pdf_reader_controls.dart';
import 'providers.dart';
import 'repository.dart';
import 'widget/book_cover.dart';

/// Native PDF reading surface with controls limited to PDF-supported features.
class PdfReaderView extends ConsumerStatefulWidget {
  const PdfReaderView({super.key, required this.book, this.initialAnchor});
  final Book book;
  final ReaderAnchor? initialAnchor;
  @override
  ConsumerState<PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends ConsumerState<PdfReaderView> {
  final _reader = PdfReadiumAdapter();
  final _menuConfig = engine.ReaderConfig();
  final _menu = ValueNotifier(false);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _bookmarks = <Map<String, dynamic>>[];
  late final BookshelfRepository _repository;
  rd.Publication? _publication;
  rd.Locator? _position;
  rd.PDFLayout _layout = rd.PDFLayout.scrollHorizontal;
  // A small fixed gap keeps page boundaries visible without another setting.
  static const double _pageSpacing = 8;
  String? _error;
  bool _closing = false;
  bool _surfaceReady = false;
  bool _configuringSurface = false;
  Future<void> _writes = Future.value();
  Timer? _settingsTimer;

  rd.PDFPreferences get _preferences => rd.PDFPreferences(
    layout: _layout,
    fit: rd.PDFFit.width,
    pageSpacing: _pageSpacing,
    // Keep one page visible even on landscape screens and tablets.
    spread: rd.PDFSpread.never,
  );
  int get _page => _position?.locations?.position ?? 1;
  double get _progress =>
      (_position?.locations?.totalProgression ??
              _position?.locations?.progression ??
              0)
          .clamp(0.0, 1.0);

  Map<String, dynamic>? get _bookmark {
    final position = _position;
    if (position == null) return null;
    for (final row in _bookmarks) {
      final locator = _locator(ReaderAnchor.fromJson(row['anchor']));
      if (locator?.href == position.href &&
          locator?.locations?.position == position.locations?.position) {
        return row;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _repository = ref.read(bookshelfRepositoryProvider);
    unawaited(_open());
  }

  void _report(Object? error) {
    if (mounted && error != null && !_closing) {
      setState(() => _error = '操作失败：$error');
    }
  }

  rd.Locator? _locator(ReaderAnchor? anchor) {
    if (anchor?.type != 'readium' || anchor == null) return null;
    return rd.Locator.fromJson(anchor.value);
  }

  Future<void> _open() async {
    try {
      if (_repository is! PublicationFileRepository) {
        throw StateError('仓库需要提供 PDF 文件路径');
      }
      final pathFuture = (_repository as PublicationFileRepository)
          .publicationPath(widget.book);
      final values = await Future.wait<Object>([
        _repository.loadSettings(),
        _repository.loadNotes(widget.book.id, ReaderNoteKind.bookmark),
        pathFuture,
      ]);
      final settings = values[0] as ReaderSettings;
      // Legacy "paginated" and unknown values use horizontal page snapping.
      _layout = settings.pdfLayout == rd.PDFLayout.scrollVertical.name
          ? rd.PDFLayout.scrollVertical
          : rd.PDFLayout.scrollHorizontal;
      _menuConfig.setTheme(
        engine.ReaderTheme.fromAlias(settings.dark ? 'night' : settings.theme),
      );
      _bookmarks
        ..clear()
        ..addAll(
          (values[1] as List<Map<String, dynamic>>).where(
            (row) => row['anchor'] != null,
          ),
        );
      final publication = await _reader.open(values[2] as String);
      if (!mounted) return;
      _position =
          _locator(widget.initialAnchor) ??
          _locator(widget.book.location.anchor) ??
          (publication.readingOrder.isEmpty
              ? null
              : publication.locatorFromLink(publication.readingOrder.first));
      _subscriptions.add(
        _reader.positions.listen(_onPosition, onError: _report),
      );
      _subscriptions.add(_reader.errors.listen(_report));
      setState(() => _publication = publication);
    } catch (error) {
      _report(error);
    }
  }

  void _onPosition(rd.Locator locator) {
    _position = locator;
    final page = locator.locations?.position ?? 1;
    final location = ReadingLocation(
      chapter: page > 0 ? page - 1 : 0,
      progress: locator.locations?.totalProgression ?? 0,
      anchor: ReaderAnchor(type: 'readium', value: locator.toJson()),
    );
    _writes = _writes.then(
      (_) => _repository.saveLocation(widget.book.id, location),
      onError: (_) => _repository.saveLocation(widget.book.id, location),
    );
    if (mounted) setState(() {});
  }

  Future<void> _finishOpeningSurface() async {
    if (_surfaceReady || _configuringSurface || _closing) return;
    _configuringSurface = true;
    try {
      await _reader.configure(_preferences);
      final initial = _position;
      if (initial != null) await _reader.goTo(initial);
    } catch (error) {
      _report(error);
    } finally {
      _configuringSurface = false;
      if (mounted && !_closing) setState(() => _surfaceReady = true);
    }
  }

  Future<void> _toggleBookmark() async {
    final position = _position;
    if (position == null) return;
    final existing = _bookmark;
    setState(() {
      if (existing != null) {
        _bookmarks.remove(existing);
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        final chapter = resolvePdfBookmarkChapter(
          toc: _publication?.tableOfContents ?? const [],
          locator: position,
          page: _page,
        );
        _bookmarks.add({
          'id': 'pdf-bookmark:${position.href}:$_page',
          'anchor': ReaderAnchor(
            type: 'readium',
            value: position.toJson(),
          ).toJson(),
          'createdAt': now,
          'chapterIndex': _page - 1,
          'chapterTitle': chapter.title,
          'chapterGroupKey': chapter.key,
          'charOffset': 0,
          'excerpt': '第 $_page 页',
        });
      }
    });
    final snapshot = _bookmarks.map(Map<String, dynamic>.of).toList();
    _writes = _writes.then(
      (_) => _repository.saveNotes(
        widget.book.id,
        ReaderNoteKind.bookmark,
        snapshot,
      ),
      onError: (_) => _repository.saveNotes(
        widget.book.id,
        ReaderNoteKind.bookmark,
        snapshot,
      ),
    );
    try {
      await _writes;
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _goToBookmark(Map<String, dynamic> bookmark) async {
    final locator = _locator(ReaderAnchor.fromJson(bookmark['anchor']));
    if (locator == null) return;
    _menu.value = false;
    await _reader.goTo(locator);
  }

  Future<void> _goByLink(rd.Link link) async {
    final publication = _publication;
    if (publication == null) return;
    _menu.value = false;
    if (!await _reader.goByLink(link, publication)) {
      throw StateError('无法跳转到该目录');
    }
  }

  Future<void> _seek(double value) async {
    _menu.value = false;
    if (!await _reader.goToProgression(value)) {
      throw StateError('无法跳转到该位置');
    }
  }

  void _updateLayout(rd.PDFLayout layout) {
    setState(() => _layout = layout);
    unawaited(_reader.configure(_preferences).catchError(_report));
    _settingsTimer?.cancel();
    _settingsTimer = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_saveSettings()),
    );
  }

  Future<void> _saveSettings() async {
    try {
      final previous = await _repository.loadSettings();
      await _repository.saveSettings(
        ReaderSettings(
          fontSize: previous.fontSize,
          dark: previous.dark,
          theme: previous.theme,
          flipMode: previous.flipMode,
          lineHeight: previous.lineHeight,
          paragraphSpacing: previous.paragraphSpacing,
          firstLineIndent: previous.firstLineIndent,
          justify: previous.justify,
          dimLevel: previous.dimLevel,
          fontFamily: previous.fontFamily,
          epubScroll: previous.epubScroll,
          pdfLayout: _layout.name,
          pdfFit: rd.PDFFit.width.name,
          pdfPageSpacing: _pageSpacing,
        ),
      );
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _openNavigationPanel() async {
    final publication = _publication;
    if (publication == null) return;
    final links = <rd.Link>[];
    engine.BookTocEntry buildEntry(rd.Link link) {
      final index = links.length;
      links.add(link);
      return engine.BookTocEntry(
        id: 'pdf-toc-$index',
        title: link.title?.trim().isNotEmpty == true
            ? link.title!
            : '第 ${index + 1} 节',
        chapterIndex: index,
        children: [for (final child in link.children) buildEntry(child)],
      );
    }

    // Destinations use catalogue indices, never assumed PDF page numbers.
    // Bookmarks use a separate offset namespace to retain exact locators.
    final destinations = <(int, int), Map<String, dynamic>>{};
    final bookmarkRows = <engine.Bookmark, Map<String, dynamic>>{};
    final bookmarkGroups = <engine.Bookmark, String>{};
    for (var i = 0; i < _bookmarks.length; i++) {
      final row = _bookmarks[i];
      final locator = _locator(ReaderAnchor.fromJson(row['anchor']));
      final page =
          locator?.locations?.position ??
          ((row['chapterIndex'] as num?)?.toInt() ?? 0) + 1;
      final chapter = resolvePdfBookmarkChapter(
        toc: publication.tableOfContents,
        locator: locator,
        page: page,
        savedTitle: row['chapterTitle'] as String?,
        savedKey: row['chapterGroupKey'] as String?,
      );
      final bookmark = engine.Bookmark(
        chapterIndex: page - 1,
        charOffset: -(i + 1),
        chapterTitle: chapter.title,
        excerpt: row['excerpt'] as String? ?? '',
        createdAt: (row['createdAt'] as num?)?.toInt() ?? 0,
      );
      bookmarkRows[bookmark] = row;
      bookmarkGroups[bookmark] = chapter.key;
      destinations[(bookmark.chapterIndex, bookmark.charOffset)] = row;
    }
    final toc = [
      for (final link in publication.tableOfContents) buildEntry(link),
    ];
    final current = resolvePdfTocIndex(
      toc: publication.tableOfContents,
      locator: _position,
      page: _page,
    );
    final picked = await showModalBottomSheet<engine.ReadingPosition>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.92,
        builder: (context, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: ColoredBox(
            color: _menuConfig.theme.paperColor,
            child: engine.CatalogSheet(
              bookTitle: widget.book.title,
              author: widget.book.author,
              intro: '',
              coverColor: const Color(0xFFA6A6A6),
              coverBuilder: (_) => BookCover(book: widget.book),
              chapterTitles: [for (final entry in links) entry.title ?? '目录'],
              toc: toc,
              currentIndex: current ?? 0,
              theme: _menuConfig.theme,
              scrollController: scrollController,
              bookmarksOnly: true,
              emptyCatalogMessage: '该 PDF 没有可用目录',
              initialTabIndex: 0,
              bookmarks: bookmarkRows.keys.toList(),
              bookmarkGroupKey: (bookmark) => bookmarkGroups[bookmark]!,
              onDeleteBookmark: (bookmark) {
                final row = bookmarkRows[bookmark];
                if (row != null) unawaited(_guard(() => _removeBookmark(row)));
              },
            ),
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    final row = destinations[(picked.chapterIndex, picked.charOffset)];
    if (row != null) {
      await _goToBookmark(row);
    } else if (picked.charOffset == 0 &&
        picked.chapterIndex >= 0 &&
        picked.chapterIndex < links.length) {
      await _goByLink(links[picked.chapterIndex]);
    }
  }

  Future<void> _removeBookmark(Map<String, dynamic> bookmark) async {
    setState(() => _bookmarks.remove(bookmark));
    final snapshot = _bookmarks.map(Map<String, dynamic>.of).toList();
    _writes = _writes.then(
      (_) => _repository.saveNotes(
        widget.book.id,
        ReaderNoteKind.bookmark,
        snapshot,
      ),
      onError: (_) => _repository.saveNotes(
        widget.book.id,
        ReaderNoteKind.bookmark,
        snapshot,
      ),
    );
    await _writes;
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _settingsTimer?.cancel();
    await _saveSettings();
    setState(() => _closing = true);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _writes;
    await _reader.dispose();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _settingsTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_reader.dispose());
    _menu.dispose();
    _menuConfig.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final publication = _publication;
    return PopScope(
      canPop: _closing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: _menuConfig.theme.paperColor,
        body: publication == null
            ? _error == null
                  ? _PdfLoading(theme: _menuConfig.theme)
                  : _PdfError(message: _error!)
            : Stack(
                fit: StackFit.expand,
                children: [
                  rd.ReadiumReaderWidget(
                    publication: publication,
                    initialLocator: _position,
                    // The native PDF surface defaults to black until it has
                    // painted its first page. Keep the same paper-coloured
                    // loading state as the TXT and EPUB readers over it.
                    loadingWidget: _PdfLoading(theme: _menuConfig.theme),
                    shouldShowControls: _menu,
                    goBackwardSemanticLabel: '上一页',
                    goForwardSemanticLabel: '下一页',
                    toggleShowControlsSemanticLabel: 'PDF 阅读菜单',
                    onReaderReady: () {
                      unawaited(_finishOpeningSurface());
                    },
                  ),
                  if (!_surfaceReady)
                    Positioned.fill(
                      child: _PdfLoading(theme: _menuConfig.theme),
                    ),
                  ValueListenableBuilder<bool>(
                    valueListenable: _menu,
                    builder: (context, visible, _) => PdfReaderMenu(
                      visible: visible,
                      title: widget.book.title,
                      page: _page,
                      progress: _progress,
                      bookmarked: _bookmark != null,
                      layout: _layout,
                      config: _menuConfig,
                      onDismiss: () => _menu.value = false,
                      onBack: () => unawaited(_close()),
                      onToggleBookmark: () => unawaited(_toggleBookmark()),
                      onPrevious: () =>
                          unawaited(_reader.previous().catchError(_report)),
                      onNext: () =>
                          unawaited(_reader.next().catchError(_report)),
                      onSeek: (value) => unawaited(_guard(() => _seek(value))),
                      onCatalog: () => unawaited(_guard(_openNavigationPanel)),
                      onLayoutChanged: _updateLayout,
                    ),
                  ),
                  if (_error != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: MaterialBanner(
                        content: Text(_error!),
                        actions: [
                          TextButton(
                            onPressed: () => setState(() => _error = null),
                            child: const Text('知道了'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _PdfError extends StatelessWidget {
  const _PdfError({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(message, textAlign: TextAlign.center),
    ),
  );
}

class _PdfLoading extends StatelessWidget {
  const _PdfLoading({required this.theme});
  final engine.ReaderTheme theme;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: theme.paperColor,
    child: Center(
      child: Semantics(
        label: '正在加载图书正文',
        child: CircularProgressIndicator(color: theme.accentColor),
      ),
    ),
  );
}

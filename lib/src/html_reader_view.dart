import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'bookshelf_view.dart';
import 'models.dart';
import 'providers.dart';
import 'repository.dart';
import 'theme/reader_palette.dart';

class HtmlReaderView extends ConsumerStatefulWidget {
  const HtmlReaderView({super.key, required this.book});

  final Book book;

  @override
  ConsumerState<HtmlReaderView> createState() => _HtmlReaderViewState();
}

class _HtmlReaderViewState extends ConsumerState<HtmlReaderView>
    with WidgetsBindingObserver {
  late final BookshelfRepository _repository;
  BookContent? _content;
  BookContent? _resourceContent;
  Object? _error;
  ReaderSettings _settings = const ReaderSettings();
  late ReadingLocation _location;
  final _positions = ItemPositionsListener.create();
  final _scroll = ItemScrollController();
  Timer? _debounce;
  bool _restoring = true;
  bool _controlsVisible = true;
  double _readingViewportHeight = 1;
  double get _readingTopAlignment => _controlsVisible
      ? (kToolbarHeight / _readingViewportHeight).clamp(0, 1)
      : 0;
  double? _scrubProgress;
  int _contentCharacters = 0;
  final _expandedToc = <String>{};
  final _imageLoads = <String, Future<Uint8List?>>{};
  final _imageBytes = <String, Uint8List?>{};

  Widget _bookImage(BookContent content, String path) {
    Widget image(Uint8List? bytes) => bytes == null
        ? const Text('图片暂不支持显示')
        : Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const Text('图片暂不支持显示'),
          );

    // Use completed bytes synchronously even if HtmlWidget remounts the image.
    if (_imageBytes.containsKey(path)) return image(_imageBytes[path]);
    final future = _imageLoads.putIfAbsent(path, () async {
      final bytes = await (_resourceContent ?? content).resource(path);
      _imageBytes[path] = bytes;
      return bytes;
    });
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          return image(snapshot.data);
        }
        return const SizedBox(height: 60);
      },
    );
  }

  List<_ReaderItem> get _items {
    final content = _content;
    if (content == null) return const [];
    return [
      for (var chapter = 0; chapter < content.chapters.length; chapter++) ...[
        _ReaderItem.heading(chapter),
        for (
          var block = 0;
          block < content.chapters[chapter].blocks.length;
          block++
        )
          _ReaderItem.block(chapter, block),
      ],
    ];
  }

  bool _showsChapterHeading(String title) => !RegExp(
    r'^(|第\s*\d+\s*节|封面|扉页|书名页|版权页|目录|序言|后记|封底)$',
  ).hasMatch(title.trim());

  bool _isConceptualPage(BookChapter chapter) =>
      chapter.kind != BookChapterKind.content;

  String _indentedParagraphs(String markup) => markup.replaceAllMapped(
    RegExp(r'<p(?:\s[^>]*)?>', caseSensitive: false),
    (match) => '${match.group(0)}　　',
  );

  int _itemIndexFor(ReadingLocation location) {
    final content = _content!;
    var index = 0;
    for (var chapter = 0; chapter < location.chapter; chapter++) {
      index += content.chapters[chapter].blocks.length + 1;
    }
    return index + location.block + 1;
  }

  @override
  void initState() {
    super.initState();
    _repository = ref.read(bookshelfRepositoryProvider);
    _location = widget.book.location;
    WidgetsBinding.instance.addObserver(this);
    _positions.itemPositions.addListener(_onScroll);
    _load();
  }

  Future<void> _load() async {
    try {
      final contentFuture = _repository.openBook(widget.book);
      final settingsFuture = _repository.loadSettings();
      final loaded = await contentFuture;
      final content = MemoryBookContent(
        title: loaded.title,
        author: loaded.author,
        toc: loaded.toc,
        chapters: [
          for (var i = 0; i < loaded.chapters.length; i++)
            await loaded.readChapter(i),
        ],
      );
      // Preserve resource access while hydrating the compatibility view.
      _resourceContent = loaded;
      final settings = await settingsFuture;
      if (!mounted) return;
      final chapter = _location.chapter.clamp(0, content.chapters.length - 1);
      final block = _location.block.clamp(
        0,
        content.chapters[chapter].blocks.length - 1,
      );
      setState(() {
        _imageLoads.clear();
        _imageBytes.clear();
        _content = content;
        _contentCharacters = content.chapters.fold<int>(
          0,
          (total, chapter) =>
              total +
              chapter.blocks.fold<int>(
                0,
                (chapterTotal, block) =>
                    chapterTotal +
                    block
                        .replaceAll(RegExp(r'<[^>]*>'), ' ')
                        .trim()
                        .length
                        .clamp(80, 1 << 30),
              ),
        );
        _settings = settings;
        _error = null;
        _location = ReadingLocation(
          chapter: chapter,
          block: block,
          progress: _location.progress,
        );
      });
      _finishRestore();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _finishRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _restoring = false;
      }
    });
  }

  void _onScroll() {
    if (_restoring || _content == null) return;
    final visible =
        _positions.itemPositions.value
            .where(
              (p) =>
                  p.itemTrailingEdge > _readingTopAlignment &&
                  p.itemLeadingEdge < 1,
            )
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isEmpty) return;
    final item = _items[visible.first.index];
    final chapter = item.chapter;
    final block = item.block ?? 0;
    final chapters = _content!.chapters;
    final total = chapters.fold<int>(0, (n, c) => n + c.blocks.length);
    final before = chapters
        .take(chapter)
        .fold<int>(0, (n, c) => n + c.blocks.length);
    final lastItem = _items[visible.last.index];
    final atEnd =
        lastItem.chapter == chapters.length - 1 &&
        lastItem.block == chapters.last.blocks.length - 1 &&
        visible.last.itemTrailingEdge <= 1.001;
    final progress = atEnd ? 1.0 : (before + block) / total;
    if (chapter == _location.chapter &&
        block == _location.block &&
        progress == _location.progress) {
      return;
    }
    setState(
      () => _location = ReadingLocation(
        chapter: chapter,
        block: block,
        progress: progress,
      ),
    );
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), _save);
  }

  Future<void> _save() async {
    _debounce?.cancel();
    if (_content == null) return;
    try {
      await _repository.saveLocation(widget.book.id, _location);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('阅读进度保存失败，请检查可用存储空间')));
      }
    }
  }

  void _chapter(int chapter) {
    if (chapter < 0 || chapter >= _content!.chapters.length) return;
    final chapters = _content!.chapters;
    final before = chapters
        .take(chapter)
        .fold<int>(0, (n, c) => n + c.blocks.length);
    final total = chapters.fold<int>(0, (n, c) => n + c.blocks.length);
    _jumpTo(
      ReadingLocation(chapter: chapter, progress: before / total),
      chapterStart: true,
    );
  }

  void _jumpTo(ReadingLocation location, {bool chapterStart = false}) {
    _debounce?.cancel();
    _restoring = true;
    setState(() {
      _location = location;
      _scrubProgress = null;
    });
    _scrollTo(location, chapterStart: chapterStart);
    _save();
  }

  Future<void> _scrollTo(
    ReadingLocation location, {
    bool chapterStart = false,
  }) async {
    if (!_scroll.isAttached) {
      await WidgetsBinding.instance.endOfFrame;
    }
    if (mounted && _scroll.isAttached) {
      await _scroll.scrollTo(
        index: chapterStart
            ? _itemIndexFor(location) - 1
            : _itemIndexFor(location),
        alignment: _readingTopAlignment,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
    if (mounted) _finishRestore();
  }

  ReadingLocation _locationAtProgress(double progress) {
    final chapters = _content!.chapters;
    final total = chapters.fold<int>(0, (n, c) => n + c.blocks.length);
    var target = (progress * total).floor().clamp(0, total - 1);
    for (var chapter = 0; chapter < chapters.length; chapter++) {
      final blocks = chapters[chapter].blocks.length;
      if (target < blocks) {
        return ReadingLocation(
          chapter: chapter,
          block: target,
          progress: progress,
        );
      }
      target -= blocks;
    }
    final last = chapters.length - 1;
    return ReadingLocation(
      chapter: last,
      block: chapters.last.blocks.length - 1,
      progress: 1,
    );
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
  }

  Future<void> _changeSettings(ReaderSettings settings) async {
    _restoring = true;
    setState(() {
      _settings = settings;
    });
    _finishRestore();
    try {
      await _repository.saveSettings(settings);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('阅读设置保存失败')));
      }
    }
  }

  Future<void> _toc() async {
    // The toolbar may have changed visibility since the last scroll event.
    _onScroll();
    final active = _activeToc();
    void expand(List<BookTocEntry> entries) {
      for (final entry in entries) {
        if (_containsEntry(entry, active)) _expandedToc.add(entry.id);
        expand(entry.children);
      }
    }

    expand(_content!.toc);
    List<(BookTocEntry, int)> rows() {
      final result = <(BookTocEntry, int)>[];
      void add(List<BookTocEntry> entries, int depth) {
        for (final entry in entries) {
          result.add((entry, depth));
          if (_expandedToc.contains(entry.id)) add(entry.children, depth + 1);
        }
      }

      add(_content!.toc, 0);
      return result;
    }

    final initial = rows().indexWhere((row) => identical(row.$1, active));
    final selected = await showModalBottomSheet<BookTocEntry>(
      context: context,
      showDragHandle: true,
      enableDrag: true,
      builder: (context) {
        return SafeArea(
          child: ScrollConfiguration(
            behavior: const _ReaderScrollBehavior(),
            child: StatefulBuilder(
              builder: (context, update) {
                final visible = rows();
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final contentFits =
                        visible.length * kMinInteractiveDimension <=
                        constraints.maxHeight;
                    return ScrollablePositionedList.builder(
                      initialScrollIndex: contentFits
                          ? 0
                          : initial < 0
                          ? 0
                          : initial,
                      initialAlignment: contentFits ? 0 : .35,
                      physics: const ClampingScrollPhysics(),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final (entry, depth) = visible[index];
                        final isActive = identical(entry, active);
                        final colors = Theme.of(context).colorScheme;
                        return ListTile(
                          contentPadding: EdgeInsets.only(
                            left: 16 + depth * 20,
                            right: 8,
                          ),
                          selected: isActive,
                          selectedTileColor: colors.primary.withValues(
                            alpha: .10,
                          ),
                          selectedColor: colors.primary,
                          title: Text(
                            entry.title,
                            style: TextStyle(
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          onTap: entry.chapter == null
                              ? null
                              : () => Navigator.pop(context, entry),
                          trailing: entry.children.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: _expandedToc.contains(entry.id)
                                      ? '折叠'
                                      : '展开',
                                  icon: Icon(
                                    _expandedToc.contains(entry.id)
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                  ),
                                  onPressed: () => update(() {
                                    if (!_expandedToc.remove(entry.id)) {
                                      _expandedToc.add(entry.id);
                                    }
                                  }),
                                ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
    if (selected?.chapter != null && mounted) {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        final chapters = _content!.chapters;
        final chapter = selected!.chapter!;
        final block = (selected.block ?? 0).clamp(
          0,
          chapters[chapter].blocks.length - 1,
        );
        final before = chapters
            .take(chapter)
            .fold<int>(0, (n, c) => n + c.blocks.length);
        final total = chapters.fold<int>(0, (n, c) => n + c.blocks.length);
        _jumpTo(
          ReadingLocation(
            chapter: chapter,
            block: block,
            progress: (before + block) / total,
          ),
          chapterStart:
              selected.block == null ||
              (block == 0 && _content!.toc.contains(selected)),
        );
      }
    }
  }

  bool _containsEntry(BookTocEntry entry, BookTocEntry? active) =>
      identical(entry, active) ||
      entry.children.any((child) => _containsEntry(child, active));

  BookTocEntry? _activeToc() {
    BookTocEntry? best;
    void visit(List<BookTocEntry> entries) {
      for (final entry in entries) {
        final chapter = entry.chapter;
        final block = entry.block ?? 0;
        if (chapter != null &&
            (chapter < _location.chapter ||
                chapter == _location.chapter && block <= _location.block) &&
            (best == null ||
                chapter > best!.chapter! ||
                chapter == best!.chapter && block >= (best!.block ?? 0))) {
          best = entry;
        }
        visit(entry.children);
      }
    }

    visit(_content!.toc);
    return best;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _save();
  }

  @override
  void dispose() {
    _save();
    _positions.itemPositions.removeListener(_onScroll);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = _settings.dark;
    final foreground = dark ? ReaderPalette.nightInk : ReaderPalette.ink;
    final titleColor = dark
        ? ReaderPalette.nightInk
        : ReaderPalette.inkSecondary;
    final h2Color = _hexColor(
      dark ? ReaderPalette.nightHeading : ReaderPalette.heading,
    );
    final h3Color = _hexColor(
      dark ? ReaderPalette.nightSubheading : ReaderPalette.subheading,
    );
    final background = dark
        ? ReaderPalette.nightBackground
        : ReaderPalette.background;
    final controlsBackground = dark
        ? ReaderPalette.nightSheet
        : ReaderPalette.sheet;
    final content = _content;
    final displayedProgress = _scrubProgress ?? _location.progress;
    final viewport = MediaQuery.sizeOf(context);
    final charactersPerLine =
        ((viewport.width - 48) / (_settings.fontSize * .55)).floor().clamp(
          12,
          1 << 30,
        );
    final linesPerPage = ((viewport.height - 248) / (_settings.fontSize * 1.8))
        .floor()
        .clamp(4, 1 << 30);
    final totalPages = _contentCharacters == 0
        ? 0
        : (_contentCharacters / (charactersPerLine * linesPerPage)).ceil();
    final currentPage = totalPages == 0
        ? 0
        : (displayedProgress * totalPages).floor().clamp(0, totalPages - 1) + 1;
    return Theme(
      data: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        colorScheme: dark
            ? ReaderPalette.darkTheme().colorScheme
            : ReaderPalette.lightTheme().colorScheme,
        scaffoldBackgroundColor: background,
      ),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: background,
          systemNavigationBarColor: background,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        ),
        child: Scaffold(
          extendBodyBehindAppBar: true,
          extendBody: true,
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(kToolbarHeight),
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              offset: _controlsVisible ? Offset.zero : const Offset(0, -1),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: AppBar(
                  backgroundColor: controlsBackground,
                  elevation: _controlsVisible ? 4 : 0,
                  scrolledUnderElevation: _controlsVisible ? 4 : 0,
                  surfaceTintColor: Colors.transparent,
                  shadowColor: Colors.black.withValues(alpha: dark ? .4 : .18),
                  title: Text(widget.book.title),
                ),
              ),
            ),
          ),
          body: _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(readerError(_error!)),
                      TextButton(
                        onPressed: () {
                          setState(() => _error = null);
                          _load();
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : content == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    // Only the status bar reserves space. The toolbar overlays
                    // a stable viewport; jumps account for it via alignment.
                    SizedBox(height: MediaQuery.viewPaddingOf(context).top),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _toggleControls,
                        child: ScrollConfiguration(
                          behavior: const _ReaderScrollBehavior(),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              _readingViewportHeight = constraints.maxHeight;
                              return ScrollablePositionedList.builder(
                                itemScrollController: _scroll,
                                itemPositionsListener: _positions,
                                initialScrollIndex: _itemIndexFor(_location),
                                initialAlignment: _readingTopAlignment,
                                physics: const ClampingScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  0,
                                  24,
                                  160,
                                ),
                                itemCount: _items.length,
                                itemBuilder: (context, index) {
                                  final item = _items[index];
                                  final chapter =
                                      content.chapters[item.chapter];
                                  if (item.block == null) {
                                    if (_isConceptualPage(chapter) ||
                                        !_showsChapterHeading(chapter.title)) {
                                      return const SizedBox(height: 60);
                                    }
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        top: 20,
                                        bottom: 12,
                                      ),
                                      child: Center(
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 760,
                                          ),
                                          child: Text(
                                            chapter.title,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize:
                                                  _settings.fontSize * 1.35,
                                              fontWeight: FontWeight.w600,
                                              color: titleColor,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  return Center(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 760,
                                      ),
                                      child: HtmlWidget(
                                        _indentedParagraphs(
                                          chapter.blocks[item.block!],
                                        ),
                                        textStyle: TextStyle(
                                          fontSize: _settings.fontSize,
                                          height: 1.8,
                                          color: foreground,
                                        ),
                                        customStylesBuilder: (element) {
                                          switch (element.localName) {
                                            case 'p':
                                              return {'text-indent': '2em'};
                                            case 'h2': // 节
                                              return {
                                                'font-size':
                                                    '${_settings.fontSize * 1.18}px',
                                                'font-weight': '600',
                                                'text-align': 'center',
                                                'margin-top': '1.8em',
                                                'margin-bottom': '.7em',
                                                'color': h2Color,
                                              };
                                            case 'h3':
                                              return {
                                                'font-size':
                                                    '${_settings.fontSize}px',
                                                'font-weight': '600',
                                                'text-align': 'center',
                                                'margin-top': '1.5em',
                                                'margin-bottom': '.6em',
                                                'color': h3Color,
                                              };
                                          }
                                          return null;
                                        },
                                        onTapUrl: (_) async => true,
                                        customWidgetBuilder: (element) {
                                          if (element.localName != 'img') {
                                            return null;
                                          }
                                          final path = element
                                              .attributes['data-reader-resource'];
                                          if (path == null) {
                                            return const SizedBox.shrink();
                                          }
                                          return _bookImage(content, path);
                                        },
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
          bottomNavigationBar: content == null
              ? null
              : AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: _controlsVisible
                      ? ColoredBox(
                          color: controlsBackground,
                          child: SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      IconButton(
                                        tooltip: '上一章',
                                        onPressed: _location.chapter > 0
                                            ? () => _chapter(
                                                _location.chapter - 1,
                                              )
                                            : null,
                                        icon: const Icon(Icons.chevron_left),
                                      ),
                                      Expanded(
                                        child: SliderTheme(
                                          data: SliderTheme.of(context)
                                              .copyWith(
                                                trackHeight: 8,
                                                activeTrackColor: dark
                                                    ? ReaderPalette.nightInk
                                                    : ReaderPalette.accent,
                                                inactiveTrackColor: dark
                                                    ? ReaderPalette.nightSheet
                                                    : ReaderPalette.track,
                                                thumbShape:
                                                    const RoundSliderThumbShape(
                                                      enabledThumbRadius: 9,
                                                    ),
                                              ),
                                          child: Slider(
                                            value: displayedProgress,
                                            onChanged: (value) => setState(
                                              () => _scrubProgress = value,
                                            ),
                                            onChangeEnd: (value) => _jumpTo(
                                              _locationAtProgress(value),
                                            ),
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '下一章',
                                        onPressed:
                                            _location.chapter <
                                                content.chapters.length - 1
                                            ? () => _chapter(
                                                _location.chapter + 1,
                                              )
                                            : null,
                                        icon: const Icon(Icons.chevron_right),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      IconButton(
                                        tooltip: '目录',
                                        onPressed: _toc,
                                        icon: const Icon(Icons.list),
                                      ),
                                      IconButton(
                                        tooltip: dark ? '日间模式' : '夜间模式',
                                        icon: Icon(
                                          dark
                                              ? Icons.light_mode_outlined
                                              : Icons.dark_mode_outlined,
                                        ),
                                        onPressed: () => _changeSettings(
                                          _settings.copyWith(
                                            fontSize: _settings.fontSize,
                                            dark: !dark,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          '$currentPage/$totalPages · ${(displayedProgress * 100).round()}%',
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '缩小字号',
                                        onPressed: _settings.fontSize > 14
                                            ? () => _changeSettings(
                                                _settings.copyWith(
                                                  fontSize:
                                                      _settings.fontSize - 2,
                                                  dark: dark,
                                                ),
                                              )
                                            : null,
                                        icon: const Icon(Icons.text_decrease),
                                      ),
                                      IconButton(
                                        tooltip: '放大字号',
                                        onPressed: _settings.fontSize < 32
                                            ? () => _changeSettings(
                                                _settings.copyWith(
                                                  fontSize:
                                                      _settings.fontSize + 2,
                                                  dark: dark,
                                                ),
                                              )
                                            : null,
                                        icon: const Icon(Icons.text_increase),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
        ),
      ),
    );
  }

  String _hexColor(Color color) =>
      '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
}

class _ReaderScrollBehavior extends MaterialScrollBehavior {
  const _ReaderScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

class _ReaderItem {
  const _ReaderItem.heading(this.chapter) : block = null;

  const _ReaderItem.block(this.chapter, this.block);

  final int chapter;
  final int? block;
}

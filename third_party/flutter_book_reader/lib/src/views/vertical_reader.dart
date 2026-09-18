import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../paginator.dart';
import '../widgets/page_frame.dart';
import 'reader_mode_view.dart';

/// Paragraph anchors survive lazy chapter insertion, font changes and navigation.
class VerticalReader extends ReaderModeView {
  const VerticalReader({
    super.key,
    required super.controller,
    required this.onTapToggleMenu,
  });
  final VoidCallback onTapToggleMenu;
  @override
  State<VerticalReader> createState() => _VerticalReaderState();
}

class _VerticalReaderState extends ReaderModeViewState<VerticalReader>
    with SingleTickerProviderStateMixin {
  final _scroll = ItemScrollController();
  final _scrollOffset = ScrollOffsetController();
  final _positions = ItemPositionsListener.create();
  final _paragraphKeys = <(int, int), GlobalKey>{};
  final _paragraphPages = <(int, int), ReaderPage>{};
  late final _ticker = createTicker(_tick);
  List<_Entry> _entries = [];
  late List<int> _flow;
  int _chapter = 0;
  int _offset = 0;
  bool _restoring = true;
  bool _queued = false;
  bool _updating = false;
  bool _moving = false;
  double _height = 1;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _flow = controller.flowChapters;
    _chapter = controller.chapterIndex;
    _offset = controller.charOffset;
    controller.addListener(_sync);
    config.addListener(_onConfigChanged);
    _positions.itemPositions.addListener(_positionsChanged);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _requestRestore();
  }

  void _sync() {
    if (controller.autoTurning) {
      if (!_ticker.isActive) {
        _lastTick = Duration.zero;
        _ticker.start();
      }
    } else {
      _ticker.stop();
    }
    if (_updating) return;
    if (!identical(_flow, controller.flowChapters)) {
      _flow = controller.flowChapters;
      _chapter = controller.chapterIndex;
      _offset = controller.charOffset;
    }
    _requestRestore();
  }

  void _requestRestore() {
    if (!mounted || _queued) return;
    _restoring = true;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted || !_scroll.isAttached || _entries.isEmpty) return;
      var index = _entries.indexWhere((e) => e.chapter == _chapter);
      if (index < 0) return;
      for (var i = index;
          i < _entries.length && _entries[i].chapter == _chapter;
          i++) {
        final e = _entries[i];
        if (e.block != null && e.offset <= _offset && _offset > 0) index = i;
      }
      _scroll.jumpTo(index: index);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.isAttached) return;
        if (index >= _entries.length) return;
        final entry = _entries[index];
        final paragraph = _paragraph(entry);
        if (paragraph != null &&
            entry.block != null &&
            _offset > entry.offset) {
          final y = paragraph
              .getOffsetForCaret(
                TextPosition(
                  offset: (_offset - entry.offset).clamp(
                    0,
                    entry.block!.text.length,
                  ),
                ),
                Rect.zero,
              )
              .dy;
          _scroll.jumpTo(index: index, alignment: -y / _height);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _restoring = false;
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _onConfigChanged() {
    _paragraphPages.clear();
    _requestRestore();
  }

  ReaderPage _pageFor(_Entry entry) {
    final key = (entry.chapter, entry.offset);
    final previous = _paragraphPages[key];
    final block = entry.block!;
    // ReaderProse clears its selection on a new page identity. Ordinary list
    // rebuilds (including overlay insertion) must retain the same paragraph.
    if (previous != null && previous.single.text == block.text &&
        previous.single.isParagraphStart == block.isParagraphStart &&
        previous.single.isParagraphEnd == block.isParagraphEnd) {
      return previous;
    }
    return _paragraphPages[key] = [block];
  }

  RenderParagraph? _paragraph(_Entry entry) {
    final root = _paragraphKeys[(entry.chapter, entry.offset)]
        ?.currentContext
        ?.findRenderObject();
    RenderParagraph? result;
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        result ??= object;
        return;
      }
      object.visitChildren(visit);
    }

    if (root != null) visit(root);
    return result;
  }

  void _positionsChanged() {
    if (_restoring || !mounted) return;
    final visible = _positions.itemPositions.value
        .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isEmpty) return;
    final item = visible.first;
    if (item.index >= _entries.length) return;
    final entry = _entries[item.index];
    var offset = entry.offset;
    final paragraph = _paragraph(entry);
    if (paragraph != null && entry.block != null && item.itemLeadingEdge < 0) {
      offset += paragraph
          .getPositionForOffset(Offset(0, -item.itemLeadingEdge * _height))
          .offset;
    }
    _chapter = entry.chapter;
    _offset = offset;
    // Do not notify/rebuild during layout. Capture the anchor before scheduling.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _restoring) return;
      _updating = true;
      final changed = controller.chapterIndex != _chapter ||
          controller.charOffset != _offset;
      controller.chapterIndex = _chapter;
      controller.charOffset = _offset;
      controller.signature = '';
      controller.flowChapters = _flow = [
        if (_chapter > 0) _chapter - 1,
        _chapter,
        if (_chapter + 1 < controller.chapterCount) _chapter + 1,
      ];
      controller.prefetchAround(_chapter);
      if (changed) controller.notifyListeners();
      _updating = false;
      if (controller.autoTurning &&
          visible.last.index == _entries.length - 1 &&
          visible.last.itemTrailingEdge <= 1) {
        controller.setAutoTurning(false);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _tick(Duration elapsed) {
    if (!_scroll.isAttached || _restoring || _moving) return;
    if (elapsed - _lastTick < const Duration(milliseconds: 80)) return;
    _lastTick = elapsed;
    _moving = true;
    _scrollOffset
        .animateScroll(
          offset: _height *
              .08 /
              (controller.autoTurnInterval.inMilliseconds / 1000),
          duration: const Duration(milliseconds: 80),
          curve: Curves.linear,
        )
        .whenComplete(() => _moving = false);
  }

  List<_Entry> _makeEntries() {
    final result = <_Entry>[];
    for (var chapter = 0; chapter < controller.chapterCount; chapter++) {
      result.add(_Entry(chapter, 0, heading: true));
      final body = controller.bodyOf(chapter);
      if (body == null) {
        result.add(_Entry(chapter, 0));
        continue;
      }
      var offset = 0;
      for (final block in controller.chapterBlocks(body)) {
        result.add(_Entry(chapter, offset, block: block));
        offset += block.length;
      }
    }
    final active = {
      for (final entry in result)
        if (entry.block != null) (entry.chapter, entry.offset),
    };
    _paragraphKeys.removeWhere((key, _) => !active.contains(key));
    _paragraphPages.removeWhere((key, _) => !active.contains(key));
    return result;
  }

  @override
  Widget build(BuildContext context) {
    _entries = _makeEntries();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTapToggleMenu,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              pagePadding.left,
              pagePadding.top,
              pagePadding.right,
              0,
            ),
            child: ReaderHeaderBar(
              title: controller.currentChapterTitle,
              theme: theme,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _height = constraints.maxHeight;
                return ScrollablePositionedList.builder(
                  itemScrollController: _scroll,
                  scrollOffsetController: _scrollOffset,
                  itemPositionsListener: _positions,
                  itemCount: _entries.length,
                  padding: EdgeInsets.symmetric(horizontal: pagePadding.left),
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    if (entry.heading) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 16),
                        child: Text(
                          controller.chapterTitleAt(entry.chapter),
                          style: config.headingStyle,
                        ),
                      );
                    }
                    if (entry.block == null) {
                      return SizedBox(
                        height: _height * .8,
                        child: Center(
                          child: controller.hasError(entry.chapter)
                              ? TextButton(
                                  onPressed: () =>
                                      controller.retry(entry.chapter),
                                  child: const Text('加载失败，点击重试'),
                                )
                              : const Text('正在加载章节…'),
                        ),
                      );
                    }
                    return Padding(
                      key: _paragraphKeys.putIfAbsent((
                        entry.chapter,
                        entry.offset,
                      ), () => GlobalKey()),
                      padding: EdgeInsets.only(bottom: config.paragraphSpacing),
                      child: ReaderProse(
                        page: _pageFor(entry),
                        config: config,
                        chapterIndex: entry.chapter,
                        chapterTitle: controller.chapterTitleAt(entry.chapter),
                        pageStartOffset: entry.offset,
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              pagePadding.left,
              0,
              pagePadding.right,
              pagePadding.bottom,
            ),
            child: ReaderFooterBar(
              theme: theme,
              chapterIndex: controller.chapterIndex,
              chapterCount: controller.chapterCount,
              pageIndex: 0,
              pageCount: 0,
              progress: controller.globalProgress,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    controller.removeListener(_sync);
    config.removeListener(_onConfigChanged);
    _positions.itemPositions.removeListener(_positionsChanged);
    super.dispose();
  }
}

class _Entry {
  const _Entry(this.chapter, this.offset, {this.heading = false, this.block});
  final int chapter, offset;
  final bool heading;
  final ReaderBlock? block;
}

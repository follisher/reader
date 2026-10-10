import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
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
    this.autoPauseListenable,
  });
  final VoidCallback onTapToggleMenu;
  final ValueListenable<bool>? autoPauseListenable;
  @override
  State<VerticalReader> createState() => _VerticalReaderState();
}

class _VerticalReaderState extends ReaderModeViewState<VerticalReader>
    with SingleTickerProviderStateMixin {
  final _selectionGroup = ReaderProseSelectionGroup();
  final _scroll = ItemScrollController();
  final _scrollOffset = ScrollOffsetController();
  final _positions = ItemPositionsListener.create();
  final _paragraphKeys = <(int, int), GlobalKey>{};
  final _paragraphPages = <(int, int), ReaderPage>{};
  late final _ticker = createTicker(_tick);
  List<_Entry> _entries = [];
  final _chapterEntries = <int, (String, List<_Entry>)>{};
  final _entryBodies = <int, String?>{};
  final _entryErrors = <int, bool>{};
  final _headingOffsets = <int, Set<int>>{};
  Duration? _lastAnchorSample;
  bool _scrolling = false;
  bool _pointerDown = false;
  bool _autoPausedForGesture = false;
  bool _pendingRestore = false;
  int _scrollGeneration = 0;
  int _restoreGeneration = 0;
  int _autoMotionGeneration = 0;
  Duration? _activeAutoInterval;
  Timer? _idleTimer;
  Timer? _menuResumeTimer;
  bool _menuResumePending = false;
  bool _entriesDirty = true;
  late List<int> _flow;
  int _chapter = 0;
  int _offset = 0;
  bool _restoring = true;
  bool _queued = false;
  bool _updating = false;
  bool _anchorUpdateQueued = false;
  bool _positionDirty = false;
  bool _moving = false;
  double _height = 1;
  late int _publishedChapter;
  late int _publishedOffset;
  late int _controllerChapter;
  late int _controllerOffset;

  @override
  void initState() {
    super.initState();
    _flow = controller.flowChapters;
    _chapter = controller.chapterIndex;
    _offset = controller.charOffset;
    _publishedChapter = _chapter;
    _publishedOffset = _offset;
    _controllerChapter = _chapter;
    _controllerOffset = _offset;
    controller.addListener(_sync);
    config.addListener(_onConfigChanged);
    widget.autoPauseListenable?.addListener(_onAutoPauseChanged);
    _positions.itemPositions.addListener(_positionsChanged);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _requestRestore();
  }

  @override
  void didUpdateWidget(covariant VerticalReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.autoPauseListenable != widget.autoPauseListenable) {
      oldWidget.autoPauseListenable?.removeListener(_onAutoPauseChanged);
      widget.autoPauseListenable?.addListener(_onAutoPauseChanged);
      _onAutoPauseChanged();
    }
  }

  bool get _autoCanRun =>
      controller.autoTurning &&
      !(widget.autoPauseListenable?.value ?? false) &&
      !_menuResumePending;

  void _onAutoPauseChanged() {
    _menuResumeTimer?.cancel();
    if (widget.autoPauseListenable?.value ?? false) {
      _menuResumePending = false;
      _sync();
      return;
    }
    if (controller.autoTurning) {
      // Let panel dismissal and any reading-layout changes settle first.
      _menuResumePending = true;
      _menuResumeTimer = Timer(const Duration(milliseconds: 350), () {
        if (!mounted || (widget.autoPauseListenable?.value ?? false)) return;
        _menuResumePending = false;
        _sync();
      });
    } else {
      _menuResumePending = false;
      _sync();
    }
  }

  void _sync() {
    final wasAutoTicking = _ticker.isActive;
    if (_autoCanRun) {
      if (!_ticker.isActive) {
        _ticker.start();
        _prefetchAutoLookahead();
      }
      if (_moving && _activeAutoInterval != controller.autoTurnInterval) {
        // Programmatic speed changes should take effect before the current
        // long segment finishes. The settings sheet normally pauses first.
        _autoMotionGeneration++;
        _moving = false;
        if (_scroll.isAttached) {
          _scrollOffset.animateScroll(
            offset: 0,
            duration: const Duration(milliseconds: 1),
          );
        }
      }
    } else {
      _ticker.stop();
      if (_moving && _scroll.isAttached) {
        // Replacing the activity stops the current one-second segment now.
        _autoMotionGeneration++;
        _moving = false;
        _scrollOffset.animateScroll(
          offset: 0,
          duration: const Duration(milliseconds: 1),
        );
      }
      if (wasAutoTicking && _scrolling && !_pointerDown) {
        _scheduleIdle(_scrollGeneration);
      }
    }
    if (_updating) return;
    if (_contentChanges().isNotEmpty) _entriesDirty = true;
    final bool flowChanged = !identical(_flow, controller.flowChapters);
    // A load can notify between a scroll sample and its post-frame write.
    // Compare with the last controller state we observed, not the pending
    // sample, or that load would cancel the user's fling with a jumpTo.
    final bool positionChanged =
        controller.chapterIndex != _controllerChapter ||
            controller.charOffset != _controllerOffset;
    if (flowChanged || positionChanged) {
      _flow = controller.flowChapters;
      _chapter = controller.chapterIndex;
      _offset = controller.charOffset;
      _controllerChapter = _chapter;
      _controllerOffset = _offset;
      _publishedChapter = _chapter;
      _publishedOffset = _offset;
      _positionDirty = false;
      _requestRestore();
    } else if (_restoring && controller.isLoaded(_chapter)) {
      _requestRestore();
    }
  }

  void _requestRestore() {
    if (_pointerDown || _scrolling) {
      _pendingRestore = true;
      return;
    }
    if (!mounted || _queued) return;
    _pendingRestore = false;
    final generation = ++_restoreGeneration;
    _restoring = true;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _restoreGeneration) return;
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
        if (generation != _restoreGeneration) return;
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
          if (mounted && generation == _restoreGeneration) {
            _restoring = false;
          }
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _onConfigChanged() {
    _chapterEntries.clear();
    _entriesDirty = true;
    _paragraphPages.clear();
    _requestRestore();
  }

  ReaderPage _pageFor(_Entry entry) {
    final key = (entry.chapter, entry.offset);
    final previous = _paragraphPages[key];
    final block = entry.block!;
    // ReaderProse clears its selection on a new page identity. Ordinary list
    // rebuilds (including overlay insertion) must retain the same paragraph.
    if (previous != null &&
        previous.single.text == block.text &&
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

  void _positionsChanged() => _samplePosition();

  void _samplePosition({bool force = false}) {
    if (_restoring || !mounted) return;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    // Reading-position bookkeeping need not run at the display refresh rate.
    // Keep fling frames free of repeated text hit tests and render-tree walks.
    final sampleInterval = controller.autoTurning
        ? const Duration(milliseconds: 200)
        : const Duration(milliseconds: 64);
    if (!force &&
        _scrolling &&
        _lastAnchorSample != null &&
        now - _lastAnchorSample! < sampleInterval) {
      return;
    }
    _lastAnchorSample = now;
    ItemPosition? first;
    ItemPosition? last;
    for (final position in _positions.itemPositions.value) {
      if (position.itemTrailingEdge <= 0 || position.itemLeadingEdge >= 1) {
        continue;
      }
      if (first == null || position.index < first.index) first = position;
      if (last == null || position.index > last.index) last = position;
    }
    if (first == null) return;
    final item = first;
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
    _positionDirty =
        _chapter != _publishedChapter || _offset != _publishedOffset;
    if (_anchorUpdateQueued) return;
    _anchorUpdateQueued = true;
    final generation = _scrollGeneration;
    // Do not mutate the controller during layout. Coalesce position callbacks
    // to at most one per frame while a fast fling is producing many updates.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorUpdateQueued = false;
      if (!mounted || _restoring || generation != _scrollGeneration) return;
      _updating = true;
      final bool chapterChanged = controller.chapterIndex != _chapter;
      controller.chapterIndex = _chapter;
      controller.charOffset = _offset;
      _controllerChapter = _chapter;
      _controllerOffset = _offset;
      if (chapterChanged) {
        controller.signature = '';
        controller.flowChapters = _flow = [
          if (_chapter > 0) _chapter - 1,
          _chapter,
          if (_chapter + 1 < controller.chapterCount) _chapter + 1,
        ];
        controller.prefetchAround(_chapter);
        if (controller.autoTurning) _prefetchAutoLookahead();
        _publishPosition();
      }
      _updating = false;
      if (controller.autoTurning &&
          last!.index == _entries.length - 1 &&
          last.itemTrailingEdge <= 1) {
        controller.setAutoTurning(false);
      }
    });
  }

  void _publishPosition() {
    if (!_positionDirty || !mounted) return;
    _publishedChapter = _chapter;
    _publishedOffset = _offset;
    _positionDirty = false;
    controller.notifyListeners();
  }

  void _prefetchAutoLookahead() {
    final chapter = _chapter + 2;
    if (chapter < controller.chapterCount &&
        !controller.chapterLocked(chapter)) {
      controller.ensureLoaded(chapter);
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification && !_restoring) {
      _idleTimer?.cancel();
      _scrollGeneration++;
      _scrolling = true;
    }
    if (notification is ScrollUpdateNotification &&
        (!_autoCanRun || _autoPausedForGesture) &&
        !_pointerDown &&
        _scrolling) {
      // Ballistic frames keep extending the quiet period. A fresh touch can
      // absorb the old activity's end notification, so do not rely on that
      // notification alone to flush deferred chapter changes.
      _scheduleIdle(_scrollGeneration);
    }
    if (notification is ScrollEndNotification) {
      // An auto-read segment ending is just a seam in the continuous motion,
      // not a reading stop. Avoid a forced text hit-test and overlay rebuild
      // at every seam.
      if (_autoCanRun && !_autoPausedForGesture) return false;
      final generation = _scrollGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            _restoring ||
            _pointerDown ||
            generation != _scrollGeneration) {
          return;
        }
        // Force a final exact sample after the list publishes its last layout;
        // the persisted position must not be the throttled in-flight sample.
        _samplePosition(force: true);
        _updating = true;
        controller.chapterIndex = _chapter;
        controller.charOffset = _offset;
        _controllerChapter = _chapter;
        _controllerOffset = _offset;
        _publishPosition();
        _updating = false;
        // Reversing a fling can generate an end notification followed by a
        // fresh start. Give the new gesture time to arrive before modifying
        // item indices or applying an anchor correction.
        _scheduleIdle(generation);
      });
    }
    return false;
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerDown = true;
    _autoPausedForGesture = true;
    _scrollGeneration++;
    _idleTimer?.cancel();
    // A scheduled programmatic correction must not land after a new finger
    // touches the page. The current visible paragraph becomes the new anchor.
    _restoreGeneration++;
    _queued = false;
    _restoring = false;
  }

  void _onPointerEnd(PointerEvent event) {
    _pointerDown = false;
    if (_scrolling) {
      _scheduleIdle(_scrollGeneration);
    } else {
      _autoPausedForGesture = false;
    }
  }

  void _scheduleIdle(int generation) {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || _pointerDown || generation != _scrollGeneration) {
        return;
      }
      _scrolling = false;
      _autoPausedForGesture = false;
      if (_entriesDirty) setState(() {});
      if (_pendingRestore) _requestRestore();
    });
  }

  void _tick(Duration elapsed) {
    if (!_scroll.isAttached ||
        _restoring ||
        _moving ||
        _autoPausedForGesture ||
        _pointerDown) {
      return;
    }
    // The UI's fastest setting is one screen per 15 seconds. Match the
    // animation horizon to that interval so a seam is not visible every
    // three seconds; cap the horizon to avoid aiming through many unloaded
    // chapters at programmatic speeds. Touch and stop still cancel at once.
    final interval = controller.autoTurnInterval;
    final step = interval < const Duration(seconds: 3)
        ? const Duration(seconds: 3)
        : interval > const Duration(seconds: 15)
            ? const Duration(seconds: 15)
            : interval;
    _activeAutoInterval = controller.autoTurnInterval;
    final generation = ++_autoMotionGeneration;
    _moving = true;
    _scrollOffset
        .animateScroll(
      offset: _height *
          step.inMilliseconds /
          controller.autoTurnInterval.inMilliseconds,
      duration: step,
      curve: Curves.linear,
    )
        .whenComplete(() {
      if (generation == _autoMotionGeneration) _moving = false;
    });
  }

  List<_Entry> _makeEntries() {
    final result = <_Entry>[];
    for (var chapter = 0; chapter < controller.chapterCount; chapter++) {
      result.add(_Entry(chapter, 0, heading: true));
      final body = controller.bodyOf(chapter);
      _entryBodies[chapter] = body;
      _entryErrors[chapter] = controller.hasError(chapter);
      if (body == null) {
        result.add(_Entry(chapter, 0));
        continue;
      }
      var cached = _chapterEntries[chapter];
      if (cached == null || !identical(cached.$1, body)) {
        var offset = 0;
        final blocks = <_Entry>[];
        for (final block in controller.chapterBlocks(body)) {
          blocks.add(_Entry(chapter, offset, block: block));
          offset += block.length;
        }
        cached = (body, blocks);
        _chapterEntries[chapter] = cached;
      }
      result.addAll(cached.$2);
    }
    _chapterEntries.removeWhere((chapter, _) => !controller.isLoaded(chapter));
    final active = {
      for (final entry in result)
        if (entry.block != null) (entry.chapter, entry.offset),
    };
    _paragraphKeys.removeWhere((key, _) => !active.contains(key));
    _paragraphPages.removeWhere((key, _) => !active.contains(key));
    return result;
  }

  List<int> _contentChanges() => [
        for (var chapter = 0; chapter < controller.chapterCount; chapter++)
          if (!identical(_entryBodies[chapter], controller.bodyOf(chapter)) ||
              (_entryErrors[chapter] ?? false) != controller.hasError(chapter))
            chapter,
      ];

  bool _canApplyContentAhead() {
    if (!controller.autoTurning || !_scrolling || _entries.isEmpty) {
      return false;
    }
    final changes = _contentChanges();
    if (changes.isEmpty) return false;
    var lastVisibleChapter = _chapter;
    for (final position in _positions.itemPositions.value) {
      if (position.itemTrailingEdge > 0 &&
          position.itemLeadingEdge < 1 &&
          position.index < _entries.length) {
        final chapter = _entries[position.index].chapter;
        if (chapter > lastVisibleChapter) lastVisibleChapter = chapter;
      }
    }
    return changes.every((chapter) => chapter > lastVisibleChapter);
  }

  @override
  Widget build(BuildContext context) {
    // Keep item indices and extents stable throughout a drag and its fling.
    // Loading/evicting an earlier chapter must not move the visible paragraph.
    if (_entriesDirty &&
        ((!_scrolling && !_pointerDown) ||
            _entries.isEmpty ||
            _canApplyContentAhead())) {
      ItemPosition? anchor;
      for (final position in _positions.itemPositions.value) {
        if (position.itemTrailingEdge > 0 &&
            position.itemLeadingEdge < 1 &&
            position.index < _entries.length &&
            (anchor == null || position.index < anchor.index)) {
          anchor = position;
        }
      }
      final oldEntry = anchor == null ? null : _entries[anchor.index];
      _entries = _makeEntries();
      _entriesDirty = false;
      if (!_restoring && oldEntry != null) {
        final index = _entries.indexWhere((entry) =>
            entry.chapter == oldEntry.chapter &&
            entry.offset == oldEntry.offset &&
            entry.heading == oldEntry.heading);
        if (index >= 0 && index != anchor!.index) {
          final alignment = anchor.itemLeadingEdge;
          final generation = _scrollGeneration;
          _restoring = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                !_scroll.isAttached ||
                _pointerDown ||
                _scrolling ||
                generation != _scrollGeneration) {
              _restoring = false;
              return;
            }
            _scroll.jumpTo(index: index, alignment: alignment);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && generation == _scrollGeneration) {
                _restoring = false;
              }
            });
          });
        }
      }
    }
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
                return NotificationListener<ScrollNotification>(
                  onNotification: _onScrollNotification,
                  child: Listener(
                    onPointerDown: _onPointerDown,
                    onPointerUp: _onPointerEnd,
                    onPointerCancel: _onPointerEnd,
                    child: ScrollablePositionedList.builder(
                      itemScrollController: _scroll,
                      scrollOffsetController: _scrollOffset,
                      itemPositionsListener: _positions,
                      itemCount: _entries.length,
                      padding:
                          EdgeInsets.symmetric(horizontal: pagePadding.left),
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        if (entry.heading) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 12, bottom: 16),
                            child: Align(
                              alignment: Alignment.center,
                              child: Text(
                                controller.chapterTitleAt(entry.chapter),
                                textAlign: TextAlign.center,
                                style: config.headingStyle,
                              ),
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
                          padding:
                              EdgeInsets.only(bottom: config.paragraphSpacing),
                          child: ReaderProse(
                            selectionGroup: _selectionGroup,
                            page: _pageFor(entry),
                            config: config,
                            chapterIndex: entry.chapter,
                            chapterTitle:
                                controller.chapterTitleAt(entry.chapter),
                            pageStartOffset: entry.offset,
                            headingOffsets: _headingOffsets.putIfAbsent(
                              entry.chapter,
                              () => controller
                                  .subsectionOffsetsFor(entry.chapter),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
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
    _idleTimer?.cancel();
    _menuResumeTimer?.cancel();
    _ticker.dispose();
    controller.removeListener(_sync);
    config.removeListener(_onConfigChanged);
    widget.autoPauseListenable?.removeListener(_onAutoPauseChanged);
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

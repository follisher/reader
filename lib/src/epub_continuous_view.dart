import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_readium/flutter_readium.dart' as rd;
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;

import 'epub_continuous_document.dart';
import 'epub_heading.dart';
import 'models.dart';

class EpubContinuousView extends StatefulWidget {
  const EpubContinuousView({
    super.key,
    required this.content,
    required this.publication,
    required this.config,
    required this.onPosition,
    required this.onSelection,
    required this.onTap,
    required this.onError,
    this.initialLocator,
    this.decorations = const [],
    this.onDecorationTap,
    this.onSelectionCleared,
    this.onSelectionGeometryChanged,
    this.onEnd,
    this.autoReading = false,
    this.autoPaused = false,
    this.autoInterval = const Duration(milliseconds: 32500),
  });
  final Future<BookContent> content;
  final rd.Publication publication;
  final engine.ReaderConfig config;
  final rd.Locator? initialLocator;
  final ValueChanged<rd.Locator> onPosition;
  final ValueChanged<rd.TextSelectionEvent> onSelection;
  final VoidCallback onTap;
  final VoidCallback? onSelectionCleared;
  final VoidCallback? onSelectionGeometryChanged;
  final ValueChanged<Object> onError;
  final List<rd.ReaderDecoration> decorations;
  final ValueChanged<List<rd.ReaderDecoration>>? onDecorationTap;
  final VoidCallback? onEnd;
  final bool autoReading, autoPaused;
  final Duration autoInterval;

  @override
  State<EpubContinuousView> createState() => EpubContinuousViewState();
}

class _Block {
  const _Block(this.chapter, this.block);
  final int chapter, block;
  String get id => '$chapter:$block';
}

class _BlockKey extends GlobalKey {
  const _BlockKey(this.id) : super.constructor();
  final String id;
}

class _ImageData {
  const _ImageData(this.bytes, this.ratio);
  final Uint8List bytes;
  final double ratio;
}

class EpubContinuousViewState extends State<EpubContinuousView>
    with SingleTickerProviderStateMixin {
  static const _center = ValueKey('continuous-epub-center');
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _selection = GlobalKey<SelectionAreaState>();
  final _selectionFocus = FocusNode();
  bool _hasSelection = false;
  bool _clearingSelection = false;
  final _keys = <String, GlobalKey>{};
  final _selectionNotifiers = <String, SelectionListenerNotifier>{};
  final _imageBytes = <String, _ImageData>{};
  final _imageRatios = <String, double>{};
  final _imageLoads = <String, Future<_ImageData?>>{};
  final _preparing = <int, Future<void>>{};
  final _prepared = <int>{};
  late final _autoTicker = createTicker(_autoTick);
  Duration? _lastAutoTick;
  Timer? _gestureResume;
  bool _pointerDown = false, _gesturePaused = false;
  bool _autoEnded = false;
  EpubContinuousDocument? _document;
  List<_Block> _before = [], _after = [];
  final _beforeIndices = <String, int>{}, _afterIndices = <String, int>{};
  int _baseChapter = 0, _baseBlock = 0, _first = 0, _last = 0;
  int _generation = 0;
  int _cachedBytes = 0;
  bool _loading = true, _positionScheduled = false, _restoring = false;
  Object? _error;
  rd.Locator? _visible;
  _Block? _selectedBlock;
  late String _layout;
  String get _layoutSignature =>
      '${widget.config.fontSize}:${widget.config.lineHeight}:${widget.config.paragraphSpacing}:${widget.config.fontFamily}';

  @override
  void initState() {
    super.initState();
    _layout = _layoutSignature;
    _scroll.addListener(_schedulePosition);
    _syncAuto();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final content = await widget.content;
      if (!mounted) return;
      _document = EpubContinuousDocument(content, widget.publication);
      await goTo(widget.initialLocator);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
      widget.onError(error);
    }
  }

  Future<void> _prepare(
    int chapter,
  ) => _preparing.putIfAbsent(chapter, () async {
    try {
      final body = await _document!.load(chapter);
      final resources = <String>{};
      for (final block in body.blocks) {
        for (final image in html.parseFragment(block).querySelectorAll('img')) {
          final path = image.attributes['data-reader-resource'];
          if (path != null) resources.add(path);
        }
      }
      // Resolve image geometry before adding the chapter to the scroll layout.
      // Reloaded bytes use the same aspect ratio, so cache eviction cannot move text.
      final paths = resources.toList();
      for (var i = 0; i < paths.length; i += 4) {
        await Future.wait(paths.skip(i).take(4).map(_image));
      }
      _prepared.add(chapter);
    } finally {
      _preparing.remove(chapter);
    }
  });

  Future<_ImageData?> _image(String path) {
    final cached = _imageBytes.remove(path);
    if (cached != null) {
      _imageBytes[path] = cached;
      return Future.value(cached);
    }
    return _imageLoads.putIfAbsent(path, () async {
      try {
        final bytes = await _document!.content.resource(path);
        if (bytes == null || bytes.isEmpty) return null;
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        final ratio = descriptor.width / descriptor.height;
        descriptor.dispose();
        buffer.dispose();
        final data = _ImageData(bytes, ratio);
        _imageRatios[path] = ratio;
        _imageBytes[path] = data;
        _cachedBytes += bytes.length;
        while (_imageBytes.length > 48 || _cachedBytes > 32 * 1024 * 1024) {
          _cachedBytes -= _imageBytes
              .remove(_imageBytes.keys.first)!
              .bytes
              .length;
        }
        return data;
      } catch (_) {
        return null;
      } finally {
        _imageLoads.remove(path);
      }
    });
  }

  Future<void> goTo(rd.Locator? locator) async {
    final document = _document;
    if (document == null || widget.publication.readingOrder.isEmpty) return;
    final generation = ++_generation;
    _autoEnded = false;
    final chapter = document.chapterFor(locator);
    _restoring = true;
    clearSelection();
    try {
      await _prepare(chapter);
    } catch (_) {
      _restoring = false;
      rethrow;
    }
    if (!mounted || generation != _generation) return;
    final savedBlock = locator?.locations?.additionalProperties['readerBlock'];
    final block = savedBlock is int && savedBlock >= 0
        ? document.blockFor(chapter, locator)
        : locator?.locations?.additionalProperties['readerBlock'] == -1 ||
              (locator?.text?.highlight == null &&
                  locator?.locations?.cssSelector == null &&
                  locator?.locations?.fragments.isNotEmpty != true &&
                  (locator?.locations?.progression ?? 0) == 0)
        ? -1
        : document.blockFor(chapter, locator);
    setState(() {
      _baseChapter = chapter;
      _baseBlock = block;
      _first = _last = chapter;
      _loading = false;
      _error = null;
      _rebuildBlocks();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !_scroll.hasClients) return;
      final alignment =
          (locator?.locations?.additionalProperties['readerAlignment'] as num?)
              ?.toDouble() ??
          0;
      final key = _keys['$chapter:$block'];
      final height = key?.currentContext?.size?.height ?? 0;
      _scroll.jumpTo(
        (alignment * height).clamp(
          _scroll.position.minScrollExtent,
          _scroll.position.maxScrollExtent,
        ),
      );
      _restoring = false;
      _schedulePosition();
      _syncAuto();
    });
    unawaited(_extend(chapter - 1, generation));
    unawaited(_extend(chapter + 1, generation));
    unawaited(_extend(chapter + 2, generation));
  }

  Future<void> _extend(int chapter, int generation) async {
    if (chapter < 0 ||
        chapter >= widget.publication.readingOrder.length ||
        chapter >= _first && chapter <= _last) {
      return;
    }
    try {
      await _prepare(chapter);
      if (!mounted || generation != _generation) return;
      // Add only contiguous resources, even if prefetches finish out of order.
      setState(() {
        while (_prepared.contains(_first - 1)) {
          _first--;
          for (final item in _chapterBlocks(_first).reversed) {
            _beforeIndices[item.id] = _before.length;
            _before.add(item);
          }
        }
        while (_prepared.contains(_last + 1)) {
          _last++;
          for (final item in _chapterBlocks(_last)) {
            _afterIndices[item.id] = _after.length;
            _after.add(item);
          }
        }
      });
      _schedulePosition();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
        widget.onError(error);
      }
    }
  }

  List<_Block> _chapterBlocks(int chapter) => [
    for (
      var block = -1;
      block < _document!.chapters[chapter]!.blocks.length;
      block++
    )
      _Block(chapter, block),
  ];

  void _rebuildBlocks() {
    final preceding = <_Block>[], following = <_Block>[];
    for (var chapter = _first; chapter <= _last; chapter++) {
      final body = _document!.chapters[chapter]!;
      for (var block = -1; block < body.blocks.length; block++) {
        final item = _Block(chapter, block);
        if (chapter < _baseChapter ||
            chapter == _baseChapter && block < _baseBlock) {
          preceding.add(item);
        } else {
          following.add(item);
        }
      }
    }
    _before = preceding.reversed.toList();
    _after = following;
    _beforeIndices.clear();
    _afterIndices.clear();
    for (var i = 0; i < _before.length; i++) {
      _beforeIndices[_before[i].id] = i;
    }
    for (var i = 0; i < _after.length; i++) {
      _afterIndices[_after[i].id] = i;
    }
  }

  void _schedulePosition() {
    if (_positionScheduled || _loading || _restoring) return;
    _positionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _positionScheduled = false;
      if (mounted && !_restoring) _reportPosition();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _reportPosition() {
    final viewport = _viewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    final bottom = top + viewport.size.height;
    _Block? first, last;
    var firstY = double.infinity, lastY = -double.infinity;
    double alignment = 0;
    for (final entry in _keys.entries.toList()) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box == null) {
        _keys.remove(entry.key);
        final notifier = _selectionNotifiers[entry.key];
        if (notifier != null && !notifier.registered) {
          _selectionNotifiers.remove(entry.key)?.dispose();
        }
        continue;
      }
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y >= bottom || y + box.size.height <= top || box.size.height == 0) {
        continue;
      }
      final address = entry.key.split(':').map(int.parse).toList();
      final block = _Block(address[0], address[1]);
      if (y < firstY) {
        firstY = y;
        first = block;
        alignment = ((top - y) / box.size.height).clamp(0, 1);
      }
      if (y > lastY) {
        lastY = y;
        last = block;
      }
    }
    if (first == null || last == null) return;
    final locator = _document!.locator(
      first.chapter,
      first.block,
      alignment: alignment,
    );
    if (_visible != locator) {
      _visible = locator;
      widget.onPosition(locator);
    }
    final generation = _generation;
    // Keep two resources ahead of the visible text, independently of chapter length.
    unawaited(_extend(first.chapter - 1, generation));
    unawaited(_extend(last.chapter + 1, generation));
    unawaited(_extend(last.chapter + 2, generation));
  }

  Future<void> next() async {
    if (!_scroll.hasClients) return;
    if (_last + 1 == widget.publication.readingOrder.length &&
        _scroll.offset >= _scroll.position.maxScrollExtent - 1) {
      widget.onEnd?.call();
      return;
    }
    await _scroll.animateTo(
      (_scroll.offset + _scroll.position.viewportDimension * .85).clamp(
        _scroll.position.minScrollExtent,
        _scroll.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeInOut,
    );
  }

  void _syncAuto() {
    final run =
        widget.autoReading &&
        !widget.autoPaused &&
        !_gesturePaused &&
        !_autoEnded;
    if (run && !_autoTicker.isActive) {
      _lastAutoTick = null;
      _autoTicker.start();
    } else if (!run && _autoTicker.isActive) {
      _autoTicker.stop();
      _lastAutoTick = null;
    }
  }

  void _autoTick(Duration elapsed) {
    final previous = _lastAutoTick;
    _lastAutoTick = elapsed;
    if (previous == null || !_scroll.hasClients || _loading || _restoring) {
      return;
    }
    final milliseconds = (elapsed - previous).inMicroseconds / 1000;
    final distance =
        _scroll.position.viewportDimension *
        milliseconds.clamp(0, 64) /
        widget.autoInterval.inMilliseconds.clamp(1, 1 << 30);
    final target = (_scroll.offset + distance).clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );
    if (target > _scroll.offset) {
      _scroll.jumpTo(target);
    } else if (_last + 1 == widget.publication.readingOrder.length) {
      _autoEnded = true;
      _syncAuto();
      widget.onEnd?.call();
    }
  }

  void _pauseForGesture() {
    _pointerDown = true;
    _gesturePaused = true;
    _gestureResume?.cancel();
    _syncAuto();
  }

  void _resumeAfterGesture() {
    _pointerDown = false;
    _gestureResume?.cancel();
    _gestureResume = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _pointerDown) return;
      if (_scroll.hasClients && _scroll.position.isScrollingNotifier.value) {
        _resumeAfterGesture();
        return;
      }
      _gesturePaused = false;
      _syncAuto();
    });
  }

  Future<void> retry() async {
    if (_document == null || _after.isEmpty) {
      await _open();
      return;
    }
    setState(() => _error = null);
    await Future.wait([
      _extend(_first - 1, _generation),
      _extend(_last + 1, _generation),
      _extend(_last + 2, _generation),
    ]);
    if (_error != null) throw _error!;
  }

  Rect? get selectionBounds {
    final region = _selection.currentState?.selectableRegion;
    if (!_hasSelection || region == null || region.selectionEndpoints.isEmpty) {
      return null;
    }
    final anchors = region.contextMenuAnchors;
    return Rect.fromPoints(
      anchors.primaryAnchor,
      anchors.secondaryAnchor ?? anchors.primaryAnchor,
    );
  }

  void clearSelection() {
    _clearingSelection = true;
    _selectedBlock = null;
    _hasSelection = false;
    final region = _selection.currentState?.selectableRegion;
    region?.hideToolbar();
    region?.clearSelection();
    _selectionFocus.unfocus();
    _clearingSelection = false;
    widget.onSelectionCleared?.call();
  }

  Map<String, dynamic> selectionResult(
    rd.Locator selection,
    List<rd.ReaderDecoration> underlines, {
    required bool merge,
  }) => _document!.selectionResult(selection, underlines, merge: merge);

  @override
  void didUpdateWidget(covariant EpubContinuousView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.autoReading && widget.autoReading) _autoEnded = false;
    _syncAuto();
    if (oldWidget.content != widget.content && _document == null) {
      _loading = true;
      unawaited(_open());
    }
    if (_layout == _layoutSignature) return;
    _layout = _layoutSignature;
    final locator = _visible;
    if (locator == null || _restoring) return;
    final chapter = _document!.chapterFor(locator);
    final block = locator.locations?.additionalProperties['readerBlock'];
    final key = _keys['$chapter:$block'];
    final box = key?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final oldY = box.localToGlobal(Offset.zero).dy;
    _restoring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final updated = key?.currentContext?.findRenderObject();
      if (updated is RenderBox && updated.hasSize) {
        final dy = updated.localToGlobal(Offset.zero).dy - oldY;
        _scroll.jumpTo(
          (_scroll.offset + dy).clamp(
            _scroll.position.minScrollExtent,
            _scroll.position.maxScrollExtent,
          ),
        );
      }
      _restoring = false;
      _schedulePosition();
    });
  }

  String _markedMarkup(String markup, List<rd.ReaderDecoration> marks) {
    if (marks.isEmpty) return markup;
    final document = html.parseFragment(markup);
    final text = document.text ?? '';
    final ranges = <(int, int, rd.ReaderDecoration)>[];
    for (final mark in marks) {
      final quote = mark.locator.text?.highlight;
      if (quote == null || quote.isEmpty) continue;
      var start = text.indexOf(quote);
      final before = mark.locator.text?.before ?? '';
      while (start >= 0 && !text.substring(0, start).endsWith(before)) {
        start = text.indexOf(quote, start + 1);
      }
      if (start >= 0) ranges.add((start, start + quote.length, mark));
    }
    var offset = 0;
    void visit(dom.Node node) {
      if (node is! dom.Text) {
        for (final child in node.nodes.toList()) {
          visit(child);
        }
        return;
      }
      final start = offset;
      final end = start + node.data.length;
      offset = end;
      final cuts = <int>{start, end};
      for (final range in ranges) {
        if (range.$1 < end && range.$2 > start) {
          cuts.add(range.$1.clamp(start, end));
          cuts.add(range.$2.clamp(start, end));
        }
      }
      final boundaries = cuts.toList()..sort();
      final replacement = dom.Element.tag('span');
      for (var i = 0; i + 1 < boundaries.length; i++) {
        final a = boundaries[i], b = boundaries[i + 1];
        final active = ranges
            .where((range) => range.$1 <= a && range.$2 >= b)
            .map((range) => range.$3)
            .toList();
        final piece = node.data.substring(a - start, b - start);
        if (active.isEmpty) {
          replacement.nodes.add(dom.Text(piece));
        } else {
          final styles = <String>[];
          for (final mark in active) {
            final color = mark.style.tint ?? widget.config.theme.underlineColor;
            final css =
                '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
            styles.add(
              mark.style.style == rd.DecorationStyle.underline
                  ? 'text-decoration:underline;text-decoration-color:$css'
                  : 'background-color:$css',
            );
          }
          final commentIds = active
              .where((mark) => mark.style.style == rd.DecorationStyle.highlight)
              .map((mark) => mark.id)
              .toSet()
              .toList();
          final span = dom.Element.tag(commentIds.isEmpty ? 'span' : 'a');
          if (commentIds.isNotEmpty) {
            span.attributes['href'] =
                'reader-comment:${Uri.encodeComponent(jsonEncode(commentIds))}';
            styles.add('color:inherit');
            if (!active.any(
              (mark) => mark.style.style == rd.DecorationStyle.underline,
            )) {
              styles.add('text-decoration:none');
            }
          }
          replacement.nodes.add(
            span
              ..attributes['style'] = styles.join(';')
              ..text = piece,
          );
        }
      }
      node.replaceWith(replacement);
    }

    visit(document);
    return document.outerHtml;
  }

  @override
  void dispose() {
    _generation++;
    _gestureResume?.cancel();
    _autoTicker.dispose();
    _scroll.dispose();
    _selectionFocus.dispose();
    for (final notifier in _selectionNotifiers.values) {
      notifier.dispose();
    }
    super.dispose();
  }

  // Render-only indentation keeps stored quotes and DOM ranges unchanged.
  String _indentedMarkup(String markup) {
    final fragment = html.parseFragment(markup);
    for (final paragraph in fragment.querySelectorAll('p')) {
      if (paragraph.text.trim().isEmpty || paragraph.text.startsWith('　　')) {
        continue;
      }
      paragraph.nodes.insert(0, dom.Element.tag('reader-indent'));
    }
    return fragment.outerHtml;
  }

  Widget _block(_Block item) {
    final chapter = _document!.chapters[item.chapter]!;
    final config = widget.config;
    final key = _keys.putIfAbsent(item.id, () => _BlockKey(item.id));
    if (item.block < 0) {
      if (!needsEpubChapterHeading(chapter)) return SizedBox.shrink(key: key);
      return Padding(
        key: key,
        padding: const EdgeInsets.only(top: 24, bottom: 16),
        child: Text(
          chapter.title,
          textAlign: TextAlign.center,
          style: config.textStyle.copyWith(
            fontSize: config.fontSize * 1.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    final markup = chapter.blocks[item.block];
    final href = widget.publication.readingOrder[item.chapter].href;
    final marks = <rd.ReaderDecoration>[];
    for (final mark in widget.decorations) {
      if (!EpubContinuousDocument.samePath(mark.locator.href, href)) continue;
      final parts = _document!.selectionParts(item.chapter, mark.locator);
      for (final part in parts.where((part) => part.$1 == item.block)) {
        marks.add(
          rd.ReaderDecoration(
            id: mark.id,
            locator: _document!.locatorForPart(item.chapter, part),
            style: mark.style,
          ),
        );
      }
    }
    return Listener(
      key: key,
      onPointerDown: (_) => _selectedBlock = item,
      child: Padding(
        padding: EdgeInsets.only(bottom: config.paragraphSpacing),
        child: SelectionListener(
          selectionNotifier: _selectionNotifiers.putIfAbsent(
            item.id,
            SelectionListenerNotifier.new,
          ),
          child: HtmlWidget(
            _indentedMarkup(_markedMarkup(markup, marks)),
            onTapUrl: (url) {
              if (!url.startsWith('reader-comment:')) return false;
              final ids =
                  (jsonDecode(
                            Uri.decodeComponent(
                              url.substring('reader-comment:'.length),
                            ),
                          )
                          as List)
                      .cast<String>()
                      .toSet();
              widget.onDecorationTap?.call(
                marks.where((mark) => ids.contains(mark.id)).toList(),
              );
              return true;
            },
            textStyle: config.textStyle,
            customStylesBuilder: (element) {
              if (element.localName == 'h2') {
                return {
                  'font-size': '${config.fontSize * 1.3}px',
                  'text-align': 'center',
                };
              }
              if (element.localName == 'h1') {
                return {
                  'font-size': '${config.fontSize * 1.5}px',
                  'text-align': 'center',
                };
              }
              if (const {
                'h1',
                'h3',
                'h4',
                'h5',
                'h6',
              }.contains(element.localName)) {
                return {'text-align': 'center'};
              }
              if (element.localName == 'p') {
                return {'margin': '0'};
              }
              return null;
            },
            customWidgetBuilder: (element) {
              if (element.localName == 'reader-indent') {
                return InlineCustomWidget(
                  alignment: PlaceholderAlignment.bottom,
                  child: SelectionContainer.disabled(
                    child: SizedBox(width: config.fontSize * 2),
                  ),
                );
              }
              if (element.localName != 'img') return null;
              final path = element.attributes['data-reader-resource'];
              if (path == null) return const SizedBox.shrink();
              final future = _image(path);
              return AspectRatio(
                aspectRatio: _imageRatios[path] ?? 1,
                child: FutureBuilder<_ImageData?>(
                  future: future,
                  builder: (_, snapshot) {
                    final data = _imageBytes[path] ?? snapshot.data;
                    return data == null
                        ? const SizedBox.shrink()
                        : Image.memory(
                            data.bytes,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _sliver(List<_Block> blocks, {Key? key}) => SliverPadding(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    sliver: SliverList(
      delegate: SliverChildBuilderDelegate(
        (_, index) => _block(blocks[index]),
        childCount: blocks.length,
        findChildIndexCallback: (key) {
          if (key is! _BlockKey) return null;
          return identical(blocks, _before)
              ? _beforeIndices[key.id]
              : _afterIndices[key.id];
        },
      ),
    ),
  );

  int? _sourceSelectionOffset(_Block item) {
    final offset = _selectionNotifiers[item.id]!.selection.range?.startOffset;
    if (offset == null) return null;
    final paragraph = html
        .parseFragment(_document!.chapters[item.chapter]!.blocks[item.block])
        .querySelector('p');
    final added =
        paragraph != null &&
            paragraph.text.trim().isNotEmpty &&
            !paragraph.text.startsWith('　　')
        ? 1
        : 0;
    return (offset - added).clamp(0, 1 << 30);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_document == null || _after.isEmpty) {
      return Center(child: Text('正文加载失败：$_error'));
    }
    return SafeArea(
      bottom: false,
      child: SelectionArea(
        key: _selection,
        focusNode: _selectionFocus,
        contextMenuBuilder: (_, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _hasSelection) {
              widget.onSelectionGeometryChanged?.call();
            }
          });
          return const SizedBox.shrink();
        },
        onSelectionChanged: (selection) {
          if (_clearingSelection) return;
          final raw = selection?.plainText;
          _hasSelection = raw != null && raw.isNotEmpty;
          if (!_hasSelection) {
            widget.onSelectionCleared?.call();
            return;
          }
          final item = _selectedBlock;
          if (item == null || item.block < 0) return;
          // Inline layout placeholders are never part of the source quote.
          final text = raw!.replaceAll('\uFFFC', '');
          if (text.trim().isEmpty) {
            clearSelection();
            return;
          }
          widget.onSelection(
            rd.TextSelectionEvent(
              locator: _document!.locator(
                item.chapter,
                item.block,
                selection: text,
                selectionOffset:
                    _selectionNotifiers[item.id]?.registered == true
                    ? _sourceSelectionOffset(item)
                    : null,
              ),
              selectedText: text,
            ),
          );
        },
        child: Listener(
          onPointerDown: (_) => _pauseForGesture(),
          onPointerUp: (_) => _resumeAfterGesture(),
          onPointerCancel: (_) => _resumeAfterGesture(),
          child: GestureDetector(
            onTap: () {
              if (_hasSelection) {
                clearSelection();
              } else {
                widget.onTap();
              }
            },
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                _schedulePosition();
                return false;
              },
              child: CustomScrollView(
                key: _viewport,
                controller: _scroll,
                center: _center,
                scrollCacheExtent: const ScrollCacheExtent.viewport(2),
                slivers: [
                  if (_first > 0)
                    const SliverToBoxAdapter(
                      child: SizedBox(
                        height: 80,
                        child: Center(child: Text('正在加载正文…')),
                      ),
                    ),
                  _sliver(_before),
                  _sliver(_after, key: _center),
                  if (_last + 1 < widget.publication.readingOrder.length)
                    const SliverToBoxAdapter(
                      child: SizedBox(
                        height: 80,
                        child: Center(child: Text('正在加载正文…')),
                      ),
                    ),
                  if (_last + 1 == widget.publication.readingOrder.length)
                    const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

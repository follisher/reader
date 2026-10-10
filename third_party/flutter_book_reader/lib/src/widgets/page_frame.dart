import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../battery.dart';
import '../comment/reader_comment_store.dart';
import '../paginator.dart';
import '../reader_config.dart';
import '../reader_labels.dart';
import '../reader_theme.dart';
import '../text_actions.dart';
import '../underline/reader_underline_store.dart';
import 'battery_indicator.dart';
import 'reader_selection_toolbar.dart';

/// 顶部小标题栏：章首显示书名、非章首显示章节标题；横向 / 纵向模式共用。
class ReaderHeaderBar extends StatelessWidget {
  const ReaderHeaderBar({super.key, required this.title, required this.theme});

  final String title;
  final ReaderTheme theme;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kReaderHeaderHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: theme.subTextColor),
        ),
      ),
    );
  }
}

/// 底部信息栏：章号 / 页码 / 进度。作为固定 chrome，不随翻页滑动。
class ReaderFooterBar extends StatelessWidget {
  const ReaderFooterBar({
    super.key,
    required this.theme,
    required this.chapterIndex,
    required this.chapterCount,
    required this.pageIndex,
    required this.pageCount,
    required this.progress,
  });

  final ReaderTheme theme;
  final int chapterIndex;
  final int chapterCount;
  final int pageIndex;
  final int pageCount;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final ReaderLabels labels = ReaderLabels.of(context);
    final TextStyle style = TextStyle(fontSize: 11, color: theme.subTextColor);
    return SizedBox(
      height: kReaderFooterHeight,
      child: Row(
        children: <Widget>[
          Text(labels.chapterProgress(chapterIndex, chapterCount),
              style: style),
          const Spacer(),
          if (pageCount > 0) Text('${pageIndex + 1}/$pageCount', style: style),
          const SizedBox(width: 12),
          Text('${(progress * 100).toStringAsFixed(1)}%', style: style),
          _battery(context),
        ],
      ),
    );
  }

  /// 右下角电量：由宿主经 [ReaderBatteryScope] 注入，未注入 / 值为 null 则不显示。
  Widget _battery(BuildContext context) {
    final ValueListenable<ReaderBatteryInfo?>? battery =
        ReaderBatteryScope.of(context);
    if (battery == null) return const SizedBox.shrink();
    return ValueListenableBuilder<ReaderBatteryInfo?>(
      valueListenable: battery,
      builder: (BuildContext context, ReaderBatteryInfo? info, _) {
        if (info == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 12),
          child: BatteryIndicator(info: info, color: theme.subTextColor),
        );
      },
    );
  }
}

/// 单页完整内容：顶部小标题 +（章首）大标题 + 正文 + 底部信息栏。
class ReaderPageContent extends StatelessWidget {
  const ReaderPageContent({
    super.key,
    required this.theme,
    required this.config,
    required this.bookTitle,
    required this.chapterTitle,
    required this.page,
    required this.isChapterHead,
    required this.chapterIndex,
    required this.chapterCount,
    required this.pageIndex,
    required this.pageCount,
    required this.progress,
    this.pageStartOffset = 0,
    this.leadingParagraphStart,
    this.headingOffsets = const <int>{},
    this.chapterEnd,
    this.padding = kReaderPagePadding,
  });

  final ReaderTheme theme;
  final ReaderConfig config;
  final String bookTitle;
  final String chapterTitle;
  final ReaderPage page;
  final bool isChapterHead;
  final int chapterIndex;
  final int chapterCount;
  final int pageIndex;
  final int pageCount;
  final double progress;

  /// 本页首字符在本章「块长度空间」中的起始偏移（划线锚定用）。
  final int pageStartOffset;

  /// 页首延续段落的真实起始偏移（段评角标跨页统计用），见 [ReaderProse.leadingParagraphStart]。
  final int? leadingParagraphStart;
  final Set<int> headingOffsets;

  /// 章末自定义组件（仅本章最后一页传入）：排在正文下方、页脚之上。
  /// 分页已为它预留高度，因此正文不会被它挤掉，见 `chapterEndReserve`。
  final Widget? chapterEnd;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ReaderHeaderBar(
            title: isChapterHead ? bookTitle : chapterTitle,
            theme: theme,
          ),
          if (isChapterHead) ...<Widget>[
            const SizedBox(height: kReaderHeadingGapTop),
            Align(
              alignment: Alignment.center,
              child: Text(
                chapterTitle,
                textAlign: TextAlign.center,
                style: config.headingStyle,
              ),
            ),
            const SizedBox(height: kReaderHeadingGapBottom),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 正文占据剩余空间；章末组件按自身高度紧随其后。
                Flexible(
                  child: ReaderProse(
                    page: page,
                    config: config,
                    bounded: true,
                    chapterIndex: chapterIndex,
                    chapterTitle: chapterTitle,
                    pageStartOffset: pageStartOffset,
                    leadingParagraphStart: leadingParagraphStart,
                    headingOffsets: headingOffsets,
                  ),
                ),
                if (chapterEnd != null) chapterEnd!,
              ],
            ),
          ),
          ReaderFooterBar(
            theme: theme,
            chapterIndex: chapterIndex,
            chapterCount: chapterCount,
            pageIndex: pageIndex,
            pageCount: pageCount,
            progress: progress,
          ),
        ],
      ),
    );
  }
}

/// 按文本块渲染一页正文；支持长按选中（见 [ReaderSelectionScope]）。
///
/// 选中规则：长按某段落 —— 若该段 ≤ 2 行，选中整段；若 ≥ 3 行，选中手指所在行
/// 及其上下各一行（共 3 行）。选中后在其上方弹出「复制 / 划线 / 查询 / 分享」工具条。
class ReaderProseSelectionGroup {
  final _members = <_ReaderProseState>{};
  _ReaderProseState? _owner;
  int _start = 0, _end = 0;

  List<_ReaderProseState> get _ordered => _members
      .where((state) => state.mounted && state.widget.chapterIndex == _owner?.widget.chapterIndex)
      .toList()..sort((a, b) => a.widget.pageStartOffset.compareTo(b.widget.pageStartOffset));

  void _select(_ReaderProseState owner, int start, int end) {
    _owner = owner;
    _start = start;
    _end = end;
    for (final state in _ordered) {
      state._mutateSelection(() {
        state._selIndentWidth = owner._selIndentWidth;
        state._startBlock = null;
        state._endBlock = null;
        for (var i = 0; i < state.widget.page.length; i++) {
          final lo = state._chapterToPlain(i, start);
          final hi = state._chapterToPlain(i, end);
          if (hi <= lo) continue;
          state._startBlock ??= i;
          if (state._startBlock == i) state._startOff = lo;
          state._endBlock = i;
          state._endOff = hi;
        }
      });
    }
    owner._selText = _ordered.map((state) => state._computeLocalSelText())
        .where((text) => text.isNotEmpty).join('\n');
    owner._toolbar?.markNeedsBuild();
  }

  void clear() {
    final states = _members.toList();
    _owner = null;
    for (final state in states) {
      if (state.mounted) state._clearLocalSelection();
    }
  }
}

class ReaderProse extends StatefulWidget {
  const ReaderProse({
    super.key,
    required this.page,
    required this.config,
    this.bounded = false,
    this.chapterIndex = 0,
    this.chapterTitle = '',
    this.pageStartOffset = 0,
    this.leadingParagraphStart,
    this.headingOffsets = const <int>{},
    this.selectionGroup,
  });

  final ReaderPage page;
  final ReaderProseSelectionGroup? selectionGroup;
  final ReaderConfig config;
  final bool bounded;

  /// 本页所属章节下标（划线锚定用）。
  final int chapterIndex;

  /// 本页所属章节标题（随选中回调传给业务方，便于据此构造 Comment 等）。
  final String chapterTitle;

  /// 本页首字符在本章「块长度空间」中的起始偏移（与书签同一套坐标）。
  final int pageStartOffset;

  /// 若本页以「上一页某段的延续块」开头，则为该段真实起始偏移；否则为 null（用本页起始）。
  /// 段评角标跨页时据此统计整段评论数，避免漏掉落在前一页那部分的评论。
  final int? leadingParagraphStart;
  final Set<int> headingOffsets;

  @override
  State<ReaderProse> createState() => _ReaderProseState();
}

class _ReaderProseState extends State<ReaderProse> {
  void _mutateSelection(VoidCallback action) => setState(action);
  static final RegExp _leadingIndent = RegExp(r'^[　\s]+');

  ReaderConfig get _config => widget.config;

  /// 选区端点：起点 / 终点各为「块下标 + 块内偏移」，可跨段落。
  /// 恒满足 (startBlock,startOff) ≤ (endBlock,endOff)；null 表示无选中。
  int? _startBlock;
  int _startOff = 0;
  int? _endBlock;
  int _endOff = 0;
  String _selText = '';

  /// 选中时缓存的缩进宽度（整页统一），供跨块纯文本换算。
  double _selIndentWidth = 0;

  /// 是否正在拖动手柄：拖动时隐藏气泡菜单，松手后再显示。
  bool _draggingHandle = false;

  /// 每个段落块的 key（用于取渲染盒做命中测试与工具条定位）。
  final Map<int, GlobalKey> _keys = <int, GlobalKey>{};

  OverlayEntry? _toolbar;
  bool _selectionAttached = true;

  /// 各块首字符在本章的起始偏移（前缀和，随页面变化重算一次）。
  /// 让 [_blockChapterStart] 由原来的 O(i) 变为 O(1)，消除单页 O(n²)。
  List<int> _blockStarts = const <int>[];

  /// 缩进占位宽度缓存：仅取决于缩进串 / 字体 / 字号 / 系统缩放，页内恒定。
  static final _indentWidths = <(String, TextStyle, TextScaler), double>{};

  @override
  void initState() {
    super.initState();
    _recomputeBlockStarts();
    widget.selectionGroup?._members.add(this);
  }

  /// 重算各块章内起始偏移前缀和，并使依赖页面的缓存失效。
  void _recomputeBlockStarts() {
    final int n = widget.page.length;
    final List<int> starts = List<int>.filled(n, widget.pageStartOffset);
    int sum = widget.pageStartOffset;
    for (int i = 0; i < n; i++) {
      starts[i] = sum;
      sum += widget.page[i].length;
    }
    _blockStarts = starts;
  }

  @override
  void didUpdateWidget(ReaderProse old) {
    super.didUpdateWidget(old);
    // 页面 / 排版变化：重算前缀和并让页级缓存失效。
    if (!identical(widget.page, old.page) ||
        widget.pageStartOffset != old.pageStartOffset ||
        widget.chapterIndex != old.chapterIndex ||
        widget.leadingParagraphStart != old.leadingParagraphStart) {
      _recomputeBlockStarts();
    }
    // 页内容 / 排版变化（翻页、改字号、旋转、缩放重排）时，原选区锚定的渲染盒已失效，
    // 立即清除选中态，避免浮层读取「待布局」的 RenderParagraph 触发断言 / 错位。
    if (!identical(widget.page, old.page) ||
        widget.pageStartOffset != old.pageStartOffset ||
        widget.chapterIndex != old.chapterIndex) {
      if (_hasSel || _toolbar != null) {
        _removeToolbar();
        _draggingHandle = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _clearSelection();
        });
      }
    }
  }

  @override
  void activate() {
    super.activate();
    _selectionAttached = true;
  }

  @override
  void deactivate() {
    _selectionAttached = false;
    _removeToolbar();
    _startBlock = null;
    _endBlock = null;
    _selText = '';
    super.deactivate();
  }

  @override
  void dispose() {
    final group = widget.selectionGroup;
    group?._members.remove(this);
    if (group?._owner == this) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (group?._owner == this) group?.clear();
      });
    }
    _removeToolbar();
    super.dispose();
  }

  void _removeToolbar() {
    final toolbar = _toolbar;
    _toolbar = null;
    toolbar?.remove();
    toolbar?.dispose();
  }

  void _clearSelection() {
    final group = widget.selectionGroup;
    if (group?._owner != null) {
      group!.clear();
    } else {
      _clearLocalSelection();
    }
  }

  void _clearLocalSelection() {
    _removeToolbar();
    _draggingHandle = false;
    if (mounted) {
      setState(() {
        _startBlock = null;
        _endBlock = null;
        _selText = '';
      });
    }
  }

  /// 结束手柄拖动：恢复气泡菜单显示。
  void _endHandleDrag() {
    if (!_draggingHandle) return;
    _draggingHandle = false;
    _toolbar?.markNeedsBuild();
  }

  bool get _hasLocalSel => _startBlock != null && _endBlock != null;
  bool get _hasSel => _hasLocalSel || widget.selectionGroup?._owner == this;

  /// 块 i 内可选起点（段首块跳过缩进占位符 offset 0）。
  int _minBase(int i) => widget.page[i].isParagraphStart ? 1 : 0;

  /// 块 i 的选区在其内部的 [lo, hi)（不在选区内返回 null）。
  TextSelection? _localSel(int i) {
    if (!_hasLocalSel || i < _startBlock! || i > _endBlock!) return null;
    final String plain = _plainForSpan(widget.page[i], _selIndentWidth);
    final int lo = i == _startBlock! ? _startOff : _minBase(i);
    final int hi = i == _endBlock! ? _endOff : plain.length;
    if (hi <= lo) return null;
    return TextSelection(baseOffset: lo, extentOffset: hi);
  }

  /// 汇总跨块选中文字（段落间以换行分隔、剔除缩进占位符）。
  String _computeSelText() {
    final group = widget.selectionGroup;
    if (group?._owner == this) {
      return group!._ordered.map((state) => state._computeLocalSelText())
          .where((text) => text.isNotEmpty).join('\n');
    }
    return _computeLocalSelText();
  }

  String _computeLocalSelText() {
    if (!_hasLocalSel) return '';
    final StringBuffer sb = StringBuffer();
    for (int i = _startBlock!; i <= _endBlock!; i++) {
      final TextSelection? ls = _localSel(i);
      if (ls == null) continue;
      final String plain = _plainForSpan(widget.page[i], _selIndentWidth);
      final String part = plain.substring(ls.start, ls.end).replaceAll('￼', '');
      if (sb.isNotEmpty && widget.page[i].isParagraphStart) sb.write('\n');
      sb.write(part);
    }
    return sb.toString().trim();
  }

  /// 块 i 实际渲染的段落 RenderObject。用它（而非另建 [TextPainter]）做选区盒 /
  /// 光标 / 命中测算，保证与屏幕上真实排版（含 Web 字体回退、locale 影响）完全一致。
  RenderParagraph? _para(int i) {
    final RenderObject? ro = _keys[i]?.currentContext?.findRenderObject();
    return (ro is RenderParagraph && ro.hasSize) ? ro : null;
  }

  // ——————————— 章内偏移映射（划线用；与书签同一套「块长度空间」）———————————

  int get _indentLen => _config.indent.length;

  /// 块 i 首字符在本章的起始偏移（前缀和查表，O(1)）。
  int _blockChapterStart(int i) => (i >= 0 && i < _blockStarts.length)
      ? _blockStarts[i]
      : widget.pageStartOffset;

  /// 块 i 内「占位符空间」偏移 → 本章偏移。
  int _plainToChapter(int i, int plainOffset) {
    final ReaderBlock b = widget.page[i];
    final int bc = _blockChapterStart(i);
    if (b.isParagraphStart) {
      if (plainOffset <= 0) return bc;
      return bc + _indentLen + (plainOffset - 1);
    }
    return bc + plainOffset;
  }

  /// 本章偏移 → 块 i 内「占位符空间」偏移（clamp 到本块可视范围）。
  int _chapterToPlain(int i, int chapterOffset) {
    final ReaderBlock b = widget.page[i];
    final int bc = _blockChapterStart(i);
    final int t = chapterOffset - bc; // 块 text 空间偏移
    if (b.isParagraphStart) {
      final int bodyLen = b.length - _indentLen;
      final int plainLen = 1 + (bodyLen < 0 ? 0 : bodyLen);
      return (t - _indentLen + 1).clamp(1, plainLen);
    }
    return t.clamp(0, b.length);
  }

  /// 块 i 内跟读高亮（听书当前句）对应的占位符空间区间；无则 null。
  TextSelection? _readingSelFor(int i) {
    final ReaderReadingScope? scope = ReaderReadingScope.of(context);
    if (scope == null ||
        scope.chapterIndex != widget.chapterIndex ||
        scope.start < 0 ||
        scope.end <= scope.start) {
      return null;
    }
    final int bc = _blockChapterStart(i);
    final int be = bc + widget.page[i].length;
    final int s = scope.start.clamp(bc, be);
    final int e = scope.end.clamp(bc, be);
    if (e <= s) return null;
    final int ps = _chapterToPlain(i, s);
    final int pe = _chapterToPlain(i, e);
    if (pe <= ps) return null;
    return TextSelection(baseOffset: ps, extentOffset: pe);
  }

  /// 当前选区对应的本章 [start, end)；无选中返回 null。
  (int, int)? _selChapterRange() {
    final group = widget.selectionGroup;
    if (group?._owner == this) return (group!._start, group._end);
    if (!_hasSel) return null;
    final int s = _plainToChapter(_startBlock!, _startOff);
    final int e = _plainToChapter(_endBlock!, _endOff);
    return e > s ? (s, e) : null;
  }

  /// 与当前选区在本章相交的已有划线。
  List<Underline> _overlappingUnderlines() {
    final ReaderUnderlineScope? scope = ReaderUnderlineScope.of(context);
    final (int, int)? range = _selChapterRange();
    if (scope == null || range == null) return const <Underline>[];
    return scope.underlines
        .where((Underline u) =>
            u.overlaps(widget.chapterIndex, range.$1, range.$2))
        .toList();
  }

  /// 块 i 内需要绘制的划线区间（占位符空间），由本章划线与本块范围求交得到。
  /// [chapterUnderlines] 已在调用侧按本章预筛一次，避免逐块重复过滤全量划线。
  List<TextSelection> _underlineRangesFor(
      int i, List<Underline> chapterUnderlines) {
    if (chapterUnderlines.isEmpty) {
      return const <TextSelection>[];
    }
    final int bc = _blockChapterStart(i);
    final int be = bc + widget.page[i].length;
    final List<TextSelection> res = <TextSelection>[];
    for (final Underline u in chapterUnderlines) {
      final int s = u.start.clamp(bc, be);
      final int e = u.end.clamp(bc, be);
      if (e <= s) continue;
      final int ps = _chapterToPlain(i, s);
      final int pe = _chapterToPlain(i, e);
      if (pe > ps) res.add(TextSelection(baseOffset: ps, extentOffset: pe));
    }
    if (res.length < 2) return res;
    // 合并重叠 / 相邻区间，避免多条划线在同一处叠画导致波浪线变粗。
    res.sort((TextSelection a, TextSelection b) => a.start.compareTo(b.start));
    final List<TextSelection> merged = <TextSelection>[res.first];
    for (int k = 1; k < res.length; k++) {
      final TextSelection cur = res[k];
      final TextSelection last = merged.last;
      if (cur.start <= last.end) {
        merged[merged.length - 1] = TextSelection(
          baseOffset: last.start,
          extentOffset: cur.end > last.end ? cur.end : last.end,
        );
      } else {
        merged.add(cur);
      }
    }
    return merged;
  }

  /// 块 i 内评论引用原文的高亮区间。重叠评论先合并，避免背景重复叠色。
  List<TextSelection> _commentRangesFor(int i, List<Comment> chapterComments) {
    if (chapterComments.isEmpty) return const <TextSelection>[];
    final int bc = _blockChapterStart(i);
    final int be = bc + widget.page[i].length;
    final List<TextSelection> ranges = <TextSelection>[];
    for (final Comment comment in chapterComments) {
      final int start = comment.start.clamp(bc, be);
      final int end = comment.end.clamp(bc, be);
      if (end <= start) continue;
      final int plainStart = _chapterToPlain(i, start);
      final int plainEnd = _chapterToPlain(i, end);
      if (plainEnd > plainStart) {
        ranges.add(
          TextSelection(baseOffset: plainStart, extentOffset: plainEnd),
        );
      }
    }
    if (ranges.length < 2) return ranges;
    ranges.sort((a, b) => a.start.compareTo(b.start));
    final List<TextSelection> merged = <TextSelection>[ranges.first];
    for (final TextSelection current in ranges.skip(1)) {
      final TextSelection previous = merged.last;
      if (current.start <= previous.end) {
        merged[merged.length - 1] = TextSelection(
          baseOffset: previous.start,
          extentOffset: current.end > previous.end ? current.end : previous.end,
        );
      } else {
        merged.add(current);
      }
    }
    return merged;
  }

  double _measureIndent(String indent, TextStyle style, TextScaler scaler) {
    if (indent.isEmpty) return 0;
    final TextPainter tp = TextPainter(
      text: TextSpan(text: indent, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final double w = tp.width;
    tp.dispose();
    return w;
  }

  /// 缩进宽度（缓存）：仅取决于缩进串 / 字体 / 字号 / 系统缩放，页内恒定，
  /// 无需每次 build 都 `TextPainter.layout` 一次。
  double _indentWidth(TextScaler scaler) {
    final key = (_config.indent, _config.textStyle, scaler);
    final cached = _indentWidths[key];
    if (cached != null) return cached;
    final width = _measureIndent(key.$1, key.$2, scaler);
    // Share measurements across paragraphs entering the viewport during a
    // fling. Bound the cache so changing books/themes cannot grow it forever.
    if (_indentWidths.length >= 16) {
      _indentWidths.remove(_indentWidths.keys.first);
    }
    _indentWidths[key] = width;
    return width;
  }

  /// 与渲染完全一致的 [InlineSpan]：段首用等宽占位块承载缩进。
  InlineSpan _spanFor(
    ReaderBlock block,
    double indentWidth, {
    bool heading = false,
  }) {
    final style = heading
        ? _config.textStyle.copyWith(
            fontSize: _config.fontSize * 1.16,
            fontWeight: FontWeight.w700,
          )
        : _config.textStyle;
    if (!block.isParagraphStart) {
      return TextSpan(text: block.text, style: style);
    }
    final String body = block.text.replaceFirst(_leadingIndent, '');
    return TextSpan(
      style: style,
      children: <InlineSpan>[
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SizedBox(width: indentWidth),
        ),
        TextSpan(text: body),
      ],
    );
  }

  void _onLongPress(
    int blockIndex,
    ReaderBlock block,
    Offset globalPos,
    double indentWidth,
  ) {
    final RenderParagraph? rp = _para(blockIndex);
    if (rp == null) return;
    final Offset local = rp.globalToLocal(globalPos);
    final double width = rp.size.width;

    // 用真实渲染段落重建行度量（RenderParagraph 无 computeLineMetrics）：
    // 取整段选区盒、按 top 归并成行，保证与屏幕排版一致（Web 字体回退 / locale）。
    final int fullLen = _plainForSpan(block, indentWidth).length;
    final List<TextBox> allBoxes = rp.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: fullLen));
    if (allBoxes.isEmpty) return;
    final List<double> tops = <double>[];
    final List<double> heights = <double>[];
    for (final TextBox b in allBoxes) {
      int line = -1;
      for (int k = 0; k < tops.length; k++) {
        if ((tops[k] - b.top).abs() < 1.0) {
          line = k;
          break;
        }
      }
      final double h = b.bottom - b.top;
      if (line < 0) {
        tops.add(b.top);
        heights.add(h);
      } else if (h > heights[line]) {
        heights[line] = h;
      }
    }
    final List<int> order = List<int>.generate(tops.length, (int x) => x)
      ..sort((int a, int b) => tops[a].compareTo(tops[b]));
    final List<double> lineTop = <double>[for (final int j in order) tops[j]];
    final List<double> lineH = <double>[for (final int j in order) heights[j]];
    final int n = lineTop.length;
    // 手指所在行。
    int finger = n - 1;
    for (int i = 0; i < n; i++) {
      final double bottom =
          (i + 1 < n) ? lineTop[i + 1] : (lineTop[i] + lineH[i]);
      if (local.dy < bottom) {
        finger = i;
        break;
      }
    }
    // 目标行范围：≤2 行选整段；≥3 行选手指行 ± 1（共 3 行）。
    final int startLine;
    final int endLine;
    if (n <= 2) {
      startLine = 0;
      endLine = n - 1;
    } else {
      startLine = (finger - 1).clamp(0, n - 3);
      endLine = startLine + 2;
    }
    final double midStart = lineTop[startLine] + lineH[startLine] / 2;
    final double midEnd = lineTop[endLine] + lineH[endLine] / 2;
    int startOff = rp.getPositionForOffset(Offset(-1, midStart)).offset;
    final int endOff =
        rp.getPositionForOffset(Offset(width + 4000, midEnd)).offset;
    // 段首的缩进占位符（偏移 0）不应被选中/高亮——从第一个真实字符开始。
    if (block.isParagraphStart && startOff == 0) startOff = 1;
    if (endOff <= startOff) return;

    final String plain = _plainForSpan(block, indentWidth);
    final int s = startOff.clamp(0, plain.length);
    final int e = endOff.clamp(0, plain.length);

    widget.selectionGroup?.clear();
    setState(() {
      _selIndentWidth = indentWidth;
      _startBlock = blockIndex;
      _startOff = s;
      _endBlock = blockIndex;
      _endOff = e;
      _selText = _computeSelText();
    });
    widget.selectionGroup?._select(this,
        _plainToChapter(blockIndex, s), _plainToChapter(blockIndex, e));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _showSelectionOverlay());
  }

  /// 与 [_spanFor] 对齐的纯文本：段首前置一个占位符（对应缩进 WidgetSpan）。
  String _plainForSpan(ReaderBlock block, double indentWidth) {
    if (!block.isParagraphStart) return block.text;
    final String body = block.text.replaceFirst(_leadingIndent, '');
    return '￼$body';
  }

  void _showSelectionOverlay() {
    if (!mounted || !_selectionAttached) return;
    _removeToolbar();
    if (!_hasSel) return;
    _toolbar = OverlayEntry(builder: _buildSelectionOverlay);
    Overlay.of(context).insert(_toolbar!);
  }

  /// 首个非空选区盒（跨块向后找）：某端点所在块切片为空时（起点被拖到段尾等），
  /// 仍能取到实际可见的选区盒，避免 anchor 为 null 导致整个浮层消失。
  (RenderParagraph, TextBox)? _firstSelBox({bool localOnly = false}) {
    final group = widget.selectionGroup;
    if (!localOnly && group?._owner == this) {
      for (final state in group!._ordered) {
        final box = state._firstSelBox(localOnly: true);
        if (box != null) return box;
      }
      return null;
    }
    if (!_hasLocalSel) return null;
    for (int i = _startBlock!; i <= _endBlock!; i++) {
      final RenderParagraph? rp = _para(i);
      final TextSelection? ls = _localSel(i);
      if (rp == null || ls == null) continue;
      final List<TextBox> boxes = rp.getBoxesForSelection(ls);
      if (boxes.isNotEmpty) return (rp, boxes.first);
    }
    return null;
  }

  /// 末个非空选区盒（跨块向前找）。
  (RenderParagraph, TextBox)? _lastSelBox({bool localOnly = false}) {
    final group = widget.selectionGroup;
    if (!localOnly && group?._owner == this) {
      for (final state in group!._ordered.reversed) {
        final box = state._lastSelBox(localOnly: true);
        if (box != null) return box;
      }
      return null;
    }
    if (!_hasLocalSel) return null;
    for (int i = _endBlock!; i >= _startBlock!; i--) {
      final RenderParagraph? rp = _para(i);
      final TextSelection? ls = _localSel(i);
      if (rp == null || ls == null) continue;
      final List<TextBox> boxes = rp.getBoxesForSelection(ls);
      if (boxes.isNotEmpty) return (rp, boxes.last);
    }
    return null;
  }

  /// 起点手柄的全局锚点（首字左边界的行底）。
  Offset? _startAnchor() {
    final (RenderParagraph, TextBox)? r = _firstSelBox();
    if (r == null) return null;
    final (RenderParagraph rp, TextBox fb) = r;
    return rp.localToGlobal(Offset(fb.left, fb.bottom));
  }

  /// 终点手柄的全局锚点（末字右边界的行底）。
  Offset? _endAnchor() {
    final (RenderParagraph, TextBox)? r = _lastSelBox();
    if (r == null) return null;
    final (RenderParagraph rp, TextBox lb) = r;
    return rp.localToGlobal(Offset(lb.right, lb.bottom));
  }

  /// 依据当前选区实时计算高亮盒的全局位置，绘制工具条 + 首尾可拖拽手柄。
  Widget _buildSelectionOverlay(BuildContext ctx) {
    if (!mounted || !_selectionAttached) return const SizedBox.shrink();
    final Offset? start = _startAnchor();
    final Offset? end = _endAnchor();
    if (start == null || end == null) return const SizedBox.shrink();

    final Offset startBottom = start;
    final Offset endBottom = end;

    final MediaQueryData mq = MediaQuery.of(ctx);
    const double barH = 66;
    final double lineHeight = _config.fontSize * _config.lineHeight;
    final double selTop = startBottom.dy - lineHeight;
    final double selBottom = endBottom.dy; // 终点行底
    final bool above = selTop - mq.padding.top > barH + 12;
    final double barTop = (above ? selTop - barH - 8 : selBottom + 8)
        .clamp(mq.padding.top + 4, mq.size.height - barH - 4);

    // 每个子节点都带稳定 key：手柄在重建时按 key 正确复用元素，拖动手势不被中断。
    return Stack(
      children: <Widget>[
        // 全屏遮罩：吞掉遮罩上的拖动手势，避免「带位移的点击」穿透到下层 PageView
        // 的水平拖动而偶发翻页；点击遮罩空白处取消选中。
        Positioned.fill(
          key: const ValueKey<String>('sel-barrier'),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _clearSelection,
            onHorizontalDragStart: (_) {},
            onVerticalDragStart: (_) {},
          ),
        ),
        // Readium/系统选区的首尾手柄都悬挂在选区边界下方。
        _handle(
          key: const ValueKey<String>('sel-start'),
          anchor: startBottom,
          isStart: true,
        ),
        _handle(
          key: const ValueKey<String>('sel-end'),
          anchor: endBottom,
          isStart: false,
        ),
        // 气泡小菜单：拖动手柄时隐藏，松手后再显示。
        if (!_draggingHandle)
          Positioned(
            key: const ValueKey<String>('sel-toolbar'),
            left: 12,
            right: 12,
            top: barTop,
            child: GestureDetector(
              onVerticalDragStart: (_) {},
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(minWidth: constraints.maxWidth),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[_selectionBar()],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _handle({
    required Key key,
    required Offset anchor,
    required bool isStart,
  }) {
    const double handleSize = 22;
    const double touch = 22;
    return Positioned(
      key: key,
      left: anchor.dx - touch,
      top: anchor.dy - touch,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          _draggingHandle = true;
          _toolbar?.markNeedsBuild();
        },
        onPanUpdate: (DragUpdateDetails d) =>
            _dragHandle(isStart, d.globalPosition),
        onPanEnd: (_) => _endHandleDrag(),
        onPanCancel: _endHandleDrag,
        child: SizedBox(
          width: touch * 2,
          height: touch * 2 + handleSize,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: touch - handleSize / 2,
                top: touch,
                child: CustomPaint(
                  size: const Size.square(handleSize),
                  painter: _NativeSelectionHandlePainter(
                    color: _config.theme.accentColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// (b1,o1) 是否严格早于 (b2,o2)。
  bool _before(int b1, int o1, int b2, int o2) =>
      b1 < b2 || (b1 == b2 && o1 < o2);

  void _dragHandle(bool isStart, Offset globalPos) {
    if (!_hasSel) return;
    // 两个原生样式手柄都在文字下方，把触点向上回算到正文行内。
    final double bias = _config.fontSize * _config.lineHeight * 0.4;
    final Offset biased = Offset(globalPos.dx, globalPos.dy - bias);

    final group = widget.selectionGroup;
    if (group?._owner == this) {
      _ReaderProseState? hit;
      int? block;
      RenderParagraph? paragraph;
      var distance = double.infinity;
      for (final state in group!._ordered) {
        for (final i in state._keys.keys) {
          final rp = state._para(i);
          if (rp == null) continue;
          final top = rp.localToGlobal(Offset.zero).dy;
          final bottom = top + rp.size.height;
          final gap = biased.dy < top ? top - biased.dy : biased.dy > bottom ? biased.dy - bottom : 0.0;
          if (gap < distance) {
            distance = gap; hit = state; block = i; paragraph = rp;
          }
        }
      }
      if (hit == null || block == null || paragraph == null) return;
      final offset = paragraph.getPositionForOffset(paragraph.globalToLocal(biased)).offset
          .clamp(hit._minBase(block), hit._plainForSpan(hit.widget.page[block], _selIndentWidth).length);
      final position = hit._plainToChapter(block, offset);
      final start = isStart ? position.clamp(0, group._end - 1) : group._start;
      final end = isStart ? group._end : position < start + 1 ? start + 1 : position;
      group._select(this, start, end);
      return;
    }

    // 命中块：竖直落在哪个块内；落在块间空隙取竖直最近的块（支持跨段落）。
    int? hitBlock;
    RenderParagraph? hitRp;
    double bestGap = double.infinity;
    for (final int i in _keys.keys) {
      final RenderParagraph? rp = _para(i);
      if (rp == null) continue;
      final double top = rp.localToGlobal(Offset.zero).dy;
      final double bottom = top + rp.size.height;
      final double gap = biased.dy < top
          ? top - biased.dy
          : (biased.dy > bottom ? biased.dy - bottom : 0);
      if (gap < bestGap) {
        bestGap = gap;
        hitBlock = i;
        hitRp = rp;
      }
      if (gap == 0) break;
    }
    if (hitBlock == null || hitRp == null) return;

    final Offset local = hitRp.globalToLocal(biased);
    int off = hitRp.getPositionForOffset(local).offset;
    final int len =
        _plainForSpan(widget.page[hitBlock], _selIndentWidth).length;
    off = off.clamp(_minBase(hitBlock), len);

    int sb = _startBlock!, so = _startOff, eb = _endBlock!, eo = _endOff;
    if (isStart) {
      sb = hitBlock;
      so = off;
    } else {
      eb = hitBlock;
      eo = off;
    }
    // 归一化：保证起点严格早于终点（至少 1 个字符）。
    if (!_before(sb, so, eb, eo)) {
      if (isStart) {
        sb = eb;
        so = eo - 1;
        if (so < _minBase(eb)) return;
      } else {
        eb = sb;
        eo = so + 1;
        if (eo > _plainForSpan(widget.page[sb], _selIndentWidth).length) return;
      }
    }
    setState(() {
      _startBlock = sb;
      _startOff = so;
      _endBlock = eb;
      _endOff = eo;
      _selText = _computeSelText();
    });
    _toolbar?.markNeedsBuild();
  }

  Widget _selectionBar() {
    if (!mounted || !_selectionAttached || !_hasSel) return const SizedBox.shrink();
    final ReaderLabels labels = ReaderLabels.of(context);
    final ReaderSelectionScope? scope = ReaderSelectionScope.of(context);
    final ReaderUnderlineScope? uScope = ReaderUnderlineScope.of(context);
    // 复制 / 评论 / 查询 / 分享：插件不做任何内部处理（不写剪贴板、不弹输入框），
    // 仅把选中详情（章号 + 章标题 + 章内区间 + 文字）回调给业务方，由其自行处理。
    void act(ReaderTextAction action) {
      final (int, int)? range = _selChapterRange();
      scope?.onAction?.call(
        action,
        ReaderSelection(
          chapterIndex: widget.chapterIndex,
          chapterTitle: widget.chapterTitle,
          start: range?.$1 ?? -1,
          end: range?.$2 ?? -1,
          text: _selText,
        ),
      );
      _clearSelection();
    }

    // 划线：始终可「划线」（给整段选区划线，含其中未划线的部分）；若选区与已有划线
    // 相交，再额外显示「删除划线」删掉相交的。未接入划线作用域时回退旧的 onAction。
    final List<Underline> overlapping =
        uScope == null ? const <Underline>[] : _overlappingUnderlines();
    final bool hasOverlap = overlapping.isNotEmpty;
    void onAddHighlight() {
      if (uScope == null) {
        act(ReaderTextAction.highlight);
        return;
      }
      final (int, int)? range = _selChapterRange();
      if (range != null) {
        uScope.onAdd(widget.chapterIndex, range.$1, range.$2, _selText);
      }
      _clearSelection();
    }

    void onRemoveHighlight() {
      uScope?.onRemove(overlapping);
      _clearSelection();
    }

    return ReaderSelectionToolbar(
      actions: <ReaderSelectionToolbarAction>[
        ReaderSelectionToolbarAction(
          icon: Icons.content_copy_rounded,
          label: labels.selectCopy,
          onTap: () => act(ReaderTextAction.copy),
        ),
        ReaderSelectionToolbarAction(
          icon: Icons.border_color_outlined,
          label: labels.selectHighlight,
          onTap: onAddHighlight,
        ),
        ReaderSelectionToolbarAction(
          icon: Icons.mode_comment_outlined,
          label: labels.selectComment,
          onTap: () => act(ReaderTextAction.comment),
        ),
        if (hasOverlap)
          ReaderSelectionToolbarAction(
            icon: Icons.format_color_reset_outlined,
            label: labels.selectRemoveHighlight,
            onTap: onRemoveHighlight,
          ),
        ReaderSelectionToolbarAction(
          icon: Icons.search_rounded,
          label: labels.selectQuery,
          onTap: () => act(ReaderTextAction.query),
        ),
        ReaderSelectionToolbarAction(
          icon: Icons.ios_share_rounded,
          label: labels.selectShare,
          onTap: () => act(ReaderTextAction.share),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double indentWidth = _indentWidth(scaler);
    final bool selectable = ReaderSelectionScope.of(context)?.enabled ?? false;

    final ReaderSegmentScope? segScope = ReaderSegmentScope.of(context);
    final List<Comment> chapterComments = segScope == null ||
            segScope.comments.isEmpty ||
            !_config.showSegmentComments
        ? const <Comment>[]
        : <Comment>[
            for (final Comment comment in segScope.comments)
              if (comment.chapterIndex == widget.chapterIndex) comment,
          ];

    // 本章划线预筛一次，避免逐段重复过滤全量划线。
    final ReaderUnderlineScope? uScope = ReaderUnderlineScope.of(context);
    final List<Underline> chapterUnderlines =
        (uScope == null || uScope.underlines.isEmpty)
            ? const <Underline>[]
            : <Underline>[
                for (final Underline u in uScope.underlines)
                  if (u.chapterIndex == widget.chapterIndex) u,
              ];

    final List<Widget> children = <Widget>[];
    for (int i = 0; i < widget.page.length; i++) {
      final ReaderBlock block = widget.page[i];
      if (i > 0 && block.isParagraphStart) {
        children.add(SizedBox(height: _config.paragraphSpacing));
      }
      children.add(_paragraph(
        i,
        block,
        indentWidth,
        selectable,
        segScope,
        chapterUnderlines,
        chapterComments,
      ));
    }
    final Column column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    if (!widget.bounded) return column;
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: 0,
        maxHeight: double.infinity,
        child: column,
      ),
    );
  }

  Widget _paragraph(
    int i,
    ReaderBlock block,
    double indentWidth,
    bool selectable,
    ReaderSegmentScope? segScope,
    List<Underline> chapterUnderlines,
    List<Comment> chapterComments,
  ) {
    final heading = widget.headingOffsets.contains(_blockChapterStart(i));
    final InlineSpan span = _spanFor(block, indentWidth, heading: heading);
    final Widget text = Text.rich(
      span,
      textAlign: _config.textAlign,
      strutStyle: _config.strut,
    );

    final GlobalKey key = _keys.putIfAbsent(i, () => GlobalKey());
    final TextSelection? localSel = _localSel(i);
    final TextSelection? readingSel = _readingSelFor(i);
    final List<TextSelection> underlines =
        _underlineRangesFor(i, chapterUnderlines);
    final List<TextSelection> commentHighlights =
        _commentRangesFor(i, chapterComments);
    final Widget keyed = KeyedSubtree(key: key, child: text);
    final bool layered = localSel != null ||
        readingSel != null ||
        commentHighlights.isNotEmpty ||
        underlines.isNotEmpty;
    final Widget content = layered
        ? Stack(
            children: <Widget>[
              if (commentHighlights.isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _HighlightRangesPainter(
                      paragraphKey: key,
                      selections: commentHighlights,
                      color: _config.theme.commentHighlightColor,
                    ),
                  ),
                ),
              // 跟读高亮（听书当前句），置于最底层。
              if (readingSel != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _HighlightPainter(
                      paragraphKey: key,
                      selection: readingSel,
                      color: _config.theme.accentColor.withValues(alpha: 0.22),
                    ),
                  ),
                ),
              if (localSel != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _HighlightPainter(
                      paragraphKey: key,
                      selection: localSel,
                      color: _config.theme.selectionColor,
                    ),
                  ),
                ),
              if (underlines.isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _UnderlinePainter(
                      paragraphKey: key,
                      ranges: underlines,
                      color: _config.theme.underlineColor,
                    ),
                  ),
                ),
              keyed,
            ],
          )
        : keyed;

    final Widget interactiveContent =
        commentHighlights.isEmpty || segScope?.onTap == null
            ? content
            : _CommentHighlightTapRegion(
                paragraphKey: key,
                selections: commentHighlights,
                onTapOffset: (int plainOffset) {
                  final int chapterOffset = _plainToChapter(i, plainOffset);
                  final List<Comment> tapped = <Comment>[
                    for (final Comment comment in chapterComments)
                      if (comment.start <= chapterOffset &&
                          chapterOffset < comment.end)
                        comment,
                  ];
                  if (tapped.isEmpty) return;
                  final int start = tapped
                      .map((comment) => comment.start)
                      .reduce((a, b) => a < b ? a : b);
                  final int end = tapped
                      .map((comment) => comment.end)
                      .reduce((a, b) => a > b ? a : b);
                  segScope!.onTap!(ReaderSegmentTap(
                    chapterIndex: widget.chapterIndex,
                    start: start,
                    end: end,
                    count: tapped.length,
                  ));
                },
                child: content,
              );

    // 未启用选择时仍渲染已有划线，只是不响应长按。
    if (!selectable) return interactiveContent;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: (LongPressStartDetails d) => _onLongPress(
        i,
        block,
        d.globalPosition,
        indentWidth,
      ),
      onLongPressMoveUpdate: (details) {
        _draggingHandle = true;
        final bias = _config.fontSize * _config.lineHeight * 0.4;
        _dragHandle(false, details.globalPosition + Offset(0, bias));
      },
      onLongPressEnd: (_) => _endHandleDrag(),
      child: interactiveContent,
    );
  }
}

class _NativeSelectionHandlePainter extends CustomPainter {
  const _NativeSelectionHandlePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Readium/Android 原生选区手柄约 22dp：顶部窄连接点 + 下方圆形抓手。
    // 颜色来自宿主 Theme，与 Android NormalTheme 的 colorAccent 对齐。
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final double radius = size.width * 0.45;
    final double centerX = size.width / 2;
    final double centerY = size.height - radius;
    canvas
      ..drawRect(
        Rect.fromLTWH(centerX - 1, 0, 2, centerY),
        paint,
      )
      ..drawCircle(Offset(centerX, centerY), radius, paint);
  }

  @override
  bool shouldRepaint(covariant _NativeSelectionHandlePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _CommentHighlightTapRegion extends SingleChildRenderObjectWidget {
  const _CommentHighlightTapRegion({
    required this.paragraphKey,
    required this.selections,
    required this.onTapOffset,
    required super.child,
  });

  final GlobalKey paragraphKey;
  final List<TextSelection> selections;
  final ValueChanged<int> onTapOffset;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCommentHighlightTapRegion(
        paragraphKey: paragraphKey,
        selections: selections,
        onTapOffset: onTapOffset,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCommentHighlightTapRegion renderObject,
  ) {
    renderObject
      ..paragraphKey = paragraphKey
      ..selections = selections
      ..onTapOffset = onTapOffset;
  }
}

class _RenderCommentHighlightTapRegion extends RenderProxyBox {
  _RenderCommentHighlightTapRegion({
    required GlobalKey paragraphKey,
    required List<TextSelection> selections,
    required ValueChanged<int> onTapOffset,
  })  : _paragraphKey = paragraphKey,
        _selections = selections,
        _onTapOffset = onTapOffset {
    _tap.onTapUp = _handleTapUp;
  }

  final TapGestureRecognizer _tap = TapGestureRecognizer();
  GlobalKey _paragraphKey;
  List<TextSelection> _selections;
  ValueChanged<int> _onTapOffset;

  set paragraphKey(GlobalKey value) => _paragraphKey = value;
  set selections(List<TextSelection> value) => _selections = value;
  set onTapOffset(ValueChanged<int> value) => _onTapOffset = value;

  int? _offsetAt(Offset globalPosition) {
    final RenderObject? object =
        _paragraphKey.currentContext?.findRenderObject();
    if (object is! RenderParagraph || !object.hasSize) return null;
    final Offset local = object.globalToLocal(globalPosition);
    for (final TextSelection selection in _selections) {
      for (final TextBox box in object.getBoxesForSelection(selection)) {
        if (Rect.fromLTRB(box.left, box.top, box.right, box.bottom)
            .inflate(2)
            .contains(local)) {
          return object.getPositionForOffset(local).offset;
        }
      }
    }
    return null;
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (event is PointerDownEvent && _offsetAt(event.position) != null) {
      _tap.addPointer(event);
    }
  }

  void _handleTapUp(TapUpDetails details) {
    final int? offset = _offsetAt(details.globalPosition);
    if (offset != null) _onTapOffset(offset);
  }

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }
}

/// 在段落文字后面绘制选区高亮块。
///
/// 直接取真实渲染段落（[RenderParagraph]）的选区盒，而非另建 [TextPainter]，
/// 从而与屏幕上的实际排版严格对齐（避免 Web 字体回退 / locale 导致的错位、缺字）。
class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.paragraphKey,
    required this.selection,
    required this.color,
  });

  final GlobalKey paragraphKey;
  final TextSelection selection;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderObject? ro = paragraphKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph || !ro.hasSize) return;
    final Paint paint = Paint()..color = color;
    for (final TextBox b in ro.getBoxesForSelection(selection)) {
      final RRect r = RRect.fromRectAndRadius(
        Rect.fromLTRB(b.left - 1, b.top, b.right + 1, b.bottom),
        const Radius.circular(3),
      );
      canvas.drawRRect(r, paint);
    }
  }

  @override
  bool shouldRepaint(_HighlightPainter old) =>
      old.selection != selection ||
      old.color != color ||
      old.paragraphKey != paragraphKey;
}

class _HighlightRangesPainter extends CustomPainter {
  _HighlightRangesPainter({
    required this.paragraphKey,
    required this.selections,
    required this.color,
  });

  final GlobalKey paragraphKey;
  final List<TextSelection> selections;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderObject? ro = paragraphKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph || !ro.hasSize) return;
    final Paint paint = Paint()..color = color;
    for (final TextSelection selection in selections) {
      for (final TextBox box in ro.getBoxesForSelection(selection)) {
        final RRect rect = RRect.fromRectAndRadius(
          Rect.fromLTRB(box.left - 1, box.top, box.right + 1, box.bottom),
          const Radius.circular(3),
        );
        canvas.drawRRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_HighlightRangesPainter old) =>
      old.selections != selections ||
      old.color != color ||
      old.paragraphKey != paragraphKey;
}

/// 在文字下方绘制与 Readium 一致的持久直线。取真实渲染段落的选区盒，沿每个盒的
/// 底边绘制，换行后的每一行分别划线。
class _UnderlinePainter extends CustomPainter {
  _UnderlinePainter({
    required this.paragraphKey,
    required this.ranges,
    required this.color,
  });

  final GlobalKey paragraphKey;
  final List<TextSelection> ranges;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderObject? ro = paragraphKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph || !ro.hasSize) return;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.butt;
    for (final TextSelection r in ranges) {
      for (final TextBox b in ro.getBoxesForSelection(r)) {
        final double y = b.bottom + 1.5;
        canvas.drawLine(Offset(b.left, y), Offset(b.right, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_UnderlinePainter old) =>
      old.ranges != ranges ||
      old.color != color ||
      old.paragraphKey != paragraphKey;
}

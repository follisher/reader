import 'package:flutter/widgets.dart';

/// 阅读器所有对外文案的集合，支持本地化 / 白标定制。
///
/// 插件不依赖任何多语言框架：内置 12 种语言的文案预设（见 [forLanguageCode]），
/// 业务方只需把当前语言码传入（如 `ReaderLabels.forLanguageCode('zh')`）。
/// 未命中这 12 种时回退英文 [english]。也可直接构造自定义实例做白标。
///
/// 默认值即英文，因此 `const ReaderLabels()` == [english]。
@immutable
class ReaderLabels {
  const ReaderLabels({
    this.loading = 'Loading…',
    this.loadFailed = 'Failed to load',
    this.retry = 'Retry',
    this.prevChapter = 'Previous',
    this.nextChapter = 'Next',
    this.catalog = 'Contents',
    this.detail = 'Detail',
    this.bookmarkTab = 'Bookmarks',
    this.addBookmark = 'Add bookmark',
    this.removeBookmark = 'Remove bookmark',
    this.noBookmarks = 'No bookmarks yet',
    this.noBookmarksHint =
        'Tap the top-right while reading to add a bookmark,\nso you can jump back anytime.',
    this.noIntro = 'No synopsis',
    this.statChapters = 'Chapters',
    this.statCurrentChapter = 'Current',
    this.statProgress = 'Progress',
    this.introHeading = 'Synopsis',
    this.orderAsc = 'Ascending',
    this.orderDesc = 'Descending',
    this.themeMenu = 'Theme',
    this.dayMode = 'Day',
    this.nightMode = 'Night',
    this.settingsMenu = 'Settings',
    this.fontSize = 'Font size',
    this.lineSpacing = 'Line spacing',
    this.flipMode = 'Page turn',
    this.flipSimulation = 'Curl',
    this.flipCover = 'Cover',
    this.flipSlide = 'Slide',
    this.flipVertical = 'Scroll',
    this.flipNone = 'None',
    this.background = 'Background',
    this.bookEnd = '—— The End ——',
    this.loadingNext = 'Loading next chapter…',
    this.more = 'More',
    this.back = 'Back',
    this.selectCopy = 'Copy',
    this.selectHighlight = 'Highlight',
    this.selectRemoveHighlight = 'Remove',
    this.selectQuery = 'Look up',
    this.selectShare = 'Share',
    this.selectComment = 'Comment',
    this.commentTitle = 'Write a comment',
    this.commentHint = 'Write your thoughts…',
    this.commentSend = 'Send',
    this.noteFilterComment = 'Comments',
    this.segmentCommentsTitleTemplate = '{n} comments',
    this.segmentTagLabel = 'Note',
    this.commentAuthorSelf = 'Me',
    this.commentQuoteTemplate = 'Original: {q}',
    this.commentLike = 'Like',
    this.chapterProgressTemplate = 'Ch. {i}/{n}',
    this.chapterTotalTemplate = '{n} chapters',
    this.notesTab = 'Notes',
    this.noteFilterAll = 'All',
    this.noteDelete = 'Delete',
    this.noteJump = 'Go to',
    this.noNotes = 'No notes yet',
    this.noNotesHint =
        'Highlights, comments and bookmarks you add while reading show up here.',
    this.timeJustNow = 'just now',
    this.timeMinutesAgoTemplate = '{n} min ago',
    this.timeHoursAgoTemplate = '{n} h ago',
    this.timeDaysAgoTemplate = '{n} d ago',
    this.showSegmentComments = 'Show paragraph comments',
    this.hideSegmentComments = 'Hide paragraph comments',
    this.autoTurn = 'Auto page-turn',
    this.autoTurnStop = 'Stop auto-read',
    this.autoTurnExit = 'Exit auto-read',
    this.speedSlow = 'Slow',
    this.speedFast = 'Fast',
  });

  final String loading;
  final String loadFailed;
  final String retry;
  final String prevChapter;
  final String nextChapter;
  final String catalog;
  final String detail;
  final String bookmarkTab;
  final String addBookmark;
  final String removeBookmark;
  final String noBookmarks;
  final String noBookmarksHint;
  final String noIntro;

  /// 详情页统计卡：章节数 / 当前章 / 进度，以及「内容简介」标题。
  final String statChapters;
  final String statCurrentChapter;
  final String statProgress;
  final String introHeading;

  final String orderAsc;
  final String orderDesc;
  final String themeMenu;
  final String dayMode;
  final String nightMode;
  final String settingsMenu;
  final String fontSize;
  final String lineSpacing;
  final String flipMode;

  /// 翻页方式 5 个选项：仿真 / 覆盖 / 平移 / 上下 / 无动画。
  final String flipSimulation;
  final String flipCover;
  final String flipSlide;
  final String flipVertical;
  final String flipNone;

  final String background;
  final String bookEnd;
  final String loadingNext;
  final String more;
  final String back;

  /// 选中文字后的操作菜单：复制 / 划线 / 删除划线 / 查询 / 分享。
  final String selectCopy;
  final String selectHighlight;

  /// 选区与已有划线相交时，工具条上「划线」替换为「删除划线」。
  final String selectRemoveHighlight;
  final String selectQuery;
  final String selectShare;

  /// 选中文字后「评论」：气泡按钮文案 / 底部输入弹层标题 / 输入占位 / 发送按钮。
  final String selectComment;
  final String commentTitle;
  final String commentHint;
  final String commentSend;

  /// 笔记面板筛选「评论」。
  final String noteFilterComment;

  /// 段评列表：标题模板（{n}=评论数）/ 条目「段评」标签 / 作者「我」/ 引用原文模板
  /// （{q}=原文）/ 点赞文案。业务方弹出段评列表时可直接取用，避免重复维护多语言。
  final String segmentCommentsTitleTemplate;
  final String segmentTagLabel;
  final String commentAuthorSelf;
  final String commentQuoteTemplate;
  final String commentLike;

  /// 段评列表标题：如「12 条段评」。
  String segmentCommentsTitle(int count) =>
      segmentCommentsTitleTemplate.replaceFirst('{n}', '$count');

  /// 引用原文：如「原文：……」。
  String commentQuote(String quote) =>
      commentQuoteTemplate.replaceFirst('{q}', quote);

  /// “第 x/N 章” 模板：{i}=当前章号（从 1 起），{n}=总章数。
  final String chapterProgressTemplate;

  /// “共 N 章” 模板：{n}=总章数。
  final String chapterTotalTemplate;

  /// “第 x/N 章”
  String chapterProgress(int index, int count) => chapterProgressTemplate
      .replaceFirst('{i}', '${index + 1}')
      .replaceFirst('{n}', '$count');

  /// “共 N 章”
  String chapterTotal(int count) =>
      chapterTotalTemplate.replaceFirst('{n}', '$count');

  /// 笔记面板：Tab 标题 / 筛选「全部」/ 条目菜单「删除」「跳转」/ 空态文案。
  final String notesTab;
  final String noteFilterAll;
  final String noteDelete;
  final String noteJump;
  final String noNotes;
  final String noNotesHint;

  /// 相对时间文案：刚刚 / N 分钟前 / N 小时前 / N 天前（更久用绝对日期）。
  final String timeJustNow;
  final String timeMinutesAgoTemplate;
  final String timeHoursAgoTemplate;
  final String timeDaysAgoTemplate;

  /// 段评角标的显 / 隐（顶栏按钮的无障碍标签与提示）。
  final String showSegmentComments;
  final String hideSegmentComments;

  /// 自动翻页：设置面板里的开启入口 / 自动阅读中显示的停止 / 退出自动阅读 / 速度「慢」「快」。
  final String autoTurn;
  final String autoTurnStop;
  final String autoTurnExit;
  final String speedSlow;
  final String speedFast;

  /// 把时间戳（毫秒）格式化为相对时间；超过 7 天用 “yyyy-MM-dd”。
  String relativeTime(int ms, {DateTime? now}) {
    if (ms <= 0) return '';
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms);
    final Duration d = (now ?? DateTime.now()).difference(t);
    if (d.inMinutes < 1) return timeJustNow;
    if (d.inMinutes < 60) {
      return timeMinutesAgoTemplate.replaceFirst('{n}', '${d.inMinutes}');
    }
    if (d.inHours < 24) {
      return timeHoursAgoTemplate.replaceFirst('{n}', '${d.inHours}');
    }
    if (d.inDays <= 7) {
      return timeDaysAgoTemplate.replaceFirst('{n}', '${d.inDays}');
    }
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }

  // ————————————————————— 内置 12 种语言预设 —————————————————————

  static const ReaderLabels english = ReaderLabels();

  static const ReaderLabels chinese = ReaderLabels(
    loading: '加载中…',
    loadFailed: '加载失败',
    retry: '重试',
    prevChapter: '上一章',
    nextChapter: '下一章',
    catalog: '目录',
    detail: '详情',
    bookmarkTab: '书签',
    addBookmark: '加入书签',
    removeBookmark: '移除书签',
    noBookmarks: '还没有书签',
    noBookmarksHint: '阅读时点击右上角即可添加书签，\n方便随时回到精彩之处。',
    noIntro: '暂无简介',
    statChapters: '章节',
    statCurrentChapter: '当前章',
    statProgress: '进度',
    introHeading: '内容简介',
    orderAsc: '正序',
    orderDesc: '倒序',
    themeMenu: '主题',
    dayMode: '日间',
    nightMode: '夜间',
    settingsMenu: '设置',
    fontSize: '字号',
    lineSpacing: '行距',
    flipMode: '翻页',
    flipSimulation: '仿真',
    flipCover: '覆盖',
    flipSlide: '平移',
    flipVertical: '上下',
    flipNone: '无动画',
    background: '背景 / 主题',
    bookEnd: '—— 全书完 ——',
    loadingNext: '正在载入下一章…',
    more: '更多',
    back: '返回',
    selectCopy: '复制',
    selectHighlight: '划线',
    selectRemoveHighlight: '删除划线',
    selectQuery: '查询',
    selectShare: '分享',
    selectComment: '评论',
    commentTitle: '写评论',
    commentHint: '写下你的想法…',
    commentSend: '发送',
    noteFilterComment: '评论',
    segmentCommentsTitleTemplate: '{n} 条段评',
    segmentTagLabel: '段评',
    commentAuthorSelf: '我',
    commentQuoteTemplate: '原文：{q}',
    commentLike: '赞',
    chapterProgressTemplate: '第 {i}/{n} 章',
    chapterTotalTemplate: '共 {n} 章',
    notesTab: '笔记',
    noteFilterAll: '全部',
    noteDelete: '删除',
    noteJump: '跳转',
    noNotes: '还没有笔记',
    noNotesHint: '阅读时划线、写评论、点右上角加书签，都会出现在这里。',
    timeJustNow: '刚刚',
    timeMinutesAgoTemplate: '{n} 分钟前',
    timeHoursAgoTemplate: '{n} 小时前',
    timeDaysAgoTemplate: '{n} 天前',
    autoTurn: '自动翻页',
    autoTurnStop: '停止自动阅读',
    autoTurnExit: '退出自动阅读',
    speedSlow: '慢',
    speedFast: '快',
    showSegmentComments: '显示段评',
    hideSegmentComments: '隐藏段评',
  );

  /// 语言码 → 预设。
  static const Map<String, ReaderLabels> _byCode = <String, ReaderLabels>{
    'en': english,
    'zh': chinese,
  };

  /// 按语言码取内置文案；不在内置 12 种内则回退英文。
  static ReaderLabels forLanguageCode(String? code) => _byCode[code] ?? english;

  static const ReaderLabels fallback = english;

  static ReaderLabels of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReaderLabelsScope>()?.labels ??
      fallback;
}

/// 向子树提供 [ReaderLabels]。
class ReaderLabelsScope extends InheritedWidget {
  const ReaderLabelsScope({
    super.key,
    required this.labels,
    required super.child,
  });

  final ReaderLabels labels;

  @override
  bool updateShouldNotify(ReaderLabelsScope oldWidget) =>
      labels != oldWidget.labels;
}

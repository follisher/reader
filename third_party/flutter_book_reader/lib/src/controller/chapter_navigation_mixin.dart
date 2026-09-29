import '../paginator.dart';
import '../source/book_source.dart';
import 'chapter_content_mixin.dart';
import 'pagination_mixin.dart';
import 'reader_controller_base.dart';
import 'reader_seek_preview.dart';

/// 翻页与切章能力（横向/无动画模式使用）。
mixin ChapterNavigationMixin
    on ReaderControllerBase, ChapterContentMixin, PaginationMixin {
  static final RegExp _numberedHeading = RegExp(
    r'^第\s*[0-9零一二三四五六七八九十百千万两〇○]+\s*[章节回卷部篇]\s*[：:、.．—-]*\s*',
  );

  String _previewTitle(String title) {
    final String content =
        title.trim().replaceFirst(_numberedHeading, '').trim();
    return content.isEmpty ? ' ' : content;
  }

  ReaderSeekPreview previewForProgress(double progress) {
    final double normalized = progress.clamp(0.0, 1.0);
    final double scaled = normalized * chapterCount;
    final int targetChapter = normalized >= 1
        ? chapterCount - 1
        : scaled.floor().clamp(0, chapterCount - 1);
    final double chapterProgress =
        normalized >= 1 ? 1 : (scaled - targetChapter).clamp(0.0, 1.0);

    final List<int> knownPageCounts = <int>[];
    int? targetOffset;
    for (int chapter = 0; chapter < chapterCount; chapter++) {
      final String? body = bodyOf(chapter);
      if (body == null) continue;
      final List<ReaderPage>? chapterPages = pagesFor(chapter);
      if (chapterPages == null || chapterPages.isEmpty) continue;
      knownPageCounts.add(chapterPages.length);
      if (chapter == targetChapter) {
        targetOffset = offsetForChapterProgress(
          targetChapter,
          chapterProgress,
        );
      }
    }
    final int averagePageCount = knownPageCounts.isEmpty
        ? (pages.isEmpty ? 1 : pages.length)
        : (knownPageCounts.reduce((int a, int b) => a + b) /
                knownPageCounts.length)
            .round()
            .clamp(1, 1 << 30);
    final int totalPages = (averagePageCount * chapterCount).clamp(
      1,
      1 << 30,
    );
    final int page =
        normalized >= 1 ? totalPages : (normalized * totalPages).floor() + 1;
    String title = chapterTitleAt(targetChapter);
    BookTocEntry? subsection;
    void visit(List<BookTocEntry> entries, int depth) {
      for (final BookTocEntry entry in entries) {
        if (depth > 0 &&
            entry.chapterIndex == targetChapter &&
            entry.charOffset <= targetOffset! &&
            (subsection == null ||
                entry.charOffset >= subsection!.charOffset)) {
          subsection = entry;
        }
        visit(entry.children, depth + 1);
      }
    }

    if (targetOffset != null) visit(manifest.toc, 0);
    if (subsection != null) title = subsection!.title;
    return ReaderSeekPreview(
      page: page,
      totalPages: totalPages,
      title: _previewTitle(title),
    );
  }

  /// 按全书进度定位，并保留目标章节内的相对阅读位置。
  Future<void> seekToProgress(double progress) async {
    final double normalized = progress.clamp(0.0, 1.0);
    final double scaled = normalized * chapterCount;
    final int targetChapter = normalized >= 1
        ? chapterCount - 1
        : scaled.floor().clamp(0, chapterCount - 1);
    final double chapterProgress =
        normalized >= 1 ? 1 : (scaled - targetChapter).clamp(0.0, 1.0);

    await ensureLoaded(targetChapter);
    final String? body = bodyOf(targetChapter);
    if (body == null) {
      loadChapter(targetChapter);
      return;
    }
    final int targetOffset = offsetForChapterProgress(
      targetChapter,
      chapterProgress,
    );
    loadChapter(targetChapter, charOffset: targetOffset);
  }

  /// 加载某章。[atEnd] 为 true 时定位到该章最后一页（向前翻入）；
  /// [charOffset] 用于跳转到章内指定字符偏移（如书签），布局时据此定位到对应页。
  /// 返回横向 PageView 应使用的初始页索引（含 leading 偏移）。
  int loadChapter(int index, {bool atEnd = false, int charOffset = 0}) {
    final int clamped = index.clamp(0, chapterCount - 1);
    final int leadingOf = clamped > 0 ? 1 : 0;
    // 未解锁付费章只有首页：即便从下一章向前翻入（atEnd）也落到第一页，
    // 否则 pageIndex 会指向被隐藏的末页，与「可见页数=1」矛盾，导致翻页卡死。
    final bool locked = chapterLocked(clamped);
    int start = 0;
    if (atEnd && !locked) {
      final List<ReaderPage>? p = pagesFor(clamped);
      if (p != null && p.isNotEmpty) start = p.length - 1;
    }
    chapterIndex = clamped;
    onTitlePage = false; // 切章即离开扉页
    // charOffset > 0（如书签跳转）时先置首页，布局时 updateViewport 据 charOffset 校正到目标页
    this.charOffset = charOffset;
    pendingAtEnd = atEnd && !locked;
    signature = '';
    pageIndex = start;
    flowChapters = <int>[clamped];
    prefetchAround(clamped);
    notifyListeners();
    return leadingOf + start;
  }

  /// 定位到本章某页（点按/滑动跨页）。
  void goToPage(int index) {
    onTitlePage = false;
    // 未解锁付费章只放行首页。
    final int maxIndex =
        currentChapterLocked ? 0 : (pages.isEmpty ? 0 : pages.length - 1);
    pageIndex = index.clamp(0, maxIndex);
    charOffset = startOffsetOfPage(pageIndex);
    notifyListeners();
  }

  /// 停到扉页（第一章正文之前那一页）。
  void showTitlePage() {
    if (chapterIndex == 0 && hasTitlePage && !onTitlePage) {
      onTitlePage = true;
      pageIndex = 0;
      charOffset = 0;
      notifyListeners();
    }
  }

  void nextPage() {
    if (onTitlePage) {
      onTitlePage = false; // 扉页 → 正文第一页
      notifyListeners();
    } else if (currentChapterLocked) {
      // 未解锁付费章：只有首页可读，向后翻直接跳到下一章（跳过本章其余内容）。
      if (hasNext) loadChapter(chapterIndex + 1);
    } else if (pageIndex < pages.length - 1) {
      goToPage(pageIndex + 1);
    } else if (hasNext) {
      loadChapter(chapterIndex + 1);
    }
  }

  void prevPage() {
    if (onTitlePage) {
      return; // 已在扉页，前面没有了
    }
    if (pageIndex > 0) {
      goToPage(pageIndex - 1);
    } else if (hasPrev) {
      loadChapter(chapterIndex - 1, atEnd: true);
    } else if (chapterIndex == 0 && hasTitlePage) {
      showTitlePage(); // 第一章第一页 → 扉页
    }
  }

  double get globalProgress => progressForOffset(chapterIndex, charOffset);
}

Based on flutter_book_reader 1.5.13 from pub.dev (MIT, original LICENSE retained).

Local changes:
- Replace vertical chapter-sized scroll items with anchored paragraph items using
  scrollable_positioned_list. Restore/update chapter character offsets, preserve
  the visible anchor when prefetched content changes, and keep only adjacent
  chapters protected from cache eviction.
- Ignore asynchronous content notifications after controller disposal.
- Retain vertical paragraph page identities across ordinary list rebuilds so
  inserting the selection overlay does not immediately clear the selection.
  Invalidate the paragraph cache when configuration or paragraph content changes.
- Store a short body excerpt with each bookmark and backfill legacy bookmarks
  when the catalog opens, so bookmark cards can preview up to three text lines.
- Anchor vertical-scroll bookmarks to the live character offset instead of the
  paginated page index, allowing multiple bookmarks in one chapter and same-
  chapter navigation (including offset zero).

The host enables paragraph-local selection, highlights, comments and bookmarks
with SQLite stores. Each vertical paragraph owns a ReaderProse, so selection
does not span paragraphs. Paid content is not integrated in the vertical view;
upstream paginated views are retained.
Re-evaluate these patches when upgrading; do not edit the global pub cache.
# Shared EPUB menu integration

- Export `ReaderMenu` and `ReaderSeekPreview` so EPUB can reuse the TXT menu.
- `ReaderMenu.supportedFlipTypes` lets each engine expose only implemented modes;
  the default still includes every TXT flip type.
- Share `ReaderAutoReadBar`, `showReaderAutoReadSettings`, and the page timer
  progress bar with EPUB. The speed sheet exposes slow/fast and exit actions;
  each surface retains ownership of its motion and pause/resume lifecycle.

- 移除 TXT 正文段尾评论气泡及统计缓存；保留评论原文高亮和点击高亮打开评论的回调。

- TXT 纵向阅读的惰性段落共享同章选区，支持拖动手柄跨段、长按后拖动扩展，以及完整范围的划线、评论高亮与删除；首行缩进不计入选中文字。

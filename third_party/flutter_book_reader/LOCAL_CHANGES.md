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

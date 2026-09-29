# 书架便签与摘录卡片技术设计

> 状态：实现方案 v0.1  
> 对应需求：[书架便签与摘录卡片需求文档](bookshelf-notes-requirements.md)  
> 技术栈：Flutter、Riverpod、SQLite（sqflite）

## 1. 设计目标

- 在不破坏现有 `BookshelfRepository` 使用方的前提下增加书架聚合数据和跨书摘录查询。
- 避免按“书籍 × 笔记类型”逐条查询造成 N+1 性能问题。
- 复用现有书签、划线、评论 JSON 数据和阅读器定位坐标。
- 书签、划线或评论发生变化后，书架便签与摘录流能够即时刷新。
- 书架只保留三列网格布局，通过长按卡片发起移除。

## 2. 总体结构

```text
BookshelfView
├── ShelfGridView
│   └── ShelfBookCard + NoteTabsOverlay
├── ExcerptFeedView
│   └── ExcerptCard (underline/comment)
└── ShelfExcerptSwitcher
        │
        ▼
Riverpod providers/controllers
├── shelfEntriesProvider
├── excerptFeedProvider(query)
└── bookshelfUiStateProvider
        │
        ▼
BookshelfRepository
├── watchShelfEntries()
├── loadExcerptPage(query)
├── deleteReaderNote(ref)
└── existing book/note APIs
        │
        ▼
reader.sqlite
├── books
├── reader_notes
└── existing tags/book_tags (本功能不使用)
```

## 3. 数据模型

### 3.1 书架聚合模型

新增业务模型，不把 UI 字段塞入现有 `Book`：

```dart
class ShelfEntry {
  final Book book;
  final int noteCount; // bookmark + underline + comment，聚合层兼容字段
  final List<ShelfNoteMarker> markers; // 最近 4 条，用于网格便签
}

class ShelfNoteMarker {
  final ReaderNoteKind kind;
  final String noteKey;
  final int createdAt;
  final int colorIndex;
}
```

`colorIndex` 不持久化，使用稳定哈希计算：

```text
hash(bookId + kind + noteKey) % palette.length
```

这样颜色只承担装饰作用，并在页面重建、重启 App 后保持稳定。

### 3.2 摘录模型

```dart
enum ExcerptKind { underline, comment }

class ReaderNoteRef {
  final String bookId;
  final ReaderNoteKind kind;
  final String noteKey;
}

class ExcerptItem {
  final ReaderNoteRef ref;
  final Book book;
  final int chapterIndex;
  final int startOffset;
  final String chapterTitle;
  final int createdAt;
  final String quote; // 划线原文或评论引用
  final String comment; // 划线为空，评论为正文
}
```

使用稳定复合键 `bookId + kind + noteKey` 作为列表 Key、删除目标和分页并列项。

### 3.3 查询模型

```dart
enum ExcerptSort { newest, oldest, random }

class ExcerptQuery {
  final String text;
  final String? bookId;
  final ExcerptSort sort;
  final int? randomSeed;
}

class ExcerptPage {
  final List<ExcerptItem> items;
  final String? nextCursor;
}
```

## 4. SQLite 方案

### 4.1 数据库版本

数据库由 v7 升级至 v8。保留 `payload` 作为完整数据真源，为 `reader_notes` 增加可查询的冗余列：

```sql
ALTER TABLE reader_notes ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE reader_notes ADD COLUMN chapter_index INTEGER NOT NULL DEFAULT 0;
ALTER TABLE reader_notes ADD COLUMN start_offset INTEGER NOT NULL DEFAULT 0;
ALTER TABLE reader_notes ADD COLUMN display_text TEXT NOT NULL DEFAULT '';
ALTER TABLE reader_notes ADD COLUMN quote_text TEXT NOT NULL DEFAULT '';

CREATE INDEX reader_notes_book_created
ON reader_notes(book_id, created_at DESC, note_key);

CREATE INDEX reader_notes_kind_created
ON reader_notes(kind, created_at DESC, note_key);
```

字段映射：

| 类型 | `start_offset` | `display_text` | `quote_text` |
|---|---:|---|---|
| bookmark | `charOffset` | `excerpt` | 空 |
| underline | `start` | `text` | 空 |
| comment | `start` | `text` | `quote` |

升级时逐行解析旧 `payload` 回填。解析失败的行保留 payload，但冗余字段使用安全默认值；不能让单条历史脏数据导致数据库无法打开。

### 4.2 写入同步

现有 `saveNotes()` 仍按书籍和类型原子替换列表，但插入每一行时同步填写冗余列。事务完成后调用统一的 `_notifyChanged()`，触发书架和摘录 Provider 刷新。

所有会影响页面的操作统一发送变更事件：

- `saveNotes()`
- `removeBook()`
- 导入书籍
- 保存阅读进度

变更事件建议从无信息的 `Stream<void>` 升级为内部 `LibraryChange`，至少区分 `books`、`progress`、`notes`，便于后续只刷新受影响数据；对外仍可保持现有接口兼容。

### 4.3 书架聚合查询

使用两次批量查询，不逐书读取：

1. 查询全部可见书籍。
2. 一次查询所有 `reader_notes` 的 `book_id/kind/note_key/created_at`，在 Dart 中按 `book_id` 分组、统计总数、取最近 4 条。

500 本书、1 万条笔记的目标规模下，这种方式足够简单稳定；不在 SQL 中依赖窗口函数，减少不同移动端 SQLite 版本差异。

### 4.4 摘录分页查询

最新/最早排序使用 keyset pagination，不使用大偏移量 `OFFSET`：

```text
cursor = createdAt + noteKey
ORDER BY created_at DESC/ASC, note_key DESC/ASC
LIMIT 50
```

查询条件：

- `kind IN ('underline', 'comment')`
- 划线的 `display_text` 非空。
- 评论的 `display_text` 或 `quote_text` 至少一个非空。
- 可选 `book_id`。
- 搜索时对 `display_text`、`quote_text`、书名、作者做 `LIKE`，并关联 `books`。

首期不引入 FTS。若 1 万条数据下实机搜索超过目标延迟，再评估 SQLite FTS5。

随机回顾由 Provider 在当前会话中维护固定 seed：首次进入加载符合条件的引用 ID，使用 seed 洗牌并分批映射为页面；只有用户主动刷新才更换 seed。这样列表重建不会重新排序。

## 5. Repository 接口

在保留现有接口的基础上增加：

```dart
abstract interface class BookshelfRepository {
  Stream<List<ShelfEntry>> watchShelfEntries();

  Future<ExcerptPage> loadExcerptPage(
    ExcerptQuery query, {
    String? cursor,
    int limit = 50,
  });

  Future<void> deleteReaderNote(ReaderNoteRef ref);
}
```

删除单条摘录不应采用“读取整类列表 → 客户端删除 → 全量覆盖”，否则多个页面或异步写入可能互相覆盖。`deleteReaderNote()` 应按 `book_id + kind + note_key` 在事务中精确删除，然后发送 notes 变更事件。

现有 `loadNotes()/saveNotes()` 继续供阅读器会话使用。

## 6. Riverpod 状态设计

### 6.1 Provider

```dart
final shelfEntriesProvider = StreamProvider<List<ShelfEntry>>(...);

final bookshelfUiStateProvider =
    NotifierProvider<BookshelfUiController, BookshelfUiState>(...);

final excerptFeedProvider = AsyncNotifierProviderFamily<
    ExcerptFeedController, ExcerptFeedState, ExcerptQuery>(...);
```

### 6.2 UI 状态

`BookshelfUiState` 保存：

- 当前视图：`shelf` / `excerpts`。
- 书架搜索词和滚动位置。
- 摘录搜索词、书籍筛选、排序方式和滚动位置。

页面存活期间由 Provider 保持；“再次进入页面恢复上次视图”如果指跨 App 重启，则将当前视图和排序写入 `settings.options`。搜索词不跨重启保存，避免打开页面仍带有难以察觉的旧过滤条件。

### 6.3 刷新策略

- 书架：订阅 `watchShelfEntries()`。
- 摘录：订阅 notes/books 变更事件；当前查询失效后重新拉取第一页。
- 搜索输入采用 250–300 ms 防抖。
- 删除采用等待数据库成功后移除 UI 的保守策略；失败时保留卡片并提示重试，避免乐观更新后难以恢复。

## 7. UI 组件拆分

建议将当前较大的 `bookshelf_view.dart` 拆分：

```text
lib/src/bookshelf/
├── bookshelf_view.dart
├── bookshelf_models.dart
├── bookshelf_providers.dart
├── shelf_grid_view.dart
├── shelf_book_card.dart
├── note_tabs_overlay.dart
├── excerpt_feed_view.dart
├── excerpt_card.dart
└── shelf_excerpt_switcher.dart
```

### 7.1 网格

- 使用三列网格行构建书架。
- 卡片主体使用 `InkWell.onTap` 和 `onLongPress`。
- 便签使用 `IgnorePointer`，确保点击语义始终落到整张卡片。
- 封面由网格卡片的 `_GridCover` 统一渲染。
- 进度条覆盖在封面底部，避免额外占用纵向空间。

### 7.2 便签视觉

- 使用纯 Flutter `Container`/`CustomPainter` 绘制，不增加图片资源。
- 便签从封面左右边缘交错露出，最多 4 张。
- 固定柔和色板，例如黄、粉、蓝、绿、橙、紫。
- 对无封面占位图同样展示，并在深色模式下增加边缘描边。
- 装饰节点设置 `ExcludeSemantics`。

### 7.3 摘录流

- 使用 `CustomScrollView + SliverList` 懒构建。
- 接近列表末尾时加载下一页；底部显示加载中、失败重试或“已到底”。
- 划线和评论共用外壳组件，正文区域按类型渲染。
- 评论卡片明确区分引用块与评论正文。
- 展开/收起状态按 `ReaderNoteRef` 记录在页面状态中。

### 7.5 底部切换按钮

- 自定义悬浮分段控件，放在 `Scaffold` 的底部安全区上方。
- 左侧“书架 + 图标”，右侧“摘录 + 图标”；当前项使用选中底色和字重。
- 控件不遮挡网格/列表最后一项，滚动内容增加相应 bottom padding。
- 提供完整中文 Semantics，支持键盘焦点与大字体。

## 8. 导航与原文定位

### 8.1 打开请求

新增：

```dart
class ReaderOpenRequest {
  final Book book;
  final int? chapterIndex;
  final int? charOffset;
}
```

为兼容现有宿主，`BookshelfView` 保留 `onBookTap(Book)`，增加可选的：

```dart
final ValueChanged<ReaderOpenRequest>? onReaderOpen;
```

- 普通书籍点击仍调用 `onBookTap`。
- 摘录点击优先调用 `onReaderOpen`。
- 未提供 `onReaderOpen` 时回退为 `onBookTap`，至少能打开书籍，但宿主若要满足精确定位验收必须接入新回调。

### 8.2 ReaderView

为 `ReaderView` 增加可选 `initialPosition`，映射到引擎已有的：

```dart
BookReader(
  startChapter: initialPosition?.chapterIndex,
  startCharOffset: initialPosition?.charOffset,
)
```

引擎已经规定：传入 `startChapter` 时优先使用指定位置，否则读取现有阅读进度，因此无需修改分页或坐标算法。

划线使用 `start`，评论使用 `start` 作为 `charOffset`。

## 9. 删除与一致性

### 9.1 删除摘录

1. 用户从卡片菜单选择删除。
2. 弹出二次确认，文案区分“划线”和“评论”。
3. 调用 `deleteReaderNote(ref)` 精确删除。
4. 数据库提交成功后发出 notes 变更事件。
5. 摘录流刷新，书架 marker 同步刷新。

### 9.2 删除书籍

- 网格长按调用 `_confirmRemove()` 与 `removeBook()`。
- 现有实现会删除 `reader_notes` 后删除书籍，继续复用。
- 删除确认文案更新为包含书签、划线和评论。

### 9.3 并发写入

- 继续使用 Repository 的 `_serial` 队列串行化 SQLite 写入。
- 单条删除和阅读器全量 `saveNotes()` 可能竞争；数据库操作串行只能保证顺序，不能避免旧会话快照重新写回。
- 因此 `saveNotes()` 应增加每类笔记的修订号或在阅读器会话返回前完成 pending flush。首期建议为 `reader_notes` 增加内部 revision 检查，避免摘录页删除后被仍打开的旧阅读器快照恢复。

## 10. 测试方案

### 10.1 Repository 测试

- v7 → v8 迁移保留全部 payload 并正确回填冗余列。
- 三类笔记聚合总数正确，最近 4 条排序稳定。
- 空正文划线和完全空评论不进入摘录流。
- 最新、最早分页无重复、无遗漏。
- 文本搜索覆盖划线、评论引用、评论正文、书名和作者。
- 单条删除只删除目标，不影响同书其他笔记。
- 删除书籍后不再返回 marker 或摘录。
- `saveNotes()` 成功后会触发订阅刷新。

### 10.2 Widget 测试

- 网格卡片展示 0–4 张便签，超过 4 条仍为 4 张。
- 便签无独立点击语义，点击其区域仍打开书籍。
- 网格长按出现现有移除确认弹窗。
- 底部切换按钮正确切换并保持两侧状态。
- 划线/评论卡片布局、展开、复制、删除和错误提示。
- 大字体、深色模式、无封面状态无溢出。

### 10.3 导航测试

- 普通点击恢复上次阅读位置。
- 划线卡片传递 `chapterIndex + start`。
- 评论卡片传递 `chapterIndex + start`。
- 指定摘录位置时覆盖已有阅读进度；普通打开时仍恢复阅读进度。

### 10.4 性能验证

- 生成 500 本书、10,000 条划线/评论的测试数据库。
- 记录书架聚合查询、首屏构建和搜索响应时间。
- 确认网格仅构建可见卡片，摘录每页默认 50 条。
- 观察滚动期间帧时间和图片内存，不一次性加载所有封面原图。

## 11. 实施顺序

1. **数据层**：v8 迁移、冗余列写入、聚合查询、摘录分页、精确删除、变更通知。
2. **状态层**：新增模型和 Riverpod Provider，完成搜索、排序、分页、刷新。
3. **导航层**：`ReaderOpenRequest`、`ReaderView.initialPosition`、宿主回调兼容。
4. **书架 UI**：拆出现有列表，新增网格、便签、进度和长按移除。
5. **摘录 UI**：划线/评论卡片、筛选、排序、复制、删除。
6. **切换与状态保持**：底部悬浮分段控件、滚动位置和查询状态。
7. **验证**：迁移测试、Repository 测试、Widget/导航测试、性能数据集。

## 12. 主要风险

| 风险 | 应对 |
|---|---|
| JSON 内字段无法高效搜索和分页 | v8 增加冗余查询列，payload 继续作为完整数据真源 |
| 笔记保存后书架不刷新 | `saveNotes()` 提交后统一发送 notes 变更事件 |
| 摘录页删除被旧阅读器快照恢复 | 引入修订号/冲突检查，并在退出阅读器时 flush pending 写入 |
| 网格便签颜色每次变化 | 由稳定复合键计算颜色，不使用运行时随机数 |
| 悬浮切换控件遮挡内容 | 统一增加安全区和列表底部 padding |
| 大量封面导致内存上涨 | 使用目标尺寸解码、懒加载与现有文件缓存 |
| 公共组件 API 破坏宿主 | 保留 `onBookTap`，新增可选精确定位回调 |

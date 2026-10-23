# Reader

本地离线阅读：提供书架、分类目录、阅读器和阅读数据持久化。

支持导入或内置 **TXT、Markdown（`.md`）、EPUB 与 PDF**。PDF 阅读仅在 Android/iOS 可用；其余三种格式可使用文本阅读器，EPUB 在 Android/iOS 会使用 Readium 原生阅读器。

## 功能概览

- 本地书架：分类视图/网格视图、搜索、封面、阅读进度、阅读便签与长按移除。
- 导入：可多选导入 UTF-8 TXT、Markdown、EPUB、PDF；SHA-256 自动去重，保留用户原文件不变。
- 内置目录：由宿主以 Dart `BookCatalog` 声明书籍、标签和可选排版文件；可按标签查询或监听图书变化。
- TXT 与 Markdown：TXT 自动识别常见中文章节和 `Chapter N`；Markdown 使用 GitHub Flavored Markdown 解析并按标题建立章节。
- EPUB：读取元数据、封面、目录、正文和内嵌图片；Android/iOS 支持横向分页或纵向连续阅读、目录、书签、划线、评论、复制、搜索、分享及位置恢复。
- PDF：Android/iOS 支持原生渲染、目录跳转、进度跳转、书签、上下/左右滚动及阅读位置恢复。
- 文本阅读：连续滚动、平移/覆盖/仿真等翻页模式、字体/行距/段落/纸张/亮度设置、自动阅读、书签、划线、评论、复制、搜索、分享和进度恢复。
- 阅读摘录：跨书集中查看划线与评论，支持搜索、按书筛选、排序、随机回顾、复制、删除和跳回原文。
- 数据与性能：书籍副本、缓存、进度、设置和笔记存入应用私有目录；章节按需加载，解析在后台 isolate 执行。

## 快速接入

在宿主的 `pubspec.yaml` 中使用本地路径依赖：

```yaml
dependencies:
  reader:
    path: ../reader
```

启动时创建仓库，并在根 `ProviderScope` 注入：

```dart
final repository = await LocalBookshelfRepository.create();

runApp(
  ProviderScope(
    overrides: [
      bookshelfRepositoryProvider.overrideWithValue(repository),
    ],
    child: const MyApp(),
  ),
);
```

书架和阅读页的导航由宿主控制：

```dart
BookshelfView(
  onBookTap: (book) => openReader(context, book: book),
  onReaderOpen: (request) => openReaderRequest(context, request: request),
)
```

`onReaderOpen` 用于从书签、划线和评论精确回到原文；应原样传递 `ReaderOpenRequest`。应用退出时调用 `await repository.close()`。

### 主题与封面复用

`ReaderView`、`openReader` 和 `openReaderRequest` 默认跟随 `Theme.of(context).brightness`；需要阅读器独立主题时传入 `followHostTheme: false`。`BookCover` 可在宿主的其他列表中复用书架封面样式，无需注入仓库：

```dart
BookCover(
  book: book,
  onTap: () => openReader(context, book: book),
)
```

## 内置书籍与分类

在宿主维护书籍清单并注入 `readerCatalogProvider`。未注入时不会导入任何内置资源。

```dart
abstract final class AppBookTags {
  static const classic = CatalogTag(name: '经典', color: '#7C3AED');
  static const history = CatalogTag(name: '历史', color: '#57715D');
}

const catalog = BookCatalog(books: [
  CatalogBook(
    assetPath: 'assets/books/example.md',
    tags: [AppBookTags.classic],
    // 可选：为 TXT/Markdown 提供排版与目录数据。
    layoutAssetPath: 'assets/books/example.layout.json',
  ),
]);

ProviderScope(
  overrides: [
    readerCatalogProvider.overrideWithValue(catalog),
  ],
  child: const MyApp(),
)
```

同时在宿主 `pubspec.yaml` 声明资源目录。标签名称是持久化唯一标识：同名标签应复用同一常量，且颜色声明必须一致。

按标签读取图书：

```dart
final library = ref.read(readerLibraryProvider);
final books = await library.loadBooksByTags(
  BookTagsQuery(tags: [AppBookTags.classic]),
);

final watched = ref.watch(booksByTagsProvider(
  BookTagsQuery(
    tags: [AppBookTags.classic, AppBookTags.history],
    match: BookTagMatch.any,
  ),
));
```

多个标签默认要求全部匹配；`BookTagMatch.any` 表示匹配任意一个；空标签查询全部图书。

## 导入与外部内容

`BookshelfView` 已包含文件选择和导入入口。通过下载或资源文件取得字节时，也可直接导入：

```dart
await repository.importBytes(
  bytes,
  'book.epub',
  source: BookSource.downloaded,
);
```

`BookSource` 支持 `builtIn`、`imported` 和 `downloaded`。模块不发起网络请求，也不保存账号或授权状态。

需要接入远程或加密章节时，可实现 `flutter_book_reader` 的 `BookSource` 并传给 `ReaderView`；大型内容建议实现 `OnDemandBookContent`，按章加载：

```dart
ReaderView(
  key: const ValueKey('remote-book'),
  book: shelfBook,
  source: remoteSource,
  controller: BookReaderController(),
)
```

更换书籍或数据源时请使用新的 Widget key。自定义文本源使用文本阅读器；本地 EPUB/PDF 的原生阅读要求仓库实现 `PublicationFileRepository`，`LocalBookshelfRepository` 已实现。

## 平台与安全边界

- Flutter >= 3.44.4，Dart >= 3.10.0 < 4.0.0。
- Android/iOS：EPUB 与 PDF 使用 Readium；iOS 最低版本为 15.0，Android 最低 minSdk 为 24。Android 还需启用 core-library desugaring。具体 Pod 与 Gradle 配置可参考 `example/`。
- 桌面平台：PDF 会显示不可用提示；EPUB 回退为文本阅读路径，富文本和图片呈现能力受限。
- 单个文件上限 50 MB；EPUB 最多 10,000 个资源、声明解压体积上限 150 MB。TXT 和 Markdown 必须为 UTF-8。
- Markdown 导入会移除脚本、事件属性和不安全资源；EPUB 离线解析路径会清理脚本、嵌入框架与外部资源。Readium 对原始 EPUB 的资源和链接策略应由宿主按产品安全要求验证。
- 不提供 DRM、图书加密、密钥授权或云同步；不支持固定版式 EPUB、音视频及复杂 CSS 的完整还原。

## 示例与开发

示例工程位于 `example/`，包含 TXT、Markdown、EPUB 和 PDF 样例：

```sh
cd example
flutter pub get
flutter run
```

在模块根目录进行验证：

```sh
flutter pub get
flutter analyze
flutter test
```

测试覆盖格式解析与导入、目录与封面、阅读位置、笔记和摘录、EPUB 连续阅读与选区、PDF 导航，以及书架和阅读器交互。

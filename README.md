# Reader

`reader` 是一个可独立维护的 Flutter 阅读模块，提供本地 EPUB/TXT 书架、阅读器和阅读进度管理。它不负责应用路由、账号、下载或授权，宿主应用决定这些部分如何实现。

## 目录与定位

模块独立位于：

```text
/Users/bo/Documents/blindness/reader
```

可以在此目录单独初始化 Git 仓库。主应用通过本地路径依赖它：

```yaml
dependencies:
  reader:
    path: ../reader
```

## 已实现能力

- 三列网格书架、书名/作者筛选、封面阅读便签、阅读进度与长按移除确认。
- 跨书摘录流集中展示划线和评论，支持搜索、按书筛选、排序、随机回顾、复制、删除及跳回原文。
- 多选导入本地 UTF-8 TXT 文件；内置 EPUB 仍可正常解析和阅读。
- EPUB 元数据、spine 章节顺序、正文与内嵌位图读取；书架会显示 EPUB 声明的封面，没有封面时使用默认图标。
- TXT 常见中文章节名与 `Chapter N` 识别；无章节文本自动分段。
- 默认采用 `flutter_book_reader`：上下连续滚动、真实分页、平移/覆盖/仿真/无动画切页。
- 全屏沉浸阅读，轻点正文中间唤起菜单；设置中切换翻页模式、字号、行距、纸张主题与亮度蒙层。
- 自动翻页及速度调节；连续滚动模式自动滚动，进入后台停止自动阅读。
- 本地章节缓存分文件保存，阅读时仅加载清单及当前/相邻章节。导入和旧缓存升级仍需完整解析一次。
- EPUB 默认使用文本重排；菜单中的“图文阅读”切换到兼容 HTML 阅读页，保留图片及原有嵌套目录。
- 新阅读页保存章节与字符位置，400ms 防抖，退出/后台立即提交；旧段落位置自动转换。图文页沿用段落位置及 700ms 防抖。
- SHA-256 去重。导入结果会区分新增图书与已合并的重复文件；图书副本、书架、进度和设置均保存在应用私有目录，不会修改用户原文件。

书架文件默认存于 `Application Support/reader`。曾使用旧目录名的版本会在首次打开时自动迁移书架数据。

## 接入宿主应用

在应用启动时创建一个共享仓库，并将它注入根 `ProviderContainer`。这样书架页面与阅读页始终使用同一份状态和数据库。

```dart
final readerRepository = await LocalBookshelfRepository.create();

final container = ProviderContainer(
  overrides: [
    bookshelfRepositoryProvider.overrideWithValue(readerRepository),
  ],
);

runApp(UncontrolledProviderScope(container: container, child: const MyApp()));
```

书架和阅读页由宿主控制导航：

```dart
BookshelfView(
  onBookTap: (book) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReaderView(book: book)),
    );
  },
  onReaderOpen: (request) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderView(
          book: request.book,
          initialChapter: request.chapterIndex,
          initialCharOffset: request.charOffset,
        ),
      ),
    );
  },
)
```

`onReaderOpen` 用于从摘录卡片精确定位到章节字符位置。它是可选回调；不传时摘录卡片会回退到 `onBookTap`，只能打开书籍而不能保证定位到该条摘录。

应用退出前或根容器释放后，调用 `readerRepository.close()` 关闭数据库。

## 添加图书

`BookshelfView` 内置本地文件选择与导入入口。若宿主使用资源文件或后续的下载服务，统一将获得的字节交给仓库：

```dart
// 已从 AssetBundle 读取，或已完成网络下载与完整性校验。
await repository.importBytes(
  bytes,
  'book.epub',
  source: BookSource.downloaded,
);
```

`BookSource` 已预留 `builtIn`、`imported` 和 `downloaded`。模块当前不发网络请求，也不保存账号或授权状态。

### 分类查询与正文跳转

主应用可以在未打开书架时读取某个分类。入口会先同步内置书籍，再查询本地书架；查询包含该标签下的内置、导入和下载图书，不包含已移除的书。读取或导入失败会抛出异常，调用方可显示重试。

```dart
final library = ref.read(readerLibraryProvider);
final books = await library.loadBooksByTags(
  BookTagsQuery(tags: [AppBookTags.fortune]), // 命理
);

// 点击查询结果直接打开正文，恢复阅读进度。
await openReader(context, book: books.first);
```

实际列表需处理空结果后再取书籍。`openReader` 接收列表返回的 `Book`，无需自行拼接书名、文件路径或 ID；context 需位于已注入仓库的 ProviderScope 和 Navigator 内。该方法将当前仓库传入阅读页，支持局部 ProviderScope。宿主若使用自己的路由系统，也可直接构建 `ReaderView(book: book)`。

标签由主仓库定义为 `CatalogTag` 常量（下文的 `AppBookTags`）。清单和查询共用这些常量，无需在 reader 中添加枚举，也不用在调用处手写标签名称。多个标签默认要求全部匹配；传 `match: BookTagMatch.any` 可改为任一匹配，空标签返回全部图书。

需要自动更新的页面使用：

```dart
final books = ref.watch(booksByTagsProvider(
  BookTagsQuery(tags: [AppBookTags.fortune, AppBookTags.ancient]),
)); // AsyncValue<List<Book>>：处理 loading/error/data
```

书架的两个回调也可直接使用统一导航入口：

```dart
BookshelfView(
  onBookTap: (book) => openReader(context, book: book),
  onReaderOpen: (request) => openReaderRequest(context, request: request),
)
```

### 跟随主应用夜间模式

`ReaderView`、`HtmlReaderView`、`openReader` 和 `openReaderRequest` 默认跟随主应用 `Theme.of(context).brightness`：应用夜间模式使用深色正文，返回日间模式恢复阅读器保存的日间纸张主题（若原先保存的是夜间主题则使用白色）。文本和图文阅读均支持，系统主题变化也会跟随。应用模式不会覆盖保存的纸张偏好、字号和阅读位置。

阅读器菜单仍可手动调整文本阅读主题；后续主应用明暗模式变化或重新打开正文时重新跟随。图文阅读跟随时隐藏独立夜间切换按钮。

所有入口默认跟随，不需要修改主仓库调用方式。若某个场景需要独立阅读主题，可显式设置 `followHostTheme: false`，Widget 和统一导航方法都支持。

### 外部使用书籍封面

`BookCover` 复用书架的封面样式，默认不显示分类标签、阅读便签和进度，不需要注入仓库。传入查询得到的 `Book` 即可：

```dart
BookCover(
  book: book,
  onTap: () => openReader(context, book: book),
)
```

默认大小为 110 × 162，父级 `SizedBox` 或网格约束可以调整大小。存在封面文件时显示图片，否则使用书名和作者生成的默认封面。`onTap`、`onLongPress` 可选；书架通过 `showProgress: true` 和 `markers` 保留原有进度与便签展示。

### Dart 内置目录

书籍目录和标签全部由主仓库维护，reader 只提供模型和查询接口（完整示例见 `example/lib/catalog.dart`）。在主仓库维护 `lib/pages/books/catalog.dart`：

```dart
import 'package:reader/reader.dart';

abstract final class AppBookTags {
  static const classic = CatalogTag(name: '经典', color: '#7C3AED');
  static const fortune = CatalogTag(name: '命理', color: '#2563EB');
  static const ancient = CatalogTag(name: '古籍', color: '#9C8F7D');
  // 新增标签只需在主仓库继续定义常量。
  static const history = CatalogTag(name: '历史', color: '#57715D');
}

const catalog = BookCatalog(books: [
  CatalogBook(
    assetPath: 'assets/books/紫微斗數全書卷一.txt',
    tags: [AppBookTags.classic, AppBookTags.fortune, AppBookTags.ancient],
  ),
]);

// 与 bookshelfRepositoryProvider 一起注入根作用域。
readerCatalogProvider.overrideWithValue(catalog)
```

图书资源仍需在宿主 `pubspec.yaml` 声明。通过 `readerCatalogProvider` 注入 Dart 清单；不注入时不导入任何内置资源。模块不再读取 `catalog.json` 或扫描资源目录。主仓库已迁移为 `lib/pages/books/catalog.dart`，并在根 ProviderContainer 注入。目录同步会保留阅读进度和笔记，已移除的内置书籍不会自动恢复。

以后新增书籍，只需在主仓库加入资源文件并将 `CatalogBook` 加入清单；新增标签，只需在主仓库定义新的 `CatalogTag` 常量并在对应书籍的 `tags` 中引用。目录与查询页面都导入这一个文件，不需要修改 reader。新增资源目录仍需在主仓库 `pubspec.yaml` 声明；如果已有 `assets/books/` 声明，往该目录增加文件无需逐一登记。

标签名称是唯一标识，与现有 SQLite 标签关系兼容。同名常量视为同一标签；名称不能为空或带首尾空白，同名标签的颜色声明须一致，重复书籍资源路径也会在导入前报错。改标签显示名称视为更换标签，需同时更新主仓库中共用的常量；下次启动会同步新关系。

若不使用 Riverpod，可创建 `ReaderLibrary(repository: repository, catalog: catalog)` 并调用相同方法。一个仓库复用一个实例；`initialize()` 可在启动时调用，同一实例的并发初始化共享任务，失败后可重试。修改目录后重新启动应用即可同步。

## 文件与安全边界

单个图书限制为 50 MB；EPUB 最多 10,000 个资源，声明的解压内容限制为 150 MB。解析在后台 isolate 中进行。EPUB 会移除脚本、嵌入式框架、外部链接与外部资源引用，不执行书内代码。

当前版本将普通 EPUB/TXT 副本及书签、划线、评论保存在应用沙盒中。它不提供 DRM、图书加密、密钥授权、账号或云同步。未来接入加密内容时，应通过 `BookContent` 接口按章提供已解密内容，避免将整本明文写入磁盘。

本模块不是完整的 EPUB 排版引擎：不支持复杂外部 CSS、固定版式、音视频、DRM；SVG 图片可能无法显示。默认文本阅读不会呈现原书图片和富文本样式，请使用“图文阅读”查看。TXT 需要 UTF-8 编码，GBK/UTF-16 文件应先转换。

## 独立演示

演示工程在 `example/`。首次打开会安装一份原创示例文本。

```sh
cd /Users/bo/Documents/blindness/reader/example
flutter pub get
flutter run
```

Android 示例使用 `com.example.reader_example`，不会覆盖主应用。

## 开发与验证

```sh
cd /Users/bo/Documents/blindness/reader
flutter pub get
flutter analyze
flutter test
```

测试覆盖 EPUB/TXT 解析、无效文件、路径限制、去重、重启后的进度和设置、书架筛选、阅读位置恢复及阅读器设置。

模块要求 Dart `>=3.10.0 <4.0.0`，并使用 Flutter、Riverpod 和 SQLite。当前主应用使用 `reader: path: ../reader` 引入该模块。

## 可替换阅读数据源

默认 `ReaderView(book: book)` 使用 `RepositoryBookSource`。外部章节数据可以直接实现三方库的 `BookSource`，保持一个稳定实例传入：

```dart
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;

// remoteSource 是宿主实现的 engine.BookSource 实例。
final controller = engine.BookReaderController();

ReaderView(book: shelfBook, source: remoteSource, controller: controller);
```

数据源需要实现 `loadManifest()` 和 `loadChapterBody(int index)`，正文用换行分段。`BookReaderController` 可控制翻页、切章和自动阅读。宿主更换书籍或数据源时应使用新的 Widget key。自定义源的进度按引擎字符坐标保存；本地源额外做段落与缩进转换。图文入口仅适用于默认本地源。

`BookContent` 仍可使用内存章节；大型/远程内容实现 `OnDemandBookContent`，让 `chapters` 只返回元数据，通过 `loadChapter(index)` 读取正文。调用方统一使用 `content.readChapter(index)`，不要依赖缓存对象的 `chapters[i].blocks` 已经加载。

数据库当前为 v8。升级会保留原书架、阅读进度、设置和 `reader_notes` payload，并回填用于书架聚合、摘录搜索与排序的查询列和索引。章节缓存仍为 v2，原始图书副本仍保留。

正文支持长按划线、评论、复制、浏览器查询（百度）和系统文字分享。评论输入层保存后刷新段尾角标，点击角标可查看和删除段评；目录中的笔记支持查看、定位和删除。书签、划线、评论均存入本地 `reader.sqlite`，重开阅读器后恢复，移除图书时一起清理。写入失败保留当前会话的数据并显示重试入口；评论输入框保留草稿。首次读取失败会显示打开失败，避免用空数据覆盖已有笔记。

自定义 `BookshelfRepository` 需实现 `loadNotes` / `saveNotes`，后者按书籍和 `ReaderNoteKind` 原子替换列表。若同时实现可选的 `BookshelfInsightsRepository`，书架会使用批量聚合、实时摘录流与精确单条删除；未实现时自动回退到基础仓库接口。自定义章节源也使用书架 `book.id` 保存笔记，需保证书籍 ID、章节顺序及正文稳定。锚点使用引擎字符坐标，当前固定首行缩进为 2；字号和翻页模式变化不会改变坐标。连续滚动模式的选区限于单段，图文阅读暂不提供这些批注交互。

自动阅读没有接入屏幕常亮插件。Android 系统版本/宿主 target SDK 可能限制隐藏系统栏，沉浸模式需在宿主真机验证。新增原生插件后需完整重启宿主应用，热重载无法注册分享和浏览器插件。

### 阅读引擎维护

`third_party/flutter_book_reader` 是 1.5.13 的项目内 MIT 许可副本，保留原始许可证。已修补连续滚动的章内位置恢复/更新、加载后可见位置保持，以及控制器释放后的异步通知。升级时请对照 `LOCAL_CHANGES.md` 合并；不要直接修改全局 pub 缓存。连续滚动支持段内选中和批注，付费内容与章节附加组件尚不在此分支的支持范围内。

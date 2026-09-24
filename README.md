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

- 书架展示、书名/作者筛选、阅读进度与移除确认。
- 多选导入本地 EPUB 和 UTF-8 TXT 文件。
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
)
```

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

### 内置书籍标签

演示应用使用 `example/assets/catalog.json` 管理内置书籍的默认标签。配置文件只负责声明资源和标签，应用启动时会将关系同步到本地 SQLite；用户界面目前只提供标签筛选，不提供标签编辑。

```json
{
  "version": 1,
  "tags": {
    "小说": { "color": "#D97706" }
  },
  "books": [
    {
      "file": "百年孤独.epub",
      "tags": ["小说"]
    }
  ]
}
```

`file` 相对于 `assets/books/`，标签名称必须出现在对应书籍的 `tags` 数组中。修改清单后重新构建应用即可同步默认关系；阅读进度和笔记不会受到影响。

## 文件与安全边界

单个图书限制为 50 MB；EPUB 最多 10,000 个资源，声明的解压内容限制为 150 MB。解析在后台 isolate 中进行。EPUB 会移除脚本、嵌入式框架、外部链接与外部资源引用，不执行书内代码。

当前版本将普通 EPUB/TXT 副本保存在应用沙盒中。它不提供 DRM、图书加密、密钥授权、下载、同步、书签、笔记或高亮功能。未来接入加密内容时，应通过 `BookContent` 接口按章提供已解密内容，避免将整本明文写入磁盘。

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

数据库升级至 v5，保留原书架、阅读进度和设置，新增 `reader_notes` 表，按书籍 ID、笔记类型及锚点保存书签、划线和评论。章节缓存仍为 v2，原始图书副本仍保留。

正文支持长按划线、评论、复制、浏览器查询（百度）和系统文字分享。评论输入层保存后刷新段尾角标，点击角标可查看和删除段评；目录中的笔记支持查看、定位和删除。书签、划线、评论均存入本地 `reader.sqlite`，重开阅读器后恢复，移除图书时一起清理。写入失败保留当前会话的数据并显示重试入口；评论输入框保留草稿。首次读取失败会显示打开失败，避免用空数据覆盖已有笔记。

自定义 `BookshelfRepository` 需实现 `loadNotes` / `saveNotes`，后者按书籍和 `ReaderNoteKind` 原子替换列表。自定义章节源也使用书架 `book.id` 保存笔记，需保证书籍 ID、章节顺序及正文稳定。锚点使用引擎字符坐标，当前固定首行缩进为 2；字号和翻页模式变化不会改变坐标。连续滚动模式的选区限于单段，图文阅读暂不提供这些批注交互。

自动阅读没有接入屏幕常亮插件。Android 系统版本/宿主 target SDK 可能限制隐藏系统栏，沉浸模式需在宿主真机验证。新增原生插件后需完整重启宿主应用，热重载无法注册分享和浏览器插件。

### 阅读引擎维护

`third_party/flutter_book_reader` 是 1.5.13 的项目内 MIT 许可副本，保留原始许可证。已修补连续滚动的章内位置恢复/更新、加载后可见位置保持，以及控制器释放后的异步通知。升级时请对照 `LOCAL_CHANGES.md` 合并；不要直接修改全局 pub 缓存。连续滚动支持段内选中和批注，付费内容与章节附加组件尚不在此分支的支持范围内。

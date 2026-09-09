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
- 目录、上下章节、字号 14–32、日间/夜间模式。
- 章节与内容块级阅读位置恢复；滚动停止 700ms、切章、退出及进入后台时保存。
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

## 文件与安全边界

单个图书限制为 50 MB；EPUB 最多 10,000 个资源，声明的解压内容限制为 150 MB。解析在后台 isolate 中进行。EPUB 会移除脚本、嵌入式框架、外部链接与外部资源引用，不执行书内代码。

当前版本将普通 EPUB/TXT 副本保存在应用沙盒中。它不提供 DRM、图书加密、密钥授权、下载、同步、书签、笔记或高亮功能。未来接入加密内容时，应通过 `BookContent` 接口按章提供已解密内容，避免将整本明文写入磁盘。

本模块不是完整的 EPUB 排版引擎：不支持复杂外部 CSS、固定版式、音视频、DRM、嵌套 TOC 和章节内锚点导航；SVG 图片可能无法显示。TXT 需要 UTF-8 编码，GBK/UTF-16 文件应先转换。

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

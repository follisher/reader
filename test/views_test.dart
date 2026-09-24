import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

final book = Book(
  id: 'demo',
  title: '山间阅读札记',
  author: '离线阅读示例',
  format: BookFormat.txt,
  source: BookSource.imported,
  fileName: 'demo.txt',
  addedAt: DateTime(2026),
  location: const ReadingLocation(chapter: 1, block: 8, progress: .6),
);

class FakeRepository implements BookshelfRepository {
  final notes = <String, List<Map<String, dynamic>>>{};
  @override
  Future<List<Map<String, dynamic>>> loadNotes(
    String bookId,
    ReaderNoteKind kind,
  ) async => List.of(notes['$bookId:${kind.name}'] ?? []);
  @override
  Future<void> saveNotes(
    String bookId,
    ReaderNoteKind kind,
    List<Map<String, dynamic>> value,
  ) async {
    notes['$bookId:${kind.name}'] = List.of(value);
  }

  final saves = <ReadingLocation>[];
  ReaderSettings settings = const ReaderSettings();
  bool failOpen = false;
  List<BookTocEntry>? toc;
  @override
  Stream<List<Book>> watchBooks() => Stream.value([book]);
  @override
  Future<BookContent> openBook(Book book) async {
    if (failOpen) throw const FormatException('图书文件不存在');
    return MemoryBookContent(
      title: book.title,
      author: book.author,
      toc: toc,
      chapters: List.generate(
        2,
        (chapter) => BookChapter(
          id: '$chapter',
          title: chapter == 0 ? '第一章 出发' : '第二章 山间',
          blocks: List.generate(
            20,
            (block) =>
                '<p>段落 $chapter-$block：山里的清晨很安静。沿着溪水向前走，阳光穿过树叶，在石阶上留下细碎的光影。停下脚步，翻开随身的书，慢慢读完这一页。</p>',
          ),
        ),
      ),
    );
  }

  @override
  Future<Book> importBytes(
    Uint8List bytes,
    String fileName, {
    BookSource source = BookSource.imported,
  }) async => book;
  @override
  Future<BookImportResult> importBytesWithResult(
    Uint8List bytes,
    String fileName, {
    BookSource source = BookSource.imported,
  }) async => BookImportResult(book: book, isDuplicate: false);
  @override
  Future<void> removeBook(String id) async {}
  @override
  Future<void> saveLocation(String id, ReadingLocation location) async {
    saves.add(location);
  }

  @override
  Future<ReaderSettings> loadSettings() async => settings;
  @override
  Future<void> saveSettings(ReaderSettings value) async {
    settings = value;
  }

  @override
  Future<void> syncCatalogTags(
    String bookId,
    Map<String, String?> tags,
  ) async {}
}

final boundary = GlobalKey();
Widget app(FakeRepository repo, Widget child) => ProviderScope(
  child: ProviderScope(
    overrides: [bookshelfRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(
      home: RepaintBoundary(key: boundary, child: child),
    ),
  ),
);
Future<void> capture(WidgetTester tester, String name) async {
  const output = String.fromEnvironment('READER_SCREENSHOTS');
  if (output.isEmpty) return;
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets('toc selects only current subsection and jumps to its block', (
    tester,
  ) async {
    final repo = FakeRepository()
      ..toc = const [
        BookTocEntry(
          id: 'root',
          title: '章目录',
          chapter: 1,
          block: 0,
          children: [
            BookTocEntry(id: 'a', title: '小节甲', chapter: 1, block: 0),
            BookTocEntry(id: 'b', title: '小节乙', chapter: 1, block: 7),
            BookTocEntry(id: 'c', title: '小节丙', chapter: 1, block: 14),
          ],
        ),
      ];
    await tester.pumpWidget(app(repo, HtmlReaderView(book: book)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    final selected = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .where((tile) => tile.selected);
    expect(selected.length, 1);
    expect((selected.single.title as Text).data, '小节乙');
    await tester.tap(find.text('小节丙'));
    await tester.pumpAndSettle();
    expect(repo.saves.last.chapter, 1);
    expect(repo.saves.last.block, 14);
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('章目录'));
    await tester.pumpAndSettle();
    expect(repo.saves.last.block, 0);
    expect(repo.saves.last.progress, .5);
    final heading = tester.getRect(find.text('第二章 山间'));
    final toolbar = tester.getRect(find.byType(AppBar));
    expect(heading.top, greaterThanOrEqualTo(toolbar.bottom + 12));
    expect(heading.bottom, lessThan(tester.view.physicalSize.height));
    await tester.tapAt(heading.center);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('第二章 山间')), heading);
    final list = find.byType(ScrollablePositionedList);
    expect(tester.getRect(list).top, 0);
    await tester.tapAt(heading.center);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('第二章 山间')), heading);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  setUpAll(() async {
    const fontPath = String.fromEnvironment('READER_PREVIEW_FONT');
    if (fontPath.isEmpty) return;
    final font = FontLoader('Ahem')
      ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
    await font.load();
    const iconPath = String.fromEnvironment('READER_PREVIEW_ICONS');
    if (iconPath.isNotEmpty) {
      await (FontLoader('MaterialIcons')
            ..addFont(File(iconPath).readAsBytes().then(ByteData.sublistView)))
          .load();
    }
  });
  testWidgets('shelf shows saved progress, search, and routes selected book', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = FakeRepository();
    Book? selected;
    await tester.pumpWidget(
      app(repo, BookshelfView(onBookTap: (book) => selected = book)),
    );
    await tester.pumpAndSettle();
    expect(find.text('已读 60%'), findsOneWidget);
    await capture(tester, 'bookshelf');
    await tester.tap(find.text(book.title));
    expect(selected?.id, book.id);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的图书'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'reader restores block, preserves it on font change, navigates and saves',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = FakeRepository();
      await tester.pumpWidget(app(repo, HtmlReaderView(book: book)));
      await tester.pumpAndSettle();
      expect(find.textContaining('段落 1-8', findRichText: true), findsWidgets);
      await capture(tester, 'reader');
      await tester.tap(find.byTooltip('放大字号'));
      await tester.pumpAndSettle();
      expect(repo.settings.fontSize, 22);
      expect(find.textContaining('段落 1-8', findRichText: true), findsWidgets);
      await tester.tap(find.byTooltip('夜间模式'));
      await tester.pumpAndSettle();
      expect(repo.settings.dark, isTrue);
      await capture(tester, 'reader-dark');
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('上一章'), findsOneWidget);
      expect(find.byTooltip('下一章'), findsOneWidget);
      await tester.tap(find.text('第一章 出发'));
      await tester.pumpAndSettle();
      expect(find.textContaining('段落 0-0', findRichText: true), findsWidgets);
      expect(repo.saves.last.chapter, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(repo.saves.last.chapter, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('reader displays recoverable file errors', (tester) async {
    final repo = FakeRepository()..failOpen = true;
    await tester.pumpWidget(app(repo, HtmlReaderView(book: book)));
    await tester.pumpAndSettle();
    expect(find.text('图书文件不存在'), findsOneWidget);
    repo.failOpen = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('段落 1-8', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

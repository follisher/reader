import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:reader/src/book_reader_adapter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'views_test.dart' show FakeRepository, app, book, capture;

class LazyContent extends MemoryBookContent implements OnDemandBookContent {
  LazyContent()
    : super(
        title: '按需加载',
        author: '',
        chapters: [
          for (var i = 0; i < 40; i++)
            BookChapter(id: '$i', title: '第 $i 章', blocks: const []),
        ],
      );
  final loaded = <int>[];
  @override
  Future<BookChapter> loadChapter(int index) async {
    loaded.add(index);
    return BookChapter(
      id: '$index',
      title: '第 $index 章',
      blocks: List.generate(
        40,
        (i) => '<p>第 $index 章段落 $i ${'阅读正文。' * 20}</p>',
      ),
    );
  }
}

class LazyRepository extends FakeRepository {
  final content = LazyContent();
  @override
  Future<BookContent> openBook(Book book) async => content;
}

void main() {
  setUpAll(() async {
    const fontPath = String.fromEnvironment('READER_PREVIEW_FONT');
    if (fontPath.isEmpty) return;
    final font = FontLoader('ReaderPreview')
      ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
    await font.load();
  });
  test(
    'source loads only requested chapters, deduplicates and bounds cache',
    () async {
      final repo = LazyRepository();
      final source = RepositoryBookSource(repo, book);
      expect((await source.loadManifest()).chapterCount, 40);
      expect(repo.content.loaded, isEmpty);
      await Future.wait([source.loadChapterBody(2), source.loadChapterBody(2)]);
      expect(repo.content.loaded, [2]);
      for (var i = 3; i < 12; i++) {
        await source.loadChapterBody(i);
      }
      await source.loadChapterBody(2);
      expect(repo.content.loaded.where((i) => i == 2).length, 2);
    },
  );

  test(
    'normalization retains paragraph boundaries and maps legacy positions',
    () {
      final text = TextChapter.fromChapter(
        const BookChapter(
          id: 'a',
          title: '标题',
          blocks: ['<p>甲&amp;乙<br>第二行</p>', '<div><p>段二</p><p>段三</p></div>'],
        ),
      );
      expect(text.paragraphs, ['甲&乙', '第二行', '段二', '段三']);
      expect(text.canonicalForBlock(1), 6);
      for (var i = 0; i < text.length; i++) {
        for (var indent = 0; indent <= 4; indent++) {
          expect(text.toCanonical(text.toEngine(i, indent), indent), i);
        }
      }
    },
  );

  test(
    'v3 database migration preserves shelf and persists new settings/offsets',
    () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('reader-migration-');
      final db = await databaseFactoryFfi.openDatabase(
        '${dir.path}/reader.sqlite',
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE books (id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL, format TEXT NOT NULL, source TEXT NOT NULL, file_name TEXT NOT NULL, cover_file_name TEXT, cover_checked INTEGER NOT NULL DEFAULT 0, cache_ready INTEGER NOT NULL DEFAULT 0, added_at INTEGER NOT NULL, chapter INTEGER NOT NULL DEFAULT 0, block INTEGER NOT NULL DEFAULT 0, progress REAL NOT NULL DEFAULT 0)',
            );
            await db.execute(
              'CREATE TABLE settings (id INTEGER PRIMARY KEY, font_size REAL NOT NULL, dark INTEGER NOT NULL)',
            );
            await db.insert('settings', {'id': 1, 'font_size': 24, 'dark': 1});
          },
        ),
      );
      await db.close();
      var repo = await LocalBookshelfRepository.create(
        directory: dir,
        factory: databaseFactoryFfi,
      );
      try {
        expect((await repo.loadSettings()).dark, isTrue);
        final imported = await repo.importBytes(
          utf8.encode('第一章 开始\n正文甲\n第二章 后续\n正文乙'),
          'demo.txt',
        );
        await repo.saveLocation(
          imported.id,
          const ReadingLocation(
            chapter: 1,
            block: 1,
            charOffset: 7,
            progress: .7,
          ),
        );
        await repo.saveSettings(
          const ReaderSettings(
            fontSize: 27,
            theme: 'green',
            flipMode: 'cover',
            lineHeight: 2,
            firstLineIndent: 3,
            paragraphSpacing: 16,
            justify: false,
            dimLevel: .2,
          ),
        );
        await repo.close();
        repo = await LocalBookshelfRepository.create(
          directory: dir,
          factory: databaseFactoryFfi,
        );
        final restored = (await repo.watchBooks().first).single;
        expect(restored.location.charOffset, 7);
        final settings = await repo.loadSettings();
        expect(settings.theme, 'green');
        expect(settings.flipMode, 'cover');
        expect(settings.firstLineIndent, 3);
        expect(settings.paragraphSpacing, 16);
        expect(settings.justify, isFalse);
        final content = await repo.openBook(restored);
        expect(content, isA<OnDemandBookContent>());
        expect(content.chapters.every((c) => c.blocks.isEmpty), isTrue);
        expect((await content.readChapter(1)).blocks.join(), contains('正文乙'));
        final manifest = jsonDecode(
          await File(
            '${dir.path}/cache/${restored.id}/content.json',
          ).readAsString(),
        );
        expect(manifest['version'], 2);
        expect(manifest['chapters'][0].containsKey('blocks'), isFalse);
      } finally {
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'new reader restores, paginates, persists config and auto turns',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = LazyRepository();
      final controller = engine.BookReaderController();
      await tester.pumpWidget(
        app(repo, ReaderView(book: book, controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(controller.position, isNotNull);
      expect(controller.chapterIndex, 1);
      expect(controller.position!.charOffset, greaterThan(0));
      final restoredParagraph = find.textContaining(
        '第 1 章段落 8',
        findRichText: true,
      );
      expect(restoredParagraph, findsWidgets);
      final restoredRect = tester.getRect(restoredParagraph.first);
      expect(restoredRect.top, lessThan(150));
      expect(restoredRect.bottom, greaterThan(30));
      expect(repo.content.loaded.length, lessThan(10));
      final reader = tester.widget<engine.BookReader>(
        find.byType(engine.BookReader),
      );
      if (const String.fromEnvironment('READER_PREVIEW_FONT').isNotEmpty) {
        reader.config!.setFontFamily('ReaderPreview');
        await tester.pumpAndSettle();
      }
      expect(reader.config!.flipType, engine.FlipType.scrollVertical);
      await capture(tester, 'reader-new-scroll');
      repo.saves.clear();
      await tester.drag(find.byType(engine.BookReader), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 450));
      expect(repo.saves, isNotEmpty);
      expect(controller.chapterIndex, 1);
      expect(repo.saves.last.charOffset, isNotNull);
      reader.config!
        ..setFlipType(engine.FlipType.slideHorizontal)
        ..setTheme(engine.ReaderTheme.green)
        ..setLineHeight(2);
      await tester.pumpAndSettle();
      expect(controller.isReady, isTrue);
      expect(controller.pageCount, greaterThan(1));
      expect(repo.settings.theme, 'green');
      expect(repo.settings.flipMode, 'slideHorizontal');
      await capture(tester, 'reader-new-paged');
      final before = controller.pageIndex;
      controller.startAutoTurn(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.pageIndex, greaterThan(before));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(controller.isAutoTurning, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(repo.saves.last.charOffset, isNotNull);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );
  testWidgets(
    'vertical reader keeps anchor on reflow and crosses chapters in both directions',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = LazyRepository();
      final controller = engine.BookReaderController();
      await tester.pumpWidget(
        app(repo, ReaderView(book: book, controller: controller)),
      );
      await tester.pumpAndSettle();
      final offset = controller.position!.charOffset;
      final reader = tester.widget<engine.BookReader>(
        find.byType(engine.BookReader),
      );
      reader.config!.increaseFont();
      await tester.pumpAndSettle();
      expect(controller.chapterIndex, 1);
      expect(controller.position!.charOffset, offset);
      controller.goToChapter(10);
      await tester.pumpAndSettle();
      expect(controller.chapterIndex, 10);
      expect(controller.position!.charOffset, 0);
      await tester.drag(find.byType(engine.BookReader), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(controller.chapterIndex, 9);
      await tester.drag(find.byType(engine.BookReader), const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(controller.chapterIndex, 10);
      final beforeAuto = controller.position!.charOffset;
      controller.startAutoTurn(const Duration(seconds: 2));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      controller.stopAutoTurn();
      await tester.pumpAndSettle();
      expect(controller.position!.charOffset, greaterThan(beforeAuto));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );
}

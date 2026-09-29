import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_book_reader/src/controller/reading_controller.dart';
import 'package:flutter_book_reader/src/views/vertical_reader.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
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
  test('first-use reader defaults are white and medium speed', () {
    expect(const ReaderSettings().theme, 'white');
    final config = engine.ReaderConfig();
    expect(config.theme.alias, 'white');
    expect(
      engine.BookReaderController().autoTurnInterval,
      const Duration(milliseconds: 32500),
    );
    config.dispose();
  });

  test(
    'reader, persisted shelf, and restore share character progress',
    () async {
      final repo = LazyRepository();
      final source = RepositoryBookSource(repo, book);
      final manifest = await source.loadManifest();
      final config = engine.ReaderConfig();
      final controller = ReadingController(
        source: source,
        manifest: manifest,
        config: config,
        startChapter: 10,
      );
      await controller.ensureLoaded(10);
      final text = await source.textChapter(10);
      final canonicalOffset = text.length ~/ 2;
      final engineOffset = text.toEngine(
        canonicalOffset,
        config.firstLineIndent,
      );
      controller.charOffset = engineOffset;
      final expected = (10 + canonicalOffset / text.length) / 40;
      expect(controller.globalProgress, closeTo(expected, 1e-9));

      final store = RepositoryProgressStore(
        repository: repo,
        book: book,
        source: source,
        config: config,
        manifest: manifest,
        canSave: () => true,
        onError: (error) => expect(error, isNull),
      );
      await store.save(book.id, controller.position);
      final saved = repo.saves.single;
      expect(saved.progress, closeTo(controller.globalProgress, 1e-9));

      final restoredBook = Book(
        id: book.id,
        title: book.title,
        author: book.author,
        format: book.format,
        source: book.source,
        fileName: book.fileName,
        addedAt: book.addedAt,
        location: saved,
      );
      final restoredSource = RepositoryBookSource(repo, restoredBook);
      final restoredStore = RepositoryProgressStore(
        repository: repo,
        book: restoredBook,
        source: restoredSource,
        config: config,
        manifest: manifest,
        canSave: () => true,
        onError: (error) => expect(error, isNull),
      );
      final restored = await restoredStore.load(book.id);
      expect(restored?.chapterIndex, 10);
      expect(restored?.charOffset, engineOffset);

      controller.dispose();
      config.dispose();
    },
  );

  test(
    'fresh database uses the white theme without changing legacy rows',
    () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('reader-defaults-');
      final repo = await LocalBookshelfRepository.create(
        directory: dir,
        factory: databaseFactoryFfi,
      );
      try {
        expect((await repo.loadSettings()).theme, 'white');
      } finally {
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets('loading an earlier chapter keeps the active drag stable', (
    tester,
  ) async {
    final repo = LazyRepository();
    final source = RepositoryBookSource(repo, book);
    final config = engine.ReaderConfig();
    final controller = ReadingController(
      source: source,
      manifest: await source.loadManifest(),
      config: config,
      startChapter: 10,
    );
    await tester.runAsync(() => controller.ensureLoaded(10));
    var scrollStarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (context, _) =>
                NotificationListener<ScrollStartNotification>(
                  onNotification: (_) {
                    scrollStarts++;
                    return false;
                  },
                  child: VerticalReader(
                    controller: controller,
                    onTapToggleMenu: () {},
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final listFinder = find.byType(ScrollablePositionedList);
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    final count = tester.widget<ScrollablePositionedList>(listFinder).itemCount;
    final paragraph = find
        .textContaining('第 10 章段落 1', findRichText: true)
        .first;
    final before = tester.getRect(paragraph);
    await tester.runAsync(() => controller.ensureLoaded(0));
    await tester.pump();
    expect(
      tester.widget<ScrollablePositionedList>(listFinder).itemCount,
      count,
    );
    expect(tester.getRect(paragraph), before);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.chapterIndex, 10);
    expect(tester.getRect(paragraph).top, closeTo(before.top, 1));
    var notifications = 0;
    void countNotification() => notifications++;
    controller.addListener(countNotification);
    final offsetBeforeFling = controller.charOffset;
    await tester.fling(listFinder, const Offset(0, -450), 2500);
    var lastOffset = controller.charOffset;
    var anchorChanges = 0;
    for (var frame = 0; frame < 20; frame++) {
      if (frame == 3) {
        // A prefetch completion must not be mistaken for an external seek.
        await tester.runAsync(() => controller.ensureLoaded(2));
      }
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.charOffset, greaterThanOrEqualTo(lastOffset));
      if (controller.charOffset != lastOffset) anchorChanges++;
      lastOffset = controller.charOffset;
    }
    expect(anchorChanges, lessThanOrEqualTo(6));
    await tester.pumpAndSettle();
    expect(controller.charOffset, greaterThan(offsetBeforeFling));
    expect(notifications, lessThan(5));
    controller.removeListener(countNotification);

    // Reverse direction without lifting the finger while a chapter loads.
    // The underlying list must keep its indices until the gesture and the
    // subsequent ballistic motion are both finished.
    final countBeforeReverse = tester
        .widget<ScrollablePositionedList>(listFinder)
        .itemCount;
    final reverse = await tester.startGesture(tester.getCenter(listFinder));
    await reverse.moveBy(const Offset(0, -140));
    await tester.pump();
    await tester.runAsync(() => controller.ensureLoaded(1));
    await tester.pump();
    await reverse.moveBy(const Offset(0, 110));
    await tester.pump();
    expect(
      tester.widget<ScrollablePositionedList>(listFinder).itemCount,
      countBeforeReverse,
    );
    await reverse.up();
    await tester.pump(const Duration(milliseconds: 16));

    // A fresh touch must invalidate the prior fling's queued end callback.
    await tester.fling(listFinder, const Offset(0, -500), 3200);
    await tester.pump(const Duration(milliseconds: 16));
    final interrupt = await tester.startGesture(tester.getCenter(listFinder));
    await interrupt.moveBy(const Offset(0, 90));
    await tester.pump();
    expect(
      tester.widget<ScrollablePositionedList>(listFinder).itemCount,
      countBeforeReverse,
    );
    await interrupt.up();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ScrollablePositionedList>(listFinder).itemCount,
      greaterThan(countBeforeReverse),
    );

    scrollStarts = 0;
    ItemPosition firstVisible() => tester
        .widget<ScrollablePositionedList>(listFinder)
        .itemPositionsNotifier!
        .itemPositions
        .value
        .where(
          (position) =>
              position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1,
        )
        .reduce((a, b) => a.index < b.index ? a : b);
    final beforeAuto = firstVisible();
    controller.setAutoTurnInterval(const Duration(seconds: 1));
    controller.setAutoTurning(true);
    for (var frame = 0; frame < 35; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (frame == 5) {
        final countBeforeLookahead = tester
            .widget<ScrollablePositionedList>(listFinder)
            .itemCount;
        await tester.runAsync(() => controller.ensureLoaded(13));
        await tester.pump();
        expect(
          tester.widget<ScrollablePositionedList>(listFinder).itemCount,
          greaterThan(countBeforeLookahead),
        );
      }
    }
    final afterAuto = firstVisible();
    expect(
      afterAuto.index > beforeAuto.index ||
          afterAuto.itemLeadingEdge < beforeAuto.itemLeadingEdge - .01,
      isTrue,
    );
    for (var frame = 0; frame < 100; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Even at the fastest speed there should be no 1-second animation seam.
    expect(scrollStarts, lessThanOrEqualTo(1));
    controller.setAutoTurning(false);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    // The speed-slider's fastest setting should not restart the scroll every
    // three seconds; that small seam is conspicuous during slow reading.
    controller.setAutoTurnInterval(const Duration(seconds: 15));
    scrollStarts = 0;
    controller.setAutoTurning(true);
    for (var frame = 0; frame < 225; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scrollStarts, lessThanOrEqualTo(1));
    controller.setAutoTurning(false);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    config.dispose();
  });

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
        expect((await repo.loadSettings()).theme, 'yellow');
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
      expect(controller.autoTurnInterval, const Duration(milliseconds: 32500));
      expect(repo.settings.theme, 'white');
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
  testWidgets('menu progress slider seeks within the whole book', (
    tester,
  ) async {
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

    await tester.tapAt(const Offset(195, 422));
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    final rect = tester.getRect(slider);
    final gesture = await tester.startGesture(
      Offset(rect.left + rect.width * .04, rect.center.dy),
    );
    await gesture.moveTo(Offset(rect.left + rect.width * .26, rect.center.dy));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('reader-seek-preview')),
      findsOneWidget,
    );
    final previewTexts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('reader-seek-preview')),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    expect(previewTexts.first, contains('/'));
    final totalPages = int.parse(previewTexts.first.split('/').last.trim());
    expect(totalPages, greaterThan(repo.content.chapters.length));
    expect(previewTexts.last, ' ');
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('reader-seek-preview')),
      findsNothing,
    );
    expect(controller.chapterIndex, greaterThan(1));
    expect(controller.position!.charOffset, greaterThan(0));
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('auto-read speed sheet pauses and resumes after dismissal', (
    tester,
  ) async {
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

    controller.startAutoTurn(const Duration(seconds: 6));
    await tester.pump();
    expect(controller.isAutoTurning, isTrue);
    await tester.tap(find.byKey(const ValueKey('auto-read-settings-entry')));
    await tester.pump();
    expect(controller.isAutoTurning, isFalse);
    await tester.pumpAndSettle();
    final originalSpeed = controller.autoTurnInterval;
    await tester.drag(find.byType(Slider).last, const Offset(65, 0));
    await tester.pump();
    expect(controller.autoTurnInterval, isNot(originalSpeed));
    expect(controller.isAutoTurning, isFalse);

    await tester.tapAt(const Offset(10, 80));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.isAutoTurning, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.isAutoTurning, isTrue);

    await tester.tap(find.byKey(const ValueKey('auto-read-settings-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出自动阅读'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.isAutoTurning, isFalse);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('reader menu pauses vertical auto-read until settings settle', (
    tester,
  ) async {
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

    controller.startAutoTurn(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle();
    expect(controller.isAutoTurning, isTrue);
    final pausedOffset = controller.position!.charOffset;
    await tester.pump(const Duration(seconds: 2));
    expect(controller.position!.charOffset, pausedOffset);

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    final reader = tester.widget<engine.BookReader>(
      find.byType(engine.BookReader),
    );
    final originalFont = reader.config!.fontSize;
    await tester.tap(find.text('A+'));
    await tester.pumpAndSettle();
    expect(reader.config!.fontSize, greaterThan(originalFont));
    final reflowedOffset = controller.position!.charOffset;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.position!.charOffset, reflowedOffset);

    await tester.tapAt(const Offset(195, 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.position!.charOffset, reflowedOffset);
    for (var frame = 0; frame < 75; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.position!.charOffset, greaterThan(reflowedOffset));

    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle();
    expect(controller.isAutoTurning, isTrue);
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止自动阅读'));
    await tester.pump();
    expect(controller.isAutoTurning, isFalse);
    await tester.tapAt(const Offset(195, 250));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.isAutoTurning, isFalse);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('catalog keeps auto-read paused until dismissal or navigation', (
    tester,
  ) async {
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

    controller.startAutoTurn(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录').last);
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(controller.isAutoTurning, isTrue);
    final pausedOffset = controller.position!.charOffset;
    await tester.pump(const Duration(seconds: 2));
    expect(controller.position!.charOffset, pausedOffset);

    await tester.tapAt(const Offset(15, 30));
    await tester.pump();
    for (var frame = 0; frame < 80; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.position!.charOffset, greaterThan(pausedOffset));

    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 0 章').last);
    await tester.pump();
    expect(controller.chapterIndex, 0);
    expect(controller.isAutoTurning, isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}

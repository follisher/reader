import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:reader/reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'views_test.dart' show FakeRepository, app, capture;

Book _book(String id, BookCollection collection, String tag) => Book(
  id: id,
  title: id,
  author: '',
  format: BookFormat.txt,
  source: collection == BookCollection.personal
      ? BookSource.imported
      : BookSource.builtIn,
  collection: collection,
  fileName: '$id.txt',
  addedAt: DateTime(2026),
  tags: tag.isEmpty ? const [] : [BookTag(id: 1, name: tag)],
);

class _MetadataRepository extends FakeRepository
    implements BookshelfMetadataRepository {
  Map<String, String?>? savedTags;
  final importedNames = <String>[];
  final tagsByBook = <String, Map<String, String?>>{};
  Book? duplicateBook;
  Future<void>? importBarrier;
  Object? importError;
  @override
  Future<BookImportResult> importBytesWithResult(
    Uint8List bytes,
    String fileName, {
    BookSource source = BookSource.imported,
  }) async {
    importedNames.add(fileName);
    await importBarrier;
    if (importError != null) throw importError!;
    if (duplicateBook != null) {
      return BookImportResult(book: duplicateBook!, isDuplicate: true);
    }
    final book = _book(fileName, BookCollection.personal, '');
    books = [...books, book];
    return BookImportResult(book: book, isDuplicate: false);
  }

  @override
  Future<void> setBookTags(String bookId, Map<String, String?> tags) async {
    savedTags = tags;
    tagsByBook[bookId] = Map.of(tags);
  }

  @override
  Future<void> setBookCollection(
    String bookId,
    BookCollection collection,
  ) async {}
}

void main() {
  setUpAll(() async {
    const fontPath = String.fromEnvironment('READER_PREVIEW_FONT');
    if (fontPath.isEmpty) return;
    final bytes = ByteData.sublistView(await File(fontPath).readAsBytes());
    await (FontLoader('packages/forui_lucide/ForuiLucideIcons')
          ..addFont(rootBundle.load('packages/forui_lucide/assets/lucide.ttf')))
        .load();
    for (final name in ['ReaderPreview', 'Songti TC']) {
      await (FontLoader(name)..addFont(Future.value(bytes))).load();
    }
    const iconPath = String.fromEnvironment('READER_PREVIEW_ICONS');
    if (iconPath.isNotEmpty) {
      await (FontLoader('MaterialIcons')
            ..addFont(File(iconPath).readAsBytes().then(ByteData.sublistView)))
          .load();
    }
  });
  testWidgets(
    'collections only expose their own books and populated categories',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = FakeRepository()
        ..books = [
          _book('古籍书', BookCollection.ancient, '经部'),
          _book('当代书', BookCollection.contemporary, '小说'),
          _book('私藏书', BookCollection.personal, '笔记'),
        ];
      const previewFont = String.fromEnvironment('READER_PREVIEW_FONT');
      await tester.pumpWidget(
        app(
          repo,
          Theme(
            data: ThemeData(
              fontFamily: previewFont.isEmpty ? null : 'ReaderPreview',
            ),
            child: BookshelfView(onBookTap: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '经部'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '小说'), findsNothing);
      expect(find.byKey(const ValueKey('bookshelf-import-card')), findsNothing);
      expect(
        find.byKey(const ValueKey('bookshelf-category-import-经部')),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '经部'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('bookshelf-collection-contemporary')),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '小说'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('bookshelf-category-title-小说')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('古籍书')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('bookshelf-collection-personal')),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '笔记'), findsOneWidget);
      expect(find.byKey(const ValueKey('私藏书')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('bookshelf-import-card'))),
        tester.getSize(find.byType(RepositoryBookCover)),
      );
      expect(tester.takeException(), isNull);
      await capture(tester, 'personal-collection');
    },
  );

  testWidgets(
    'empty personal shelf opens the system picker with supported formats',
    (tester) async {
      MethodCall? pickerCall;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        pickerCall = call;
        return <String>[];
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        app(FakeRepository()..books = [], BookshelfView(onBookTap: (_) {})),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('EPUB / PDF\nTXT / MD'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bookshelf-import-card')));
      await tester.pumpAndSettle();
      expect(pickerCall?.method, 'openFile');
      final args = pickerCall!.arguments as Map;
      expect(args['multiple'], true);
      expect((args['acceptedTypeGroups'] as List).single['extensions'], [
        'txt',
        'epub',
        'md',
        'pdf',
      ]);
      expect(find.text('正在导入图书…'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected files inherit the active category and accept additional labels',
    (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('reader_picker_'),
      );
      final file = File('${directory!.path}/new.txt');
      await tester.runAsync(() => file.writeAsString('第一章\n测试内容'));
      addTearDown(() => directory.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => [file.path],
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final repo = _MetadataRepository()
        ..books = [_book('已藏书', BookCollection.personal, '文学')];
      await tester.pumpWidget(app(repo, BookshelfView(onBookTap: (_) {})));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '文学'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('bookshelf-import-card')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(repo.importedNames, ['new.txt']);
      expect(repo.savedTags?.keys, ['文学']);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '文学'))
            .selected,
        true,
      );
      await tester.enterText(
        find.byKey(const ValueKey('book-tag-input')),
        '随笔，历史',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('保存分类'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(repo.savedTags?.keys.toSet(), {'文学', '随笔', '历史'});
      expect(find.text('正在导入图书…'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final tag in ['文学', '未分类']) {
    testWidgets('category row imports multiple files directly into $tag', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('reader_category_import_'),
      );
      final files = [
        File('${directory!.path}/one.txt'),
        File('${directory.path}/two.md'),
      ];
      await tester.runAsync(() async {
        for (final file in files) {
          await file.writeAsString('正文：${file.uri.pathSegments.last}');
        }
      });
      addTearDown(() => directory.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => files.map((file) => file.path).toList(),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final repo = _MetadataRepository()
        ..books = [
          _book('已有图书', BookCollection.personal, tag == '未分类' ? '' : tag),
        ];
      await tester.pumpWidget(app(repo, BookshelfView(onBookTap: (_) {})));
      await tester.pumpAndSettle();
      final button = find.byKey(ValueKey('bookshelf-category-import-$tag'));
      expect(button, findsOneWidget);
      final bookRect = tester.getRect(find.byType(RepositoryBookCover));
      final buttonRect = tester.getRect(button);
      expect(buttonRect.top, bookRect.top);
      expect(buttonRect.left - bookRect.right, closeTo(12, .001));
      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(repo.importedNames, ['one.txt', 'two.md']);
      if (tag == '未分类') {
        expect(repo.tagsByBook, isEmpty);
      } else {
        expect(repo.tagsByBook['one.txt']?.keys, [tag]);
        expect(repo.tagsByBook['two.md']?.keys, [tag]);
      }
      expect(find.byKey(const ValueKey('book-tag-input')), findsNothing);
      expect(find.text('正在导入图书…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'repository duplicate guard cancels category assignment without modifying the book',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('reader_category_duplicate_'),
      );
      final file = File('${directory!.path}/duplicate.txt');
      await tester.runAsync(() => file.writeAsString('正文'));
      addTearDown(() => directory.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => [file.path],
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final duplicate = _book('已藏书', BookCollection.personal, '历史');
      final repo = _MetadataRepository()
        ..duplicateBook = duplicate
        ..books = [duplicate, _book('分类图书', BookCollection.personal, '文学')];
      await tester.pumpWidget(app(repo, BookshelfView(onBookTap: (_) {})));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('bookshelf-category-import-文学'));
      await tester.ensureVisible(button);
      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(repo.tagsByBook, isEmpty);
      expect(repo.books, hasLength(2));
      expect(find.textContaining('已取消导入'), findsWidgets);
      expect(repo.saves, isEmpty);
      expect(find.byKey(const ValueKey('book-tag-input')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final collection in [BookCollection.personal, BookCollection.ancient]) {
    for (final fromCategory in [false, true]) {
      testWidgets(
        'renamed book already in ${collection.label} skips tags from ${fromCategory ? 'category' : 'global'} entry',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final bytes = Uint8List.fromList(utf8.encode('已经在书库里的同一本书'));
          final directory = await tester.runAsync(
            () =>
                Directory.systemTemp.createTemp('reader_duplicate_preflight_'),
          );
          final file = File('${directory!.path}/改名后的图书.txt');
          await tester.runAsync(() => file.writeAsBytes(bytes));
          addTearDown(() => directory.delete(recursive: true));
          const channel = MethodChannel('plugins.flutter.io/file_selector');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (_) async => [file.path],
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          final original = Book(
            id: sha256.convert(bytes).toString(),
            title: '已藏图书',
            author: '',
            format: BookFormat.txt,
            source: collection == BookCollection.personal
                ? BookSource.imported
                : BookSource.builtIn,
            collection: collection,
            fileName: '原文件名.txt',
            addedAt: DateTime(2026),
            tags: const [BookTag(id: 1, name: '历史')],
            location: const ReadingLocation(progress: .6, charOffset: 12),
          );
          final repo = _MetadataRepository()
            ..books = [original, _book('分类图书', BookCollection.personal, '文学')];
          await tester.pumpWidget(app(repo, BookshelfView(onBookTap: (_) {})));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('bookshelf-collection-personal')),
          );
          await tester.pumpAndSettle();
          final button = fromCategory
              ? find.byKey(const ValueKey('bookshelf-category-import-文学'))
              : find.byKey(const ValueKey('bookshelf-import-card'));
          await tester.ensureVisible(button);
          await tester.runAsync(() async {
            await tester.tap(button);
            await Future<void>.delayed(const Duration(milliseconds: 150));
          });
          await tester.pumpAndSettle();
          expect(repo.importedNames, isEmpty);
          expect(repo.tagsByBook, isEmpty);
          expect(repo.saves, isEmpty);
          expect(repo.books.first.location.progress, .6);
          expect(repo.books.first.tags.single.name, '历史');
          expect(find.byKey(const ValueKey('book-tag-input')), findsNothing);
          expect(find.textContaining('已取消导入'), findsWidgets);
          expect(
            find.textContaining('已在“${collection.label}”中'),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: button,
              matching: find.byIcon(Icons.info_outline),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'a repeated file in a batch is skipped while distinct books still import',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('reader_batch_duplicates_'),
      );
      final files = [
        File('${directory!.path}/one.txt'),
        File('${directory.path}/copy.md'),
        File('${directory.path}/different.txt'),
      ];
      await tester.runAsync(() async {
        await files[0].writeAsString('同一本图书正文');
        await files[1].writeAsString('同一本图书正文');
        await files[2].writeAsString('另一本图书的正文');
      });
      addTearDown(() => directory.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => files.map((file) => file.path).toList(),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final repo = _MetadataRepository()
        ..books = [_book('seed', BookCollection.personal, '文学')];
      await tester.pumpWidget(app(repo, BookshelfView(onBookTap: (_) {})));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const ValueKey('bookshelf-category-import-文学')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(repo.importedNames, ['one.txt', 'different.txt']);
      expect(repo.books, hasLength(3));
      expect(repo.tagsByBook.keys.toSet(), {'one.txt', 'different.txt'});
      expect(find.textContaining('已添加 2 本'), findsOneWidget);
      expect(find.textContaining('跳过 1 本'), findsOneWidget);
      expect(find.textContaining('已取消导入'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-tag-input')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final fail in [false, true]) {
    testWidgets(
      'active import card shows progress and ${fail ? 'retry' : 'completion'} in place',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final directory = await tester.runAsync(
          () => Directory.systemTemp.createTemp('reader_import_feedback_'),
        );
        final file = File('${directory!.path}/new.txt');
        await tester.runAsync(() => file.writeAsString('正文'));
        addTearDown(() => directory.delete(recursive: true));
        final picker = Completer<List<String>>();
        final importing = Completer<void>();
        const channel = MethodChannel('plugins.flutter.io/file_selector');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) => picker.future,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final repo = _MetadataRepository()
          ..books = [_book('已有图书', BookCollection.personal, '文学')]
          ..importBarrier = importing.future
          ..importError = fail ? const FormatException('文件无法读取') : null;
        await tester.pumpWidget(app(repo, BookshelfView(onBookTap: (_) {})));
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('bookshelf-category-import-文学'));
        final mainCard = find.byKey(const ValueKey('bookshelf-import-card'));
        final originalRect = tester.getRect(card);
        await tester.runAsync(() => tester.tap(card));
        await tester.pump();
        expect(
          find.descendant(of: card, matching: find.text('选择文件')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.text('+')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: card,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: mainCard, matching: find.text('+')),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          picker.complete([file.path]);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.descendant(of: card, matching: find.text('正在导入')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.text('1 / 1 本')),
          findsOneWidget,
        );
        expect(find.text('正在导入图书…'), findsNothing);
        expect(tester.getRect(card), originalRect);
        expect(
          tester
              .widget<InkWell>(
                find
                    .descendant(of: mainCard, matching: find.byType(InkWell))
                    .first,
              )
              .onTap,
          isNull,
        );
        await tester.runAsync(() async {
          importing.complete();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        if (fail) {
          expect(
            find.descendant(
              of: card,
              matching: find.byIcon(Icons.error_outline),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: card, matching: find.text('导入失败')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: card, matching: find.text('点击重试')),
            findsOneWidget,
          );
          repo.importError = null;
          repo.importBarrier = null;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (_) async => [file.path],
          );
          await tester.runAsync(() async {
            await tester.tap(card);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await tester.pumpAndSettle();
          expect(repo.importedNames, ['new.txt', 'new.txt']);
        }
        expect(
          find.descendant(
            of: card,
            matching: find.byIcon(Icons.check_circle_outline),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.text('导入完成')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: card,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        if (!fail) {
          expect(find.byType(SnackBar), findsNothing);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2100)),
          );
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: card, matching: find.text('+')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: card, matching: find.text('添加图书')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'personal book tags allow multiple existing and new labels after import',
    (tester) async {
      final repo = _MetadataRepository()
        ..books = [
          _book('私藏书', BookCollection.personal, '文学'),
          _book('其他书', BookCollection.personal, '历史'),
        ];
      await tester.pumpWidget(app(repo, BookshelfView(onBookTap: (_) {})));
      await tester.pumpAndSettle();
      // Filtering makes the book visible independently of category row order.
      await tester.tap(find.widgetWithText(ChoiceChip, '文学'));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('私藏书')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑分类标签'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '历史'));
      await tester.enterText(
        find.byKey(const ValueKey('book-tag-input')),
        '随笔，收藏',
      );
      await tester.tap(find.text('保存分类'));
      await tester.pumpAndSettle();
      expect(repo.savedTags?.keys.toSet(), {'文学', '历史', '随笔', '收藏'});
      expect(tester.takeException(), isNull);
    },
  );

  test('collections and user tags persist independently of catalog synchronization', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'reader_collections_',
    );
    var repo = await LocalBookshelfRepository.create(
      directory: directory,
      factory: databaseFactoryFfi,
    );
    try {
      final book = await repo.importBytes(
        Uint8List.fromList(utf8.encode('第一章\n正文')),
        'private.txt',
      );
      await repo.setBookTags(book.id, {'文学': null, '随笔': null});
      await repo.setBookCollection(book.id, BookCollection.contemporary);
      await repo.syncCatalogTags(book.id, {'文学': null, '推荐': '#123456'});
      await repo.syncCatalogTags(book.id, {});
      await repo.close();
      repo = await LocalBookshelfRepository.create(
        directory: directory,
        factory: databaseFactoryFfi,
      );
      var saved = (await repo.watchBooks().first).single;
      expect(saved.collection, BookCollection.contemporary);
      expect(saved.tags.map((tag) => tag.name).toSet(), {'文学', '随笔'});
      await repo.setBookTags(book.id, {'历史': null});
      saved = (await repo.watchBooks().first).single;
      expect(saved.tags.map((tag) => tag.name), ['历史']);
    } finally {
      await repo.close();
      await directory.delete(recursive: true);
    }
  });
  test(
    'version 10 libraries upgrade without losing books or classification tags',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'reader_collection_upgrade_',
      );
      var repo = await LocalBookshelfRepository.create(
        directory: directory,
        factory: databaseFactoryFfi,
      );
      try {
        final book = await repo.importBytes(
          Uint8List.fromList(utf8.encode('正文')),
          'old.txt',
        );
        await repo.setBookTags(book.id, {'旧分类': null});
        await repo.close();
        final db = await databaseFactoryFfi.openDatabase(
          '${directory.path}/reader.sqlite',
        );
        await db.execute('ALTER TABLE books DROP COLUMN collection');
        await db.setVersion(10);
        await db.close();
        repo = await LocalBookshelfRepository.create(
          directory: directory,
          factory: databaseFactoryFfi,
        );
        final restored = (await repo.watchBooks().first).single;
        expect(restored.id, book.id);
        expect(restored.collection, BookCollection.personal);
        expect(restored.tags.single.name, '旧分类');
        await repo.setBookCollection(book.id, BookCollection.contemporary);
        expect(
          (await repo.watchBooks().first).single.collection,
          BookCollection.contemporary,
        );
      } finally {
        await repo.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test('version 10 libraries with an existing collection column reopen without data loss', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'reader_existing_collection_',
    );
    var repo = await LocalBookshelfRepository.create(
      directory: directory,
      factory: databaseFactoryFfi,
    );
    try {
      final book = await repo.importBytes(
        Uint8List.fromList(utf8.encode('第一章\n已有图书正文')),
        '已有图书.txt',
      );
      await repo.setBookCollection(book.id, BookCollection.contemporary);
      await repo.setBookTags(book.id, {'已有分类': '#123456'});
      await repo.saveLocation(
        book.id,
        const ReadingLocation(chapter: 0, progress: .5, charOffset: 3),
      );
      await repo.saveNotes(book.id, ReaderNoteKind.bookmark, [
        {'chapterIndex': 0, 'charOffset': 3, 'createdAt': 1},
      ]);
      await repo.close();
      final db = await databaseFactoryFfi.openDatabase(
        '${directory.path}/reader.sqlite',
      );
      await db.setVersion(
        10,
      ); // Historical version number, column already present.
      await db.close();
      for (var attempt = 0; attempt < 2; attempt++) {
        repo = await LocalBookshelfRepository.create(
          directory: directory,
          factory: databaseFactoryFfi,
        );
        final restored = (await repo.watchBooks().first).single;
        expect(restored.id, book.id);
        expect(restored.collection, BookCollection.contemporary);
        expect(restored.tags.single.name, '已有分类');
        expect(restored.tags.single.color, '#123456');
        expect(restored.location.progress, .5);
        expect(restored.location.charOffset, 3);
        expect(
          await repo.loadNotes(book.id, ReaderNoteKind.bookmark),
          hasLength(1),
        );
        if (attempt == 0) await repo.close();
      }
    } finally {
      await repo.close();
      await directory.delete(recursive: true);
    }
  });
}

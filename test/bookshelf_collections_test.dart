import 'dart:io';
import 'dart:convert';

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
  @override
  Future<BookImportResult> importBytesWithResult(
    Uint8List bytes,
    String fileName, {
    BookSource source = BookSource.imported,
  }) async {
    importedNames.add(fileName);
    final book = _book(fileName, BookCollection.personal, '');
    books = [...books, book];
    return BookImportResult(book: book, isDuplicate: false);
  }

  @override
  Future<void> setBookTags(String bookId, Map<String, String?> tags) async {
    savedTags = tags;
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
}

import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_book_reader/src/widgets/catalog_sheet.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';

import 'views_test.dart' show FakeRepository, app, book;

void main() {
  test('bookmark excerpt JSON remains compatible with legacy data', () {
    final legacy = engine.Bookmark.fromJson(<String, dynamic>{
      'chapterIndex': 2,
      'charOffset': 12,
      'chapterTitle': '旧章节',
      'createdAt': 1,
    });
    expect(legacy.excerpt, isEmpty);

    final updated = legacy.copyWith(excerpt: '书签位置后的正文摘要');
    expect(engine.Bookmark.fromJson(updated.toJson()).excerpt, updated.excerpt);
  });

  testWidgets('new bookmark stores body excerpt', (tester) async {
    final repository = FakeRepository();
    final controller = engine.BookReaderController();
    await tester.pumpWidget(
      app(repository, ReaderView(book: book, controller: controller)),
    );
    await tester.pumpAndSettle();

    controller.toggleBookmark();
    await tester.pumpAndSettle();

    final rows = await repository.loadNotes(book.id, ReaderNoteKind.bookmark);
    expect(rows, hasLength(1));
    expect(rows.single['excerpt'], isNotEmpty);
    expect(rows.single['excerpt'], contains('山里的清晨很安静'));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    controller.dispose();
  });

  testWidgets(
    'scroll mode creates and recognizes multiple bookmarks per chapter',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FakeRepository();
      final controller = engine.BookReaderController();
      await tester.pumpWidget(
        app(repository, ReaderView(book: book, controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(controller.position, isNotNull);
      final first = controller.position!;
      expect(first.charOffset, greaterThan(0));
      controller.toggleBookmark();
      await tester.pumpAndSettle();
      expect(controller.isCurrentPageBookmarked, isTrue);

      await tester.drag(find.byType(engine.BookReader), const Offset(0, -500));
      await tester.pumpAndSettle();
      final second = controller.position!;
      expect(second.chapterIndex, first.chapterIndex);
      expect(second.charOffset, greaterThan(first.charOffset));
      expect(controller.isCurrentPageBookmarked, isFalse);
      controller.toggleBookmark();
      await tester.pumpAndSettle();

      final rows = await repository.loadNotes(book.id, ReaderNoteKind.bookmark);
      expect(rows, hasLength(2));
      expect(rows.map((row) => row['charOffset']).toSet(), <Object?>{
        first.charOffset,
        second.charOffset,
      });

      controller.goToPosition(first);
      await tester.pumpAndSettle();
      expect(controller.chapterIndex, first.chapterIndex);
      expect(controller.position!.charOffset, first.charOffset);
      expect(controller.isCurrentPageBookmarked, isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      controller.dispose();
    },
  );

  testWidgets('opening catalog backfills legacy bookmark excerpt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeRepository();
    repository.notes['${book.id}:${ReaderNoteKind.bookmark.name}'] = [
      <String, dynamic>{
        'chapterIndex': 1,
        'charOffset': 0,
        'chapterTitle': '第二章 山间',
        'createdAt': 1,
      },
    ];
    await tester.pumpWidget(app(repository, ReaderView(book: book)));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('笔记 1'));
    await tester.pumpAndSettle();

    final rows = await repository.loadNotes(book.id, ReaderNoteKind.bookmark);
    expect(rows.single['excerpt'], isNotEmpty);
    expect(find.textContaining('段落 1-0'), findsOneWidget);
    expect(tester.widget<Text>(find.textContaining('段落 1-0')).maxLines, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bookmark card shows at most three excerpt lines', (
    tester,
  ) async {
    const excerpt =
        '这里是书签位置后的正文内容，用于在笔记列表中帮助读者快速识别保存的位置。'
        '即使摘要很长，卡片也只展示三行，不会挤占整个笔记面板。';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: CatalogSheet(
              bookTitle: '测试图书',
              author: '作者',
              intro: '',
              coverColor: Colors.green,
              chapterTitles: <String>['第一章'],
              currentIndex: 0,
              theme: engine.ReaderTheme.yellow,
              bookmarks: <engine.Bookmark>[
                engine.Bookmark(
                  chapterIndex: 0,
                  charOffset: 10,
                  chapterTitle: '第一章',
                  createdAt: 1,
                  excerpt: excerpt,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes 1'));
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text(excerpt));
    expect(text.maxLines, 3);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'views_test.dart' show FakeRepository, app;
import 'package:reader/reader.dart';
import 'package:reader/src/book_reader_adapter.dart';
import 'package:reader/src/reader_notes.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

class MarkdownRepository extends FakeRepository {
  @override
  Future<BookContent> openBook(Book book) => LocalBookParser().parse(
    bytes('# 第一章\n\n这里是**需要划线**的文字，继续阅读正文。\n\n- 列表条目'),
    book.fileName,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Markdown headings, inline syntax, lists and code become readable text',
    () async {
      final content = await LocalBookParser().parse(
        bytes('''# 第一章
这里是**需要划线**的文字和[链接](https://example.com)。

- 条目一
- *条目二*

```dart
# 代码不是章节
print("hello");
```

第二章
======
> 引用内容
'''),
        '测试.MD',
      );
      expect(content.chapters.map((c) => c.title), ['第一章', '第二章']);
      expect(content.toc.map((e) => e.chapter), [0, 1]);
      final first = await normalizeChapter(content.chapters.first);
      expect(first.body, contains('这里是需要划线的文字和链接。'));
      expect(first.body, contains('条目一\n条目二'));
      expect(first.body, contains('# 代码不是章节'));
      expect(first.body, isNot(contains('**')));
      expect(
        content.chapters.first.blocks.join(),
        contains('<strong>需要划线</strong>'),
      );
      expect(content.chapters.last.blocks.join(), contains('<blockquote>'));
    },
  );

  test('Markdown rejects invalid UTF-8 and empty content', () async {
    final parser = LocalBookParser();
    await expectLater(
      parser.parse(Uint8List.fromList([255]), 'bad.md'),
      throwsFormatException,
    );
    await expectLater(
      parser.parse(bytes('  \n'), 'empty.md'),
      throwsFormatException,
    );
  });

  test('Markdown strips active HTML and uses image placeholders', () async {
    final content = await LocalBookParser().parse(
      bytes('''# 图文
<script>alert(1)</script>

![插图](./image.png)

[危险链接](javascript:alert)
'''),
      '图文.md',
    );
    final html = content.chapters.map((c) => c.blocks.join()).join();
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('javascript:')));
    expect(html, isNot(contains('<img')));
    expect(html, contains('【图片：插图】'));
  });

  testWidgets(
    'Markdown long press creates a persisted underline and restores it',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = MarkdownRepository();
      final book = Book(
        id: 'md-ui',
        title: '测试',
        author: '',
        format: BookFormat.md,
        source: BookSource.imported,
        fileName: '测试.md',
        addedAt: DateTime(2026),
      );
      await tester.pumpWidget(app(repository, ReaderView(book: book)));
      await tester.pumpAndSettle();
      final prose = find.textContaining('这里是需要划线', findRichText: true).first;
      final rect = tester.getRect(prose);
      await tester.longPressAt(Offset(rect.left + 80, rect.top + 25));
      await tester.pumpAndSettle();
      expect(find.text('划线'), findsOneWidget);
      await tester.tap(find.text('划线'));
      await tester.pumpAndSettle();
      final saved = (await repository.loadNotes(
        book.id,
        ReaderNoteKind.underline,
      )).single;
      expect(saved['text'], isNot(contains('**')));
      expect(saved['end'] as int, greaterThan(saved['start'] as int));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(repository, ReaderView(book: book)));
      await tester.pumpAndSettle();
      final reader = tester.widget<engine.BookReader>(
        find.byType(engine.BookReader),
      );
      expect(
        (await reader.underlineStore.load(book.id)).single.toJson(),
        saved,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'Markdown underline range and text survive reopening the repository',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp('reader-md-');
      var repository = await LocalBookshelfRepository.create(
        directory: directory,
        factory: databaseFactoryFfi,
      );
      try {
        final book = await repository.importBytes(
          bytes('# 第一章\n前文**需要划线**后文。'),
          '笔记.md',
        );
        expect(book.format, BookFormat.md);
        var source = RepositoryBookSource(repository, book);
        final original = await source.loadChapterBody(0);
        final start = original.indexOf('需要划线');
        expect(start, greaterThanOrEqualTo(0));
        final underline = engine.Underline(
          chapterIndex: 0,
          start: start,
          end: start + '需要划线'.length,
          text: '需要划线',
          chapterTitle: '第一章',
          createdAt: 1,
        );
        final notes = RepositoryReaderNotes(repository, book.id, (_) {});
        await notes.underlines.save(book.id, [underline]);
        await repository.close();
        repository = await LocalBookshelfRepository.create(
          directory: directory,
          factory: databaseFactoryFfi,
        );
        final reopened = (await repository.watchBooks().first).single;
        source = RepositoryBookSource(repository, reopened);
        expect(await source.loadChapterBody(0), original);
        final restored = (await RepositoryReaderNotes(
          repository,
          reopened.id,
          (_) {},
        ).underlines.load(reopened.id)).single;
        expect(restored.toJson(), underline.toJson());
        expect(
          (await source.loadChapterBody(
            0,
          )).substring(restored.start, restored.end),
          restored.text,
        );
      } finally {
        await repository.close();
        await directory.delete(recursive: true);
      }
    },
  );
}

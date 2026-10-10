import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:reader/src/html_reader_view.dart';
import 'package:reader/src/book_layout.dart';
import 'package:reader/src/book_reader_adapter.dart';
import 'views_test.dart' show FakeRepository, app;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class LayoutBundle extends CachingAssetBundle {
  LayoutBundle(this.assets);
  final Map<String, String> assets;
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(assets[key]!)));
}

class LayoutViewRepository extends FakeRepository {
  late LayoutBookContent content;
  @override
  Future<BookContent> openBook(Book book) async => content;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'catalog layout preserves original selection text, progress and notes across restart',
    () async {
      final directory = await Directory.systemTemp.createTemp('book-layout-');
      var repo = await LocalBookshelfRepository.create(
        directory: directory,
        factory: databaseFactoryFfi,
      );
      const body = '序言\n\n安身命例\n\n这里是需要划线的文字。\n\n起五行寅例\n\n其他正文。';
      final hash = sha256.convert(utf8.encode(body)).toString();
      final raw = await LocalBookParser().parse(
        Uint8List.fromList(utf8.encode(body)),
        '测试.md',
      );
      final original = TextChapter.fromChapter(raw.chapters.single);
      final canonical = original.paragraphs.join();
      final hs = [
        const LayoutHeading(
          title: '序言',
          chapter: 0,
          offset: 0,
          length: 2,
          level: 1,
        ),
        LayoutHeading(
          title: '安身命例',
          chapter: 0,
          offset: canonical.indexOf('安身命例'),
          length: 4,
          level: 2,
        ),
        LayoutHeading(
          title: '起五行寅例',
          chapter: 0,
          offset: canonical.indexOf('起五行寅例'),
          length: 5,
          level: 2,
        ),
      ];
      final rendered = renderLayoutChapter(raw.chapters.single, hs);
      final layout = BookLayout(
        sourceHash: hash,
        headings: [
          for (final h in hs)
            LayoutHeading(
              title: h.title,
              chapter: h.chapter,
              offset: h.offset,
              length: h.length,
              level: h.level,
              block: rendered.blockForOffset(h.offset),
            ),
        ],
      );
      final bundle = LayoutBundle({
        'book.md': body,
        'book.layout.json': jsonEncode(layout.toJson()),
      });
      try {
        final book = await repo.importBytes(
          Uint8List.fromList(utf8.encode(body)),
          '测试.md',
        );
        final sourceBefore = RepositoryBookSource(repo, book);
        final textBefore = await sourceBefore.loadChapterBody(0);
        final noteStart = original.toEngine(canonical.indexOf('需要划线'), 2);
        final notes = <String, dynamic>{
          'chapterIndex': 0,
          'start': noteStart,
          'end': noteStart + '需要划线'.length,
          'text': '需要划线',
          'createdAt': 1,
        };
        await repo.saveNotes(book.id, ReaderNoteKind.underline, [notes]);
        await repo.saveLocation(
          book.id,
          const ReadingLocation(charOffset: 8, block: 2, progress: .2),
        );
        await ReaderLibrary(
          repository: repo,
          bundle: bundle,
          catalog: const BookCatalog(
            books: [
              CatalogBook(
                assetPath: 'book.md',
                layoutAssetPath: 'book.layout.json',
              ),
            ],
          ),
        ).initialize();
        final content = await repo.openBook(book);
        expect(content, isA<LayoutBookContent>());
        expect(content.toc.single.children.map((e) => e.title), [
          '安身命例',
          '起五行寅例',
        ]);
        final source = RepositoryBookSource(repo, book);
        expect(await source.loadChapterBody(0), textBefore);
        final manifest = await source.loadManifest();
        expect(
          manifest.toc.single.children.last.charOffset,
          original.toEngine(hs.last.offset, 2),
        );
        expect(
          (await content.readChapter(0)).blocks.join(),
          contains('<h3>安身命例</h3>'),
        );
        await repo.close();
        repo = await LocalBookshelfRepository.create(
          directory: directory,
          factory: databaseFactoryFfi,
        );
        final restarted = (await repo.watchBooks().first).single;
        expect(restarted.id, book.id);
        expect(restarted.location.charOffset, 8);
        expect(restarted.location.block, 2);
        expect(await repo.loadNotes(book.id, ReaderNoteKind.underline), [
          notes,
        ]);
        expect(
          (await repo.openBook(restarted)).toc.single.children,
          hasLength(2),
        );
        await expectLater(
          repo.saveBookLayout(
            book.id,
            BookLayout(sourceHash: 'wrong', headings: hs),
          ),
          throwsFormatException,
        );
      } finally {
        await repo.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'visual reflow preserves annotation units, verse rows and table spaces',
    () {
      final chapter = BookChapter(
        id: '0',
        title: '测试',
        blocks: [
          '<p>${'长句正文。' * 100}</p>',
          '<p>【${'注释内容。' * 50}】</p>',
          '<p>诗句上联<br>诗句下联</p>',
          '<p>甲乙    丙丁\t子丑    寅卯</p>',
        ],
      );
      final original = TextChapter.fromChapter(chapter);
      final rendered = renderLayoutChapter(chapter, []);
      final visual = TextChapter.fromChapter(rendered.chapter);
      expect(
        visual.paragraphs.join().replaceAll(RegExp(r'\s'), ''),
        original.paragraphs.join().replaceAll(RegExp(r'\s'), ''),
      );
      expect(rendered.chapter.blocks, contains('<p>【${'注释内容。' * 50}】</p>'));
      expect(rendered.chapter.blocks, contains('<p>诗句上联</p>'));
      expect(rendered.chapter.blocks, contains('<p>诗句下联</p>'));
      expect(rendered.chapter.blocks.last, startsWith('<pre>'));
      expect(
        rendered.canonicalOffsets,
        orderedEquals([...rendered.canonicalOffsets]..sort()),
      );
    },
  );
  testWidgets(
    'image reader restores and saves positions in original coordinates',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final original = MemoryBookContent(
        title: '测试',
        author: '',
        chapters: [
          BookChapter(
            id: '0',
            title: '测试',
            blocks: [
              '<p>${'一句阅读文字。' * 60}</p>',
              '<p>目录标题</p>',
              '<p>${'第二段正文。' * 120}</p>',
            ],
          ),
        ],
      );
      final text = TextChapter.fromChapter(original.chapters.single);
      final offset = text.canonicalForBlock(1);
      final draft = LayoutHeading(
        title: '目录标题',
        chapter: 0,
        offset: offset,
        length: 4,
        level: 1,
      );
      final rendered = renderLayoutChapter(original.chapters.single, [draft]);
      final repository = LayoutViewRepository()
        ..content = LayoutBookContent(
          original,
          BookLayout(
            sourceHash: 'demo',
            headings: [
              LayoutHeading(
                title: draft.title,
                chapter: 0,
                offset: offset,
                length: 4,
                level: 1,
                block: rendered.blockForOffset(offset),
              ),
            ],
          ),
        );
      final book = Book(
        id: 'demo',
        title: '测试',
        author: '',
        format: BookFormat.md,
        source: BookSource.builtIn,
        fileName: 'test.md',
        addedAt: DateTime(2026),
        location: ReadingLocation(
          chapter: 0,
          block: 1,
          charOffset: offset,
          progress: .5,
        ),
      );
      await tester.pumpWidget(app(repository, HtmlReaderView(book: book)));
      await tester.pumpAndSettle();
      final heading = find.text('目录标题', findRichText: true).first;
      expect(tester.getRect(heading).top, inInclusiveRange(0, 844));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(repository.saves.last.charOffset, offset);
      expect(repository.saves.last.block, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(repository.saves.last.charOffset, greaterThan(offset));
      expect(repository.saves.last.block, 2);
      expect(tester.takeException(), isNull);
    },
  );
}

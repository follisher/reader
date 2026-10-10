import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/epub_continuous_view.dart';
import 'package:reader/src/epub_heading.dart';
import 'package:reader/src/models.dart';
import 'package:reader/src/parser.dart';

import 'epub_continuous_view_test.dart' show publication, frames;

void main() {
  BookChapter chapter(List<String> blocks, {String title = '第一章 山间'}) =>
      BookChapter(id: '0.xhtml', title: title, blocks: blocks);

  test(
    'opening volume/chapter/section titles retain their hierarchy without a duplicate',
    () {
      final body = chapter([
        '<h1>第一卷</h1>',
        '<h2>第一章 山间</h2>',
        '<h3>第一节</h3>',
        '<p>正文</p>',
      ]);
      expect(needsEpubChapterHeading(body), isFalse);
      expect(body.blocks, [
        '<h1>第一卷</h1>',
        '<h2>第一章 山间</h2>',
        '<h3>第一节</h3>',
        '<p>正文</p>',
      ]);
      expect(
        needsEpubChapterHeading(
          chapter(['<p class="volume-title">第一卷 起程</p>', '<h2>第一章 山间</h2>']),
        ),
        isFalse,
      );
      expect(
        needsEpubChapterHeading(chapter(['<h2>第一章　 <span>山间</span></h2>'])),
        isFalse,
      );
      expect(
        needsEpubChapterHeading(chapter(['<p>第一章 山间</p>', '<p>正文</p>'])),
        isFalse,
      );
    },
  );

  test(
    'a missing opening title is supplied even if the same title appears later',
    () {
      expect(needsEpubChapterHeading(chapter(['<p>正文</p>'])), isTrue);
      expect(
        needsEpubChapterHeading(chapter(['<p>正文</p>', '<h2>第一章 山间</h2>'])),
        isTrue,
      );
      expect(
        needsEpubChapterHeading(chapter(['<h2>序言</h2>', '<p>正文</p>'])),
        isTrue,
      );
    },
  );

  test(
    'parser retains source h1 and infers nested chapter/section TOC entries',
    () async {
      final archive = Archive();
      void add(String path, String text) {
        final bytes = utf8.encode(text);
        archive.addFile(ArchiveFile(path, bytes.length, bytes));
      }

      add(
        'META-INF/container.xml',
        '<container><rootfile full-path="book.opf"/></container>',
      );
      add(
        'book.opf',
        '<package><manifest><item id="a" href="0.xhtml"/></manifest><spine><itemref idref="a"/></spine></package>',
      );
      add(
        '0.xhtml',
        '<html><body><h1 id="volume">第一卷</h1><h2 id="chapter">第一章</h2><h3 id="section">第一节</h3><p>正文</p></body></html>',
      );
      final content = await LocalBookParser().parse(
        Uint8List.fromList(ZipEncoder().encode(archive)),
        'book.epub',
      );
      expect(content.chapters.single.blocks.first, contains('<h1'));
      expect(content.chapters.single.blocks.length, 4);
      expect(content.toc.single.title, '第一卷');
      expect(content.toc.single.children.single.title, '第一章');
      expect(content.toc.single.children.single.children.single.title, '第一节');
    },
  );

  testWidgets(
    'source opening headings render once and missing titles are supplied',
    (tester) async {
      final config = engine.ReaderConfig();
      for (final hasTitle in [true, false]) {
        final content = MemoryBookContent(
          title: '',
          author: '',
          chapters: [
            chapter([
              if (hasTitle) '<h1>第一卷</h1>',
              if (hasTitle) '<h2>第一章 山间</h2>',
              '<p>正文</p>',
            ]),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EpubContinuousView(
                key: ValueKey(hasTitle),
                content: Future.value(content),
                publication: publication(1),
                config: config,
                onPosition: (_) {},
                onSelection: (_) {},
                onTap: () {},
                onError: (_) {},
              ),
            ),
          ),
        );
        await frames(tester);
        final generated = find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == '第一章 山间',
        );
        expect(generated, hasTitle ? findsNothing : findsOneWidget);
        if (hasTitle) {
          expect(
            find.textContaining('第一卷', findRichText: true),
            findsOneWidget,
          );
          expect(
            find.textContaining('第一章 山间', findRichText: true),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      config.dispose();
    },
  );
}

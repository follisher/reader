import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_readium/flutter_readium.dart' as rd;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/epub_continuous_document.dart';
import 'package:reader/src/epub_continuous_view.dart';
import 'package:reader/src/models.dart';
import 'package:reader/src/parser.dart';

import 'reader_test.dart' show epub;

class LazyEpub extends MemoryBookContent implements OnDemandBookContent {
  LazyEpub({this.count = 30, this.paragraphs = 8, this.delayedChapter})
    : super(
        title: '连续 EPUB',
        author: '',
        chapters: [
          for (var i = 0; i < count; i++)
            BookChapter(id: 'OPS/$i.xhtml', title: '第 $i 章', blocks: const []),
        ],
      );
  final int count, paragraphs;
  final int? delayedChapter;
  final delayed = Completer<void>();
  final loaded = <int>[];

  @override
  Future<BookChapter> loadChapter(int index) async {
    loaded.add(index);
    if (index == delayedChapter) await delayed.future;
    return BookChapter(
      id: chapters[index].id,
      title: chapters[index].title,
      blocks: [
        for (var i = 0; i < paragraphs; i++)
          '<p id="p$i" data-reader-selector="html:nth-of-type(1) > body:nth-of-type(1) > p:nth-of-type(${i + 1})">第 $index 章段落 $i。${'平滑滚动阅读正文。' * 4}</p>',
      ],
    );
  }
}

rd.Publication publication(int count) => rd.Publication(
  metadata: rd.Metadata(
    localizedTitle: rd.LocalizedString.fromStrings({'zh': '连续 EPUB'}),
  ),
  readingOrder: [
    for (var i = 0; i < count; i++)
      rd.Link(href: '$i.xhtml', title: '第 $i 章', type: 'application/xhtml+xml'),
  ],
);

rd.Locator locator(int chapter, int block, {double alignment = 0}) =>
    rd.Locator.fromJson({
      'href': '$chapter.xhtml',
      'type': 'application/xhtml+xml',
      'locations': {'readerBlock': block, 'readerAlignment': alignment},
    })!;

Future<void> frames(WidgetTester tester, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  test(
    'repeated words and inline nodes preserve the correct selection offsets',
    () async {
      final content = MemoryBookContent(
        title: '',
        author: '',
        chapters: const [
          BookChapter(
            id: '0.xhtml',
            title: '',
            blocks: [
              '<p data-reader-selector="body > p:nth-of-type(1)">重复重复重复</p>',
              '<p data-reader-selector="body > p:nth-of-type(2)">前<span data-reader-selector="body > p:nth-of-type(2) > span">中</span>后</p>',
            ],
          ),
        ],
      );
      final document = EpubContinuousDocument(content, publication(1));
      await document.load(0);
      final repeated = document.locator(
        0,
        0,
        selection: '重复',
        selectionOffset: 4,
      );
      expect(repeated.locations!.domRange!.start.charOffset, 4);
      expect(repeated.text!.before, '重复重复');
      final inline = document.locator(0, 1, selection: '中后');
      expect(inline.locations!.domRange!.start.cssSelector, endsWith('span'));
      expect(inline.locations!.domRange!.end!.textNodeIndex, 1);
      expect(inline.locations!.domRange!.end!.charOffset, 1);
    },
  );

  testWidgets(
    'prefetched image geometry and inline marks preserve paragraph layout',
    (tester) async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR4nGP4z8AARAAI/gH/xp559wAAAABJRU5ErkJggg==',
      );
      final content = MemoryBookContent(
        title: '',
        author: '',
        resources: {'image.png': bytes},
        chapters: const [
          BookChapter(
            id: '0.xhtml',
            title: '正文',
            blocks: [
              '<p data-reader-selector="body > p:nth-of-type(1)">这一段有划线文字。</p>',
              '<p>下一段保持原位。</p>',
              '<img data-reader-resource="image.png">',
            ],
          ),
        ],
      );
      final future = Future<BookContent>.value(content);
      final config = engine.ReaderConfig();
      final pub = publication(1);
      final document = EpubContinuousDocument(content, pub);
      await document.load(0);
      final mark = rd.ReaderDecoration(
        id: 'line',
        locator: document.locator(0, 0, selection: '划线文字'),
        style: const rd.ReaderDecorationStyle(
          style: rd.DecorationStyle.underline,
          tint: Colors.red,
        ),
      );
      List<rd.ReaderDecoration>? tapped;
      rd.TextSelectionEvent? selected;
      Widget view(List<rd.ReaderDecoration> marks) => MaterialApp(
        home: Scaffold(
          body: EpubContinuousView(
            content: future,
            publication: pub,
            config: config,
            decorations: marks,
            onDecorationTap: (mark) => tapped = mark,
            onPosition: (_) {},
            onSelection: (event) => selected = event,
            onTap: () {},
            onError: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(view([]));
      await frames(tester);
      final next = find.textContaining('下一段保持原位', findRichText: true).first;
      final y = tester.getTopLeft(next).dy;
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio).first).aspectRatio,
        2,
      );
      await tester.pumpWidget(view([mark]));
      await frames(tester);
      expect(tester.getTopLeft(next).dy, closeTo(y, .1));
      expect(find.textContaining('划线文字', findRichText: true), findsOneWidget);
      final comment = rd.ReaderDecoration(
        id: 'comment',
        locator: mark.locator,
        style: const rd.ReaderDecorationStyle(
          style: rd.DecorationStyle.highlight,
          tint: Colors.yellow,
        ),
      );
      await tester.pumpWidget(
        view([
          mark,
          comment,
          rd.ReaderDecoration(
            id: "comment2",
            locator: mark.locator,
            style: comment.style,
          ),
          rd.ReaderDecoration(
            id: "comment3",
            locator: mark.locator,
            style: comment.style,
          ),
          rd.ReaderDecoration(
            id: "other-paragraph",
            locator: document.locator(0, 1),
            style: comment.style,
          ),
        ]),
      );
      await frames(tester);
      expect(find.byType(engine.ReaderCommentBadge), findsNothing);
      final rich = find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('这一段有划线文字'),
      );
      final paragraph = tester.renderObject<RenderParagraph>(rich.first);
      final text = paragraph.text.toPlainText();
      final start = text.indexOf('划线文字');
      final box = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 4),
          )
          .first
          .toRect();
      await tester.tapAt(paragraph.localToGlobal(box.center));
      await frames(tester);
      expect(tapped!.map((mark) => mark.id), [
        'comment',
        'comment2',
        'comment3',
      ]);

      tapped = null;
      await tester.longPressAt(paragraph.localToGlobal(box.center));
      await frames(tester);
      expect(selected?.selectedText, isNotEmpty);
      expect(tapped, isNull);
      tester
          .state<EpubContinuousViewState>(find.byType(EpubContinuousView))
          .clearSelection();
      await frames(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      config.dispose();
    },
  );
  test(
    'continuous addresses preserve original DOM and inline selection ranges',
    () async {
      final content = await LocalBookParser().parse(epub(), 'book.epub');
      final pub = rd.Publication(
        metadata: publication(1).metadata,
        readingOrder: const [
          rd.Link(href: 'a.xhtml', type: 'application/xhtml+xml'),
          rd.Link(href: 'b.xhtml', type: 'application/xhtml+xml'),
        ],
      );
      final document = EpubContinuousDocument(content, pub);
      await document.load(0);
      final selected = document.locator(0, 1, selection: '世界');
      expect(
        selected.locations!.domRange!.start.cssSelector,
        'html:nth-of-type(1) > body:nth-of-type(1) > p:nth-of-type(1)',
      );
      expect(selected.locations!.domRange!.start.charOffset, 2);
      expect(selected.locations!.domRange!.end!.charOffset, 4);
      expect(document.blockFor(0, selected), 1);
      final old = selected.toJson();
      (old['locations'] as Map)['readerBlock'] = 0;
      expect(document.blockFor(0, rd.Locator.fromJson(old)), 1);
      await document.load(1);
      expect(
        document.chapters[1]!.blocks[1],
        contains(
          'html:nth-of-type(1) > body:nth-of-type(1) > div:nth-of-type(1) > section:nth-of-type(1) > p:nth-of-type(1)',
        ),
      );
    },
  );

  testWidgets(
    'one scroll gesture crosses chapters and loads only nearby resources',
    (tester) async {
      final content = LazyEpub(paragraphs: 4);
      final positions = <rd.Locator>[];
      final errors = <Object>[];
      final config = engine.ReaderConfig();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpubContinuousView(
              content: Future.value(content),
              publication: publication(content.count),
              config: config,
              onPosition: positions.add,
              onSelection: (_) {},
              onTap: () {},
              onError: errors.add,
            ),
          ),
        ),
      );
      await frames(tester);
      expect(content.loaded.toSet().length, lessThan(10));
      expect(find.byType(CustomScrollView), findsOneWidget);
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, -1300),
        1100,
      );
      await frames(tester, 30);
      expect(positions.any((position) => position.href != '0.xhtml'), isTrue);
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(errors, isEmpty);
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 1600),
        1400,
      );
      await frames(tester, 30);
      expect(positions.last.href, '0.xhtml');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      config.dispose();
    },
  );

  testWidgets(
    'prepending a delayed chapter does not move the visible paragraph',
    (tester) async {
      final content = LazyEpub(delayedChapter: 4);
      final config = engine.ReaderConfig();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpubContinuousView(
              content: Future.value(content),
              publication: publication(content.count),
              config: config,
              initialLocator: locator(5, 2),
              onPosition: (_) {},
              onSelection: (_) {},
              onTap: () {},
              onError: (_) {},
            ),
          ),
        ),
      );
      await frames(tester);
      final paragraph = find
          .textContaining('第 5 章段落 2', findRichText: true)
          .first;
      final y = tester.getTopLeft(paragraph).dy;
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      content.delayed.complete();
      await frames(tester);
      expect(tester.getTopLeft(paragraph).dy, closeTo(y, .1));
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        closeTo(scroll, .1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      config.dispose();
    },
  );

  testWidgets('paragraph anchors survive reflow, jumps and reopening', (
    tester,
  ) async {
    final content = LazyEpub();
    final config = engine.ReaderConfig();
    final key = GlobalKey<EpubContinuousViewState>();
    final positions = <rd.Locator>[];
    final future = Future<BookContent>.value(content);
    Widget view(rd.Locator initial) => MaterialApp(
      home: Scaffold(
        body: EpubContinuousView(
          key: key,
          content: future,
          publication: publication(content.count),
          config: config,
          initialLocator: initial,
          onPosition: positions.add,
          onSelection: (_) {},
          onTap: () {},
          onError: (_) {},
        ),
      ),
    );
    await tester.pumpWidget(view(locator(5, 2, alignment: .25)));
    await frames(tester);
    expect(positions.last.href, '5.xhtml');
    expect(positions.last.locations!.additionalProperties['readerBlock'], 2);
    final paragraph = find
        .textContaining('第 5 章段落 2', findRichText: true)
        .first;
    final y = tester.getTopLeft(paragraph).dy;
    config.increaseFont();
    await tester.pumpWidget(view(locator(5, 2)));
    await frames(tester);
    expect(tester.getTopLeft(paragraph).dy, closeTo(y, .1));
    await key.currentState!.goTo(locator(20, 3));
    await frames(tester);
    expect(positions.last.href, '20.xhtml');
    expect(positions.last.locations!.additionalProperties['readerBlock'], 3);
    final saved = positions.last;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(view(saved));
    await frames(tester);
    expect(positions.last.href, saved.href);
    expect(positions.last.locations!.additionalProperties['readerBlock'], 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    config.dispose();
  });
}

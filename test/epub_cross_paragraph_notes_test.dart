import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_readium/flutter_readium.dart' as rd;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:reader/src/epub_continuous_document.dart';
import 'package:reader/src/epub_continuous_view.dart';
import 'package:reader/src/models.dart';

import 'epub_continuous_view_test.dart' show publication, frames;

rd.Locator selection(String quote, {int block = 0}) => rd.Locator.fromJson({
  'href': '0.xhtml',
  'type': 'application/xhtml+xml',
  'locations': {'readerBlock': block},
  'text': {'highlight': quote},
})!;

void main() {
  late MemoryBookContent content;
  late EpubContinuousDocument document;
  setUp(() async {
    content = MemoryBookContent(
      title: '',
      author: '',
      chapters: const [
        BookChapter(
          id: '0.xhtml',
          title: '章节标题',
          blocks: [
            '<p data-reader-selector="body > p:nth-of-type(1)">第一段结尾。</p>',
            '<p data-reader-selector="body > p:nth-of-type(2)">第二段开头与结尾。</p>',
            '<p data-reader-selector="body > p:nth-of-type(3)">第二段开头与结尾。</p>',
          ],
        ),
      ],
    );
    document = EpubContinuousDocument(content, publication(1));
    await document.load(0);
  });

  test('historical cross-paragraph underline restores a native DOM range', () {
    final original = selection('结尾。\u3000\u3000第二段开头');
    expect(document.selectionParts(0, original), [(0, 3, 6), (1, 0, 5)]);
    final repaired = document.repairSelection(0, original);
    expect(
      repaired.locations!.domRange!.start.cssSelector,
      'body > p:nth-of-type(1)',
    );
    expect(repaired.locations!.domRange!.start.charOffset, 3);
    expect(
      repaired.locations!.domRange!.end!.cssSelector,
      'body > p:nth-of-type(2)',
    );
    expect(repaired.locations!.domRange!.end!.charOffset, 5);
    expect(document.selectionParts(0, repaired), [(0, 3, 6), (1, 0, 5)]);
    expect(document.repairSelection(0, repaired), same(repaired));
  });

  test(
    'comment including a generated title restores the original body range',
    () {
      final original = selection('章节标题\u3000\u3000第一段结尾。');
      final repaired = document.repairSelection(0, original);
      expect(repaired.text!.highlight, '第一段结尾。');
      expect(repaired.locations!.domRange!.start.charOffset, 0);
      expect(repaired.locations!.domRange!.end!.charOffset, 6);
      expect(document.selectionParts(0, original), [(0, 0, 6)]);
    },
  );

  test(
    'repeated paragraphs honor the saved block; unknown text is preserved',
    () {
      expect(document.selectionParts(0, selection('第二段开头', block: 2)), [
        (2, 0, 5),
      ]);
      final unknown = selection('未找到的文字');
      expect(document.repairSelection(0, unknown), same(unknown));
      expect(document.selectionParts(0, unknown), isEmpty);
    },
  );

  test(
    'either paragraph hits the same underline; repeated text outside does not',
    () {
      final mark = rd.ReaderDecoration(
        id: 'cross',
        locator: document.repairSelection(0, selection('结尾。　　第二段开头')),
        style: const rd.ReaderDecorationStyle(
          style: rd.DecorationStyle.underline,
        ),
      );
      for (final selected in [
        document.locator(0, 0, selection: '结尾'),
        document.locator(0, 1, selection: '第二段'),
      ]) {
        final result = document.selectionResult(selected, [mark], merge: false);
        expect(result['ids'], ['cross']);
        final remaining = [mark]
          ..removeWhere((m) => (result['ids'] as List).contains(m.id));
        expect(
          document.selectionResult(selected, remaining, merge: false)['ids'],
          isEmpty,
        );
      }
      expect(
        document.selectionResult(document.locator(0, 2, selection: '第二段'), [
          mark,
        ], merge: false)['ids'],
        isEmpty,
      );
    },
  );

  test('merging a cross-paragraph underline retains the entire union', () {
    final marks = [
      rd.ReaderDecoration(
        id: 'cross',
        locator: document.repairSelection(0, selection('结尾。　　第二段开头')),
        style: const rd.ReaderDecorationStyle(
          style: rd.DecorationStyle.underline,
        ),
      ),
      rd.ReaderDecoration(
        id: 'tail',
        locator: document.locator(0, 1, selection: '头与结尾。'),
        style: const rd.ReaderDecorationStyle(
          style: rd.DecorationStyle.underline,
        ),
      ),
    ];
    final result = document.selectionResult(
      document.locator(0, 0, selection: '结尾'),
      marks,
      merge: true,
    );
    expect(result['ids'], unorderedEquals(['cross', 'tail']));
    final merged = rd.Locator.fromJson(
      result['locator'] as Map<String, dynamic>,
    )!;
    expect(document.selectionParts(0, merged), [(0, 3, 6), (1, 0, 9)]);
  });

  testWidgets(
    'indentation is non-text spacing and blank selections are cleared',
    (tester) async {
      final config = engine.ReaderConfig();
      final key = GlobalKey<EpubContinuousViewState>();
      rd.TextSelectionEvent? selected;
      var cleared = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpubContinuousView(
              key: key,
              content: Future.value(content),
              publication: publication(1),
              config: config,
              onPosition: (_) {},
              onSelection: (event) => selected = event,
              onSelectionCleared: () => cleared++,
              onTap: () {},
              onError: (_) {},
            ),
          ),
        ),
      );
      await frames(tester);
      final paragraph = find.textContaining('第一段结尾', findRichText: true).first;
      await tester.tap(paragraph);
      final area = tester.widget<SelectionArea>(find.byType(SelectionArea));
      area.onSelectionChanged!(const SelectedContent(plainText: '　　'));
      expect(selected, isNull);
      expect(cleared, greaterThan(0));
      expect(area.focusNode!.hasFocus, isFalse);
      final markup = tester
          .widgetList<HtmlWidget>(find.byType(HtmlWidget))
          .map((w) => w.html)
          .join();
      expect(markup, contains('<reader-indent>'));
      expect(markup, isNot(contains('　　')));
      final spacers = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .where((box) => box.width == config.fontSize * 2);
      expect(spacers, isNotEmpty);
      await tester.tap(paragraph);
      area.focusNode!.requestFocus();
      final region = tester
          .state<SelectionAreaState>(find.byType(SelectionArea))
          .selectableRegion;
      region.selectAll(SelectionChangedCause.toolbar);
      await frames(tester);
      expect(selected?.selectedText, contains('第一段结尾。'));
      final bounds = key.currentState!.selectionBounds;
      expect(bounds, isNotNull);
      expect(bounds!.top, lessThan(tester.getRect(paragraph).bottom));
      expect(bounds.bottom, greaterThan(bounds.top));
      expect(selected?.selectedText, isNot(contains('　　')));
      expect(selected?.selectedText, isNot(contains('\uFFFC')));
      await tester.tap(paragraph);
      await frames(tester);
      for (final listener in tester.widgetList<SelectionListener>(
        find.byType(SelectionListener),
      )) {
        expect(listener.selectionNotifier.selection.range, isNull);
      }
      expect(area.focusNode!.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      config.dispose();
    },
  );

  testWidgets('cross-paragraph underline and title comment paint body marks', (
    tester,
  ) async {
    final config = engine.ReaderConfig();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpubContinuousView(
            content: Future.value(content),
            publication: publication(1),
            config: config,
            decorations: [
              rd.ReaderDecoration(
                id: 'line',
                locator: selection('结尾。\u3000\u3000第二段开头'),
                style: const rd.ReaderDecorationStyle(
                  style: rd.DecorationStyle.underline,
                  tint: Colors.red,
                ),
              ),
              rd.ReaderDecoration(
                id: 'comment',
                locator: selection('章节标题\u3000\u3000第一段结尾。'),
                style: const rd.ReaderDecorationStyle(
                  style: rd.DecorationStyle.highlight,
                  tint: Colors.yellow,
                ),
              ),
            ],
            onPosition: (_) {},
            onSelection: (_) {},
            onTap: () {},
            onError: (_) {},
          ),
        ),
      ),
    );
    await frames(tester);
    final markup = tester
        .widgetList<HtmlWidget>(find.byType(HtmlWidget))
        .map((w) => w.html)
        .toList();
    expect(
      markup.where((s) => s.contains('text-decoration:underline')).length,
      2,
    );
    expect(
      markup.where((s) => s.contains('background-color:#ffeb3b')).length,
      1,
    );
    expect(find.byType(engine.ReaderCommentBadge), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    config.dispose();
  });
}

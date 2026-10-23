import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_readium/flutter_readium.dart' as rd;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/pdf_reader_controls.dart';

void main() {
  testWidgets(
    'PDF shared menu selects only PDF layouts and resets on dismiss',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final config = engine.ReaderConfig();
      addTearDown(config.dispose);
      var layout = rd.PDFLayout.paginated;
      var visible = true;
      var previous = 0;
      var next = 0;
      var catalog = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return PdfReaderMenu(
                  visible: visible,
                  title: 'PDF 示例',
                  page: 3,
                  progress: .25,
                  bookmarked: false,
                  layout: layout,
                  config: config,
                  onDismiss: () => setState(() => visible = false),
                  onBack: () {},
                  onToggleBookmark: () {},
                  onPrevious: () => previous++,
                  onNext: () => next++,
                  onSeek: (_) {},
                  onCatalog: () => catalog++,
                  onLayoutChanged: (value) => setState(() => layout = value),
                );
              },
            ),
          ),
        ),
      );
      expect(find.text('第 3 页 · 25%'), findsOneWidget);
      await tester.tap(find.text('上一页'));
      await tester.tap(find.text('下一页'));
      expect(previous, 1);
      expect(next, 1);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('翻页模式'), findsOneWidget);
      expect(find.text('分页'), findsNothing);
      expect(
        tester
            .widget<engine.ReaderChoiceRow<rd.PDFLayout>>(
              find.byType(engine.ReaderChoiceRow<rd.PDFLayout>),
            )
            .selected,
        rd.PDFLayout.scrollHorizontal,
      );
      for (final label in ['字号', '行距', '背景', '页间距', '适页', '适宽', '夜间']) {
        expect(find.text(label), findsNothing);
      }
      for (final entry in {
        '上下滚动': rd.PDFLayout.scrollVertical,
        '左右滚动': rd.PDFLayout.scrollHorizontal,
      }.entries) {
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();
        expect(layout, entry.value);
      }
      await tester.tapAt(const Offset(190, 350));
      await tester.pumpAndSettle();
      expect(visible, isFalse);
      update(() => visible = true);
      await tester.pumpAndSettle();
      expect(find.text('翻页模式'), findsNothing);
      expect(find.text('第 3 页 · 25%'), findsOneWidget);
      await tester.tap(find.text('目录'));
      expect(catalog, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PDF catalogue shares tab gestures, bookmark delete and navigation',
    (tester) async {
      const bookmark = engine.Bookmark(
        chapterIndex: 6,
        charOffset: -1,
        chapterTitle: '第 7 页',
        excerpt: '保存的位置',
        createdAt: 1,
      );
      engine.Bookmark? removed;
      engine.ReadingPosition? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('打开'),
                onPressed: () async {
                  picked = await showModalBottomSheet<engine.ReadingPosition>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => DraggableScrollableSheet(
                      expand: false,
                      initialChildSize: .85,
                      minChildSize: .5,
                      maxChildSize: .92,
                      builder: (_, controller) => engine.CatalogSheet(
                        bookTitle: 'PDF 示例',
                        author: '',
                        intro: '',
                        coverColor: Colors.grey,
                        chapterTitles: const ['第一节'],
                        currentIndex: 0,
                        theme: engine.ReaderTheme.white,
                        bookmarksOnly: true,
                        initialTabIndex: 0,
                        bookmarks: const [bookmark],
                        onDeleteBookmark: (value) => removed = value,
                        scrollController: controller,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.byType(Tab), findsNWidgets(2));
      expect(find.text('详情'), findsNothing);
      expect(find.text('笔记'), findsNothing);
      await tester.drag(find.byType(TabBarView), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('保存的位置'), findsOneWidget);
      expect(find.text('全部'), findsNothing);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(engine.ReaderLabels.chinese.noteDelete));
      await tester.pumpAndSettle();
      expect(removed, same(bookmark));
      expect(find.text('保存的位置'), findsNothing);
      expect(find.text('还没有书签'), findsOneWidget);
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第一节'));
      await tester.pumpAndSettle();
      expect(picked?.chapterIndex, 0);
      expect(picked?.charOffset, 0);

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('书签 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存的位置'));
      await tester.pumpAndSettle();
      expect(picked?.chapterIndex, 6);
      expect(picked?.charOffset, -1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PDF bookmarks share a chapter heading but retain separate destinations',
    (tester) async {
      const bookmarks = [
        engine.Bookmark(
          chapterIndex: 3,
          charOffset: -1,
          chapterTitle: '第一章',
          excerpt: '第 4 页',
          createdAt: 1,
        ),
        engine.Bookmark(
          chapterIndex: 5,
          charOffset: -2,
          chapterTitle: '第一章',
          excerpt: '第 6 页',
          createdAt: 2,
        ),
      ];
      engine.ReadingPosition? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('打开书签'),
                onPressed: () async {
                  picked = await showModalBottomSheet<engine.ReadingPosition>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => SizedBox(
                      height: 550,
                      child: engine.CatalogSheet(
                        bookTitle: '示例',
                        author: '',
                        intro: '',
                        coverColor: Colors.grey,
                        chapterTitles: const [],
                        currentIndex: 0,
                        theme: engine.ReaderTheme.white,
                        bookmarksOnly: true,
                        initialTabIndex: 1,
                        bookmarks: bookmarks,
                        bookmarkGroupKey: (_) => 'toc:book.pdf#page=3',
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开书签'));
      await tester.pumpAndSettle();
      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('第 4 页'), findsOneWidget);
      expect(find.text('第 6 页'), findsOneWidget);
      await tester.tap(find.text('第 6 页'));
      await tester.pumpAndSettle();
      expect(picked?.chapterIndex, 5);
      expect(picked?.charOffset, -2);
      expect(tester.takeException(), isNull);
    },
  );
}

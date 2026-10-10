import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart';
import 'package:flutter_book_reader/src/paginator.dart';
import 'package:flutter_book_reader/src/text_actions.dart';
import 'package:flutter_book_reader/src/widgets/page_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'TXT selects across independent scroll paragraphs and saves full ranges',
    (tester) async {
      final config = ReaderConfig();
      final group = ReaderProseSelectionGroup();
      const first = ReaderBlock(
        text: '　　第一段文字，第一行继续阅读。第二行继续阅读，第三行继续阅读。',
        isParagraphStart: true,
      );
      const second = ReaderBlock(
        text: '　　第二段文字，继续阅读后面的内容。',
        isParagraphStart: true,
      );
      final lines = <Underline>[];
      final comments = <Comment>[];
      ReaderSelection? selection;
      ReaderSegmentTap? tapped;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return ReaderSelectionScope(
                  enabled: true,
                  onAction: (action, value) {
                    selection = value;
                    if (action == ReaderTextAction.comment) {
                      setState(
                        () => comments.add(
                          Comment(
                            chapterIndex: 0,
                            start: value.start,
                            end: value.end,
                            quote: value.text,
                            text: '跨段评论',
                            chapterTitle: '',
                            createdAt: 1,
                          ),
                        ),
                      );
                    }
                  },
                  child: ReaderUnderlineScope(
                    underlines: List.of(lines),
                    onAdd: (chapter, start, end, text) {
                      setState(
                        () => lines.add(
                          Underline(
                            chapterIndex: chapter,
                            start: start,
                            end: end,
                            text: text,
                            chapterTitle: '',
                            createdAt: 1,
                          ),
                        ),
                      );
                    },
                    onRemove: (items) =>
                        setState(() => lines.removeWhere(items.contains)),
                    child: ReaderSegmentScope(
                      comments: List.of(comments),
                      onTap: (value) => tapped = value,
                      child: Center(
                        child: SizedBox(
                          width: 280,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ReaderProse(
                                page: const [first],
                                config: config,
                                selectionGroup: group,
                              ),
                              const SizedBox(height: 16),
                              ReaderProse(
                                page: const [second],
                                config: config,
                                selectionGroup: group,
                                pageStartOffset: first.text.length,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final one = find.textContaining('第一段文字', findRichText: true).first;
      final two = find.textContaining('第二段文字', findRichText: true).first;
      Future<void> selectAcross() async {
        final r = tester.getRect(one);
        await tester.longPressAt(r.topLeft + const Offset(75, 15));
        await tester.pumpAndSettle();
        final handle = find.byKey(const ValueKey<String>('sel-end'));
        expect(handle, findsOneWidget);
        final target = tester.getRect(two);
        await tester.dragFrom(
          tester.getCenter(handle),
          target.bottomRight + const Offset(-5, 5) - tester.getCenter(handle),
        );
        await tester.pumpAndSettle();
      }

      await selectAcross();
      await tester.tap(find.text('划线'));
      await tester.pumpAndSettle();
      expect(lines, hasLength(1));
      expect(lines.single.start, 2);
      expect(lines.single.end, greaterThan(first.text.length + 2));
      expect(lines.single.text, contains('第一段'));
      expect(lines.single.text, contains('\n第二段'));
      expect(lines.single.text, isNot(contains('　　')));
      await selectAcross();
      await tester.tap(find.text('评论'));
      await tester.pumpAndSettle();
      expect(selection!.end, greaterThan(first.text.length + 2));
      expect(comments.single.quote, contains('\n第二段'));
      // Click the second paragraph's highlighted body to verify the cross-paragraph comment.
      final r = tester.getRect(two);
      await tester.tapAt(r.topLeft + const Offset(75, 15));
      await tester.pumpAndSettle();
      expect(tapped, isNotNull);
      expect(tapped!.end, comments.single.end);
      await tester.longPressAt(r.topLeft + const Offset(75, 15));
      await tester.pumpAndSettle();
      expect(find.text('删除划线'), findsOneWidget);
      await tester.tap(find.text('删除划线'));
      await tester.pumpAndSettle();
      expect(lines, isEmpty);
      rebuild(() => comments.clear());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      config.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';

void main() {
  final book = Book(
    id: 'cover-test',
    title: '封面测试',
    author: '作者',
    format: BookFormat.txt,
    source: BookSource.imported,
    fileName: 'cover.txt',
    coverPath: '/missing/reader-cover.png',
    addedAt: DateTime(2026),
    location: const ReadingLocation(progress: .5),
    tags: const [BookTag(id: 1, name: '命理')],
  );

  testWidgets(
    'ancient cover uses a vertical title and stamp and supports host sizing and tap',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var tapped = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 120,
                  height: 180,
                  child: BookCover(book: book, onTap: () => tapped = true),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(BookCover)), const Size(120, 180));
        expect(find.text('封\n面\n测\n试'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('book-cover-title-slip')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('book-cover-classification-seal')),
          findsOneWidget,
        );
        expect(find.text('命\n理'), findsOneWidget);
        expect(find.text(book.author), findsOneWidget);
        expect(find.text('50.0%'), findsNothing);
        expect(find.bySemanticsLabel('《封面测试》'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('已读|阅读便签')), findsNothing);
        await tester.tap(find.byType(BookCover));
        expect(tapped, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('shelf can retain progress and note tabs explicitly', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: BookCover(
              book: book,
              showProgress: true,
              markers: const [
                ShelfNoteMarker(
                  kind: ReaderNoteKind.bookmark,
                  noteKey: '0:20',
                  createdAt: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BookCover)), const Size(110, 162));
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.bySemanticsLabel('《封面测试》，已读 50%，有阅读便签'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
  testWidgets(
    'compressed paper retains page anchors and groups notes on the same page',
    (tester) async {
      final pagination = BookCoverPagination([
        [for (var i = 0; i < 1000; i++) i * 480],
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: BookCover(
              book: book,
              pagination: pagination,
              markers: const [
                ShelfNoteMarker(
                  kind: ReaderNoteKind.underline,
                  noteKey: '0:0:2',
                  createdAt: 1,
                ),
                ShelfNoteMarker(
                  kind: ReaderNoteKind.underline,
                  noteKey: '0:10:12',
                  createdAt: 2,
                ),
                ShelfNoteMarker(
                  kind: ReaderNoteKind.underline,
                  noteKey: '0:479520:479522',
                  createdAt: 3,
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('book-cover-page-tab-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('book-cover-page-tab-999')),
        findsOneWidget,
      );
      final early = tester.getTopLeft(
        find.byKey(const ValueKey('book-cover-page-tab-0')),
      );
      final late = tester.getTopLeft(
        find.byKey(const ValueKey('book-cover-page-tab-999')),
      );
      expect(late.dx, greaterThan(early.dx));
      expect(tester.getSize(find.byType(BookCover)), const Size(110, 162));
      expect(tester.takeException(), isNull);
    },
  );
}

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
    'external cover hides metadata and supports host sizing and tap',
    (tester) async {
      final semantics = tester.ensureSemantics();
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
      expect(find.text(book.title), findsOneWidget);
      expect(find.text(book.author), findsOneWidget);
      expect(find.text('命理'), findsNothing);
      expect(find.text('50.0%'), findsNothing);
      expect(find.bySemanticsLabel('《封面测试》'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('已读|阅读便签')), findsNothing);
      await tester.tap(find.byType(BookCover));
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    semantics.dispose();
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
}

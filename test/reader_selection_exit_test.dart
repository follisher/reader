import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:reader/src/epub_continuous_view.dart';

import 'views_test.dart' show FakeRepository, book;
import 'epub_continuous_view_test.dart' show LazyEpub, publication, frames;

void main() {
  for (final pending in [false, true]) {
    testWidgets(
      'return to shelf destroys TXT selection overlay (pending: $pending)',
      (tester) async {
        final nav = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              bookshelfRepositoryProvider.overrideWithValue(FakeRepository()),
            ],
            child: MaterialApp(
              navigatorKey: nav,
              home: const Scaffold(body: Text('书架')),
            ),
          ),
        );
        nav.currentState!.push(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => ReaderView(book: book),
          ),
        );
        await tester.pumpAndSettle();
        final paragraph = find
            .textContaining('段落 1-9', findRichText: true)
            .first;
        final rect = tester.getRect(paragraph);
        final position = rect.topLeft + const Offset(80, 20);
        if (pending) {
          final detector = tester
              .widgetList<GestureDetector>(
                find.ancestor(
                  of: paragraph,
                  matching: find.byType(GestureDetector),
                ),
              )
              .firstWhere((widget) => widget.onLongPressStart != null);
          detector.onLongPressStart!(
            LongPressStartDetails(globalPosition: position),
          );
        } else {
          await tester.longPressAt(position);
          await tester.pumpAndSettle();
          expect(find.text('划线'), findsOneWidget);
        }
        nav.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('书架'), findsOneWidget);
        expect(find.byType(engine.ReaderSelectionToolbar), findsNothing);
        expect(find.byKey(const ValueKey<String>('sel-start')), findsNothing);
        expect(find.byKey(const ValueKey<String>('sel-end')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'leaving EPUB with active handles disposes selection and pending geometry callback',
    (tester) async {
      final config = engine.ReaderConfig();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpubContinuousView(
              content: Future.value(LazyEpub(count: 1)),
              publication: publication(1),
              config: config,
              onPosition: (_) {},
              onSelection: (_) {},
              onTap: () {},
              onError: (_) {},
              onSelectionGeometryChanged: () {},
            ),
          ),
        ),
      );
      await frames(tester);
      final area = tester.state<SelectionAreaState>(find.byType(SelectionArea));
      area.selectableRegion.selectAll(SelectionChangedCause.toolbar);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('书架'))),
      );
      await frames(tester);
      expect(find.byType(SelectionArea), findsNothing);
      expect(find.text('书架'), findsOneWidget);
      expect(tester.takeException(), isNull);
      config.dispose();
    },
  );
}

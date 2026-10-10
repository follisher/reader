import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/epub_continuous_view.dart';
import 'package:reader/src/models.dart';

import 'epub_continuous_view_test.dart' show LazyEpub, publication, frames;

void main() {
  testWidgets(
    'EPUB scrolls continuously and pauses, changes speed and stops immediately',
    (tester) async {
      final content = LazyEpub();
      final future = Future<BookContent>.value(content);
      final config = engine.ReaderConfig();
      Widget view({
        bool paused = false,
        bool active = true,
        int seconds = 15,
      }) => MaterialApp(
        home: Scaffold(
          body: EpubContinuousView(
            content: future,
            publication: publication(content.count),
            config: config,
            autoReading: active,
            autoPaused: paused,
            autoInterval: Duration(seconds: seconds),
            onPosition: (_) {},
            onSelection: (_) {},
            onTap: () {},
            onError: (_) {},
          ),
        ),
      );
      double offset() => tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      await tester.pumpWidget(view());
      await frames(tester);
      final start = offset();
      await frames(tester, 25);
      final fastDistance = offset() - start;
      expect(fastDistance, greaterThan(20));
      await tester.pumpWidget(view(paused: true));
      final paused = offset();
      await frames(tester, 25);
      expect(offset(), closeTo(paused, .1));
      await tester.pumpWidget(view(seconds: 40));
      final slowStart = offset();
      await frames(tester, 25);
      final slowDistance = offset() - slowStart;
      expect(slowDistance, greaterThan(5));
      expect(slowDistance, lessThan(fastDistance));
      await tester.pumpWidget(view(active: false));
      final stopped = offset();
      await frames(tester, 25);
      expect(offset(), closeTo(stopped, .1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      config.dispose();
    },
  );

  testWidgets(
    'touch pauses EPUB automatic scrolling and resumes after release settles',
    (tester) async {
      final content = LazyEpub();
      final config = engine.ReaderConfig();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpubContinuousView(
              content: Future.value(content),
              publication: publication(content.count),
              config: config,
              autoReading: true,
              autoInterval: const Duration(seconds: 15),
              onPosition: (_) {},
              onSelection: (_) {},
              onTap: () {},
              onError: (_) {},
            ),
          ),
        ),
      );
      await frames(tester);
      double offset() => tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CustomScrollView)),
      );
      await tester.pump();
      final paused = offset();
      await frames(tester, 20);
      expect(offset(), closeTo(paused, .1));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(offset(), closeTo(paused, .1));
      await frames(tester, 15);
      expect(offset(), greaterThan(paused));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      config.dispose();
    },
  );

  testWidgets('EPUB stops once at the end of a book', (tester) async {
    final content = LazyEpub(count: 1, paragraphs: 1);
    final config = engine.ReaderConfig();
    var reachedEnd = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpubContinuousView(
            content: Future.value(content),
            publication: publication(1),
            config: config,
            autoReading: true,
            onPosition: (_) {},
            onSelection: (_) {},
            onTap: () {},
            onError: (_) {},
            onEnd: () => reachedEnd++,
          ),
        ),
      ),
    );
    await frames(tester, 30);
    expect(reachedEnd, 1);
    await frames(tester, 15);
    expect(reachedEnd, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    config.dispose();
  });

  testWidgets(
    'shared speed sheet shows slow/fast and exit with no seconds control',
    (tester) async {
      var interval = const Duration(milliseconds: 32500);
      bool? resume;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 27,
                  child: Builder(
                    builder: (context) => engine.ReaderAutoReadBar(
                      theme: engine.ReaderTheme.fromAlias('white'),
                      labels: engine.ReaderLabels.chinese,
                      collapsed: false,
                      onExpand: () {},
                      onSettings: () async {
                        resume = await engine.showReaderAutoReadSettings(
                          context: context,
                          theme: engine.ReaderTheme.fromAlias('white'),
                          labels: engine.ReaderLabels.chinese,
                          interval: interval,
                          onIntervalChanged: (value) => interval = value,
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('auto-read-settings-entry')));
      await tester.pumpAndSettle();
      expect(find.text('慢'), findsOneWidget);
      expect(find.text('快'), findsOneWidget);
      expect(find.text('退出自动阅读'), findsOneWidget);
      expect(find.textContaining('秒'), findsNothing);
      await tester.drag(find.byType(Slider), const Offset(70, 0));
      await tester.pump();
      expect(interval, lessThan(const Duration(milliseconds: 32500)));
      await tester.tapAt(const Offset(10, 50));
      await tester.pumpAndSettle();
      expect(resume, isTrue);
      await tester.tap(find.byKey(const ValueKey('auto-read-settings-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出自动阅读'));
      await tester.pumpAndSettle();
      expect(resume, isFalse);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/widget/share_card_sheet.dart';

void main() {
  for (final theme in <engine.ReaderTheme>[
    engine.ReaderTheme.yellow,
    engine.ReaderTheme.night,
  ]) {
    testWidgets('share card fits a phone viewport in ${theme.alias} theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShareCardSheet(
              bookTitle: '山间阅读札记',
              author: '离线阅读示例',
              coverPath: null,
              chapterTitle: '第二章 山间',
              quote: List.filled(40, '山里的清晨很安静，沿着溪水向前走。').join(),
              readerTheme: theme,
              textStyle: const TextStyle(fontSize: 20),
              dateText: '2026/09/17',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('分享图片'), findsOneWidget);
      expect(find.text('《山间阅读札记》'), findsOneWidget);
      expect(find.text('摘录于 2026/09/17'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

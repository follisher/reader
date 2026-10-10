import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';

import 'views_test.dart' show FakeRepository, book;

Widget _host(
  FakeRepository repository,
  ValueNotifier<ThemeMode> mode,
  Widget reader,
) => ProviderScope(
  overrides: [bookshelfRepositoryProvider.overrideWithValue(repository)],
  child: ValueListenableBuilder<ThemeMode>(
    valueListenable: mode,
    builder: (_, value, _) => MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: value,
      home: reader,
    ),
  ),
);

void main() {
  testWidgets(
    'text follows host brightness without overwriting paper preference',
    (tester) async {
      final repository = FakeRepository()
        ..settings = const ReaderSettings(theme: 'yellow');
      final mode = ValueNotifier(ThemeMode.dark);
      await tester.pumpWidget(_host(repository, mode, ReaderView(book: book)));
      await tester.pumpAndSettle();
      final config = tester
          .widget<engine.BookReader>(find.byType(engine.BookReader))
          .config!;
      expect(config.theme.isDark, isTrue);
      config.increaseFont();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.settings.theme, 'yellow');
      expect(repository.settings.dark, isFalse);
      mode.value = ThemeMode.light;
      await tester.pumpAndSettle();
      expect(config.theme.alias, 'yellow');
      mode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(config.theme.isDark, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      mode.dispose();
      expect(repository.settings.theme, 'yellow');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('independent reader keeps its saved theme in a dark host', (
    tester,
  ) async {
    final repository = FakeRepository()
      ..settings = const ReaderSettings(theme: 'yellow');
    final mode = ValueNotifier(ThemeMode.dark);
    await tester.pumpWidget(
      _host(repository, mode, ReaderView(book: book, followHostTheme: false)),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<engine.BookReader>(find.byType(engine.BookReader))
          .config!
          .theme
          .alias,
      'yellow',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    mode.dispose();
    expect(tester.takeException(), isNull);
  });
}

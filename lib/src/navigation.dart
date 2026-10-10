import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'providers.dart';
import 'reader_view.dart';

/// Opens a list's Book directly, restoring its saved reading position.
/// Pass an excerpt's ReaderOpenRequest to [openReaderRequest] for positioning.
Future<void> openReader(
  BuildContext context, {
  required Book book,
  bool followHostTheme = true,
}) => openReaderRequest(
  context,
  request: ReaderOpenRequest(book: book),
  followHostTheme: followHostTheme,
);

Future<void> openReaderRequest(
  BuildContext context, {
  required ReaderOpenRequest request,
  bool followHostTheme = true,
}) {
  final repository = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(bookshelfRepositoryProvider);
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'book_reader'),
      builder: (_) => ProviderScope(
        overrides: [bookshelfRepositoryProvider.overrideWithValue(repository)],
        child: ReaderView(
          book: request.book,
          followHostTheme: followHostTheme,
          initialChapter: request.chapterIndex,
          initialCharOffset: request.charOffset,
          initialAnchor: request.anchor,
        ),
      ),
    ),
  );
}

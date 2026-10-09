import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'catalog.dart';
import 'models.dart';
import 'repository.dart';

/// Override this in a ProviderScope with your local or future sync repository.
final bookshelfRepositoryProvider = Provider<BookshelfRepository>((ref) {
  throw StateError('请通过 bookshelfRepositoryProvider 注入阅读仓库');
}, dependencies: const []);
final bookshelfProvider = StreamProvider<List<Book>>(
  (ref) => ref.watch(bookshelfRepositoryProvider).watchBooks(),
  dependencies: [bookshelfRepositoryProvider],
);

final shelfEntriesProvider = StreamProvider<List<ShelfEntry>>((ref) {
  final repository = ref.watch(bookshelfRepositoryProvider);
  if (repository is BookshelfInsightsRepository) {
    return (repository as BookshelfInsightsRepository).watchShelfEntries();
  }
  return repository.watchBooks().asyncMap((books) async {
    final result = <ShelfEntry>[];
    for (final book in books) {
      final markers = <ShelfNoteMarker>[];
      var count = 0;
      for (final kind in ReaderNoteKind.values) {
        final notes = await repository.loadNotes(book.id, kind);
        count += notes.length;
        for (final note in notes) {
          final noteKey = kind == ReaderNoteKind.bookmark
              ? '${note['chapterIndex']}:${note['charOffset']}'
              : '${note['chapterIndex']}:${note['start']}:${note['end']}'
                    '${kind == ReaderNoteKind.comment ? ':${note['createdAt']}' : ''}';
          markers.add(
            ShelfNoteMarker(
              kind: kind,
              noteKey: noteKey,
              createdAt: note['createdAt'] as int? ?? 0,
            ),
          );
        }
      }
      markers.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      result.add(
        ShelfEntry(
          book: book,
          noteCount: count,
          markers: markers.take(4).toList(),
        ),
      );
    }
    return result;
  });
}, dependencies: [bookshelfRepositoryProvider]);

/// The host owns the Dart catalog. Without an override, no assets are imported.
final readerCatalogProvider = Provider<BookCatalog>(
  (ref) => const BookCatalog(books: []),
  dependencies: const [],
);

final readerLibraryProvider = Provider<ReaderLibrary>(
  (ref) => ReaderLibrary(
    repository: ref.watch(bookshelfRepositoryProvider),
    catalog: ref.watch(readerCatalogProvider),
  ),
  dependencies: [bookshelfRepositoryProvider, readerCatalogProvider],
);

final booksByTagsProvider = StreamProvider.family<List<Book>, BookTagsQuery>(
  (ref, query) => ref.watch(readerLibraryProvider).watchBooksByTags(query),
  dependencies: [readerLibraryProvider],
);

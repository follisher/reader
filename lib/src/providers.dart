import 'package:flutter_riverpod/flutter_riverpod.dart';
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

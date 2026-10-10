import 'dart:convert';

import 'package:flutter/services.dart';

import 'models.dart';
import 'book_layout.dart';
import 'repository.dart';

/// A host-defined category. Reuse the same const in catalogs and queries.
/// [name] is the unique, persisted identity; [color] is optional metadata.
class CatalogTag {
  const CatalogTag({required this.name, this.color});

  final String name;
  final String? color;

  void _validate() {
    if (name.isEmpty || name.trim() != name) {
      throw ArgumentError.value(name, 'tag.name', '标签名称不能为空或含首尾空白');
    }
  }

  @override
  bool operator ==(Object other) => other is CatalogTag && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

class CatalogBook {
  const CatalogBook({
    required this.assetPath,
    this.tags = const [],
    this.layoutAssetPath,
  });
  final String assetPath;
  final String? layoutAssetPath;
  final List<CatalogTag> tags;
}

class BookCatalog {
  const BookCatalog({required this.books});
  final List<CatalogBook> books;
}

enum BookTagMatch { any, all }

/// Empty tags select all books. Multiple tags default to an intersection.
class BookTagsQuery {
  BookTagsQuery({
    required Iterable<CatalogTag> tags,
    this.match = BookTagMatch.all,
  }) : tags = Set.unmodifiable(tags) {
    for (final tag in this.tags) {
      tag._validate();
    }
  }

  final Set<CatalogTag> tags;
  final BookTagMatch match;

  bool includes(Book book) {
    if (tags.isEmpty) return true;
    final names = book.tags.map((tag) => tag.name).toSet();
    return match == BookTagMatch.all
        ? tags.every((tag) => names.contains(tag.name))
        : tags.any((tag) => names.contains(tag.name));
  }

  @override
  bool operator ==(Object other) =>
      other is BookTagsQuery &&
      other.match == match &&
      other.tags.length == tags.length &&
      tags.containsAll(other.tags);

  @override
  int get hashCode => Object.hash(match, Object.hashAllUnordered(tags));
}

/// Queries work before the bookshelf is ever mounted. Synchronization failures
/// are surfaced to the caller; a failed attempt can be retried.
class ReaderLibrary {
  ReaderLibrary({
    required this.repository,
    this.catalog = const BookCatalog(books: []),
    AssetBundle? bundle,
  }) : bundle = bundle ?? rootBundle;

  final BookshelfRepository repository;
  final BookCatalog catalog;
  final AssetBundle bundle;
  Future<void>? _initialization;

  Future<void> initialize() =>
      _initialization ??= _initialize().onError((Object e, StackTrace st) {
        _initialization = null;
        Error.throwWithStackTrace(e, st);
      });

  Future<void> _initialize() async {
    final entries = catalog.books;
    // Validate the whole catalog before any writes. Conflicting declarations
    // would otherwise make the stored color depend on book import order.
    final declaredTags = <String, CatalogTag>{};
    final paths = <String>{};
    for (final entry in entries) {
      if (entry.assetPath.isEmpty || !paths.add(entry.assetPath)) {
        throw ArgumentError.value(
          entry.assetPath,
          'assetPath',
          '图书资源路径不能为空或重复',
        );
      }
      for (final tag in entry.tags) {
        tag._validate();
        final previous = declaredTags[tag.name];
        if (previous != null && previous.color != tag.color) {
          throw ArgumentError('标签「${tag.name}」有不同的颜色定义，请共用同一个标签常量');
        }
        declaredTags[tag.name] = tag;
      }
    }
    for (final entry in entries) {
      await _import(entry.assetPath, {
        for (final tag in entry.tags) tag.name: tag.color,
      }, entry.layoutAssetPath);
    }
  }

  Future<void> _import(
    String path,
    Map<String, String?> tags,
    String? layoutPath,
  ) async {
    final data = await bundle.load(path);
    final book = await repository.importBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      path.split('/').last,
      source: BookSource.builtIn,
    );
    if (layoutPath != null && repository is BookLayoutRepository) {
      final layout = BookLayout.fromJson(
        jsonDecode(await bundle.loadString(layoutPath)) as Map<String, dynamic>,
      );
      await (repository as BookLayoutRepository).saveBookLayout(
        book.id,
        layout,
      );
    }
    await repository.syncCatalogTags(book.id, tags);
  }

  Future<List<Book>> loadBooksByTags(BookTagsQuery query) async {
    await initialize();
    return List.unmodifiable(
      (await repository.watchBooks().first).where(query.includes),
    );
  }

  Stream<List<Book>> watchBooksByTags(BookTagsQuery query) async* {
    await initialize();
    yield* repository.watchBooks().map(
      (books) => List<Book>.unmodifiable(books.where(query.includes)),
    );
  }
}

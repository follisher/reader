import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

abstract final class _Tags {
  static const classic = CatalogTag(name: '经典', color: '#7C3AED');
  static const fortune = CatalogTag(name: '命理', color: '#2563EB');
  static const novel = CatalogTag(name: '小说', color: '#D97706');
}

class _Bundle extends CachingAssetBundle {
  _Bundle(this.assets);
  final Map<String, String> assets;
  int loads = 0;

  @override
  Future<ByteData> load(String key) async {
    loads++;
    if (!assets.containsKey(key)) throw FlutterError('Missing $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(assets[key]!)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late LocalBookshelfRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('reader_catalog_');
    repository = await LocalBookshelfRepository.create(
      directory: directory,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  const catalog = BookCatalog(
    books: [
      CatalogBook(
        assetPath: 'assets/books/a.txt',
        tags: [_Tags.classic, _Tags.fortune],
      ),
      CatalogBook(assetPath: 'assets/books/b.txt', tags: [_Tags.classic]),
      CatalogBook(assetPath: 'assets/books/c.txt', tags: [_Tags.novel]),
    ],
  );

  test(
    'queries initialize without mounting shelf; all/any and empty tags',
    () async {
      final bundle = _Bundle({
        'assets/books/a.txt': '第一章\n命理正文',
        'assets/books/b.txt': '第一章\n经典正文',
        'assets/books/c.txt': '第一章\n小说正文',
      });
      final library = ReaderLibrary(
        repository: repository,
        catalog: catalog,
        bundle: bundle,
      );
      final query = BookTagsQuery(tags: [_Tags.classic, _Tags.fortune]);
      final books = await library.loadBooksByTags(query);
      expect(books, hasLength(1));
      expect((await repository.openBook(books.single)).chapters, isNotEmpty);
      expect(
        await library.loadBooksByTags(
          BookTagsQuery(
            tags: [_Tags.classic, _Tags.fortune],
            match: BookTagMatch.any,
          ),
        ),
        hasLength(2),
      );
      expect(
        await library.loadBooksByTags(BookTagsQuery(tags: [])),
        hasLength(3),
      );
      expect(bundle.loads, 3);
      await repository.removeBook(books.single.id);
      expect(await library.loadBooksByTags(query), isEmpty);
      final restarted = ReaderLibrary(
        repository: repository,
        catalog: catalog,
        bundle: bundle,
      );
      expect(await restarted.loadBooksByTags(query), isEmpty);
    },
  );

  test(
    'failed initialization can retry and concurrent calls share import',
    () async {
      final bundle = _Bundle({});
      final library = ReaderLibrary(
        repository: repository,
        catalog: const BookCatalog(
          books: [
            CatalogBook(assetPath: 'a.txt', tags: [_Tags.novel]),
          ],
        ),
        bundle: bundle,
      );
      final query = BookTagsQuery(tags: [_Tags.novel]);
      await expectLater(
        library.loadBooksByTags(query),
        throwsA(isA<FlutterError>()),
      );
      bundle.assets['a.txt'] = '第一章\n正文';
      final results = await Future.wait([
        library.loadBooksByTags(query),
        library.loadBooksByTags(query),
      ]);
      expect(results.every((books) => books.length == 1), isTrue);
      expect(bundle.loads, 2);
    },
  );

  test(
    'host adds arbitrary books and categories without reader changes',
    () async {
      const travel = CatalogTag(name: '旅行', color: '#00AABB');
      final bundle = _Bundle({'new.txt': '第一章\n新增书籍正文'});
      final library = ReaderLibrary(
        repository: repository,
        catalog: const BookCatalog(
          books: [
            CatalogBook(assetPath: 'new.txt', tags: [travel]),
          ],
        ),
        bundle: bundle,
      );
      final books = await library.loadBooksByTags(
        BookTagsQuery(tags: [travel]),
      );
      expect(books, hasLength(1));
      expect(books.single.tags.single.name, '旅行');
      expect(books.single.tags.single.color, '#00AABB');
      expect(
        await library.loadBooksByTags(
          BookTagsQuery(tags: [const CatalogTag(name: '旅行')]),
        ),
        hasLength(1),
      );
      final empty = ReaderLibrary(repository: repository, bundle: bundle);
      await empty.initialize();
      expect(bundle.loads, 1); // Empty catalog never discovers or reads assets.
    },
  );

  test('invalid host tag declarations fail before importing books', () async {
    final bundle = _Bundle({'a.txt': '正文'});
    expect(
      () => BookTagsQuery(tags: [const CatalogTag(name: ' ')]),
      throwsArgumentError,
    );
    expect(
      () => BookTagsQuery(tags: [const CatalogTag(name: ' 旅行')]),
      throwsArgumentError,
    );
    final conflicting = ReaderLibrary(
      repository: repository,
      catalog: const BookCatalog(
        books: [
          CatalogBook(
            assetPath: 'a.txt',
            tags: [CatalogTag(name: '旅行', color: '#000000')],
          ),
          CatalogBook(
            assetPath: 'b.txt',
            tags: [CatalogTag(name: '旅行', color: '#FFFFFF')],
          ),
        ],
      ),
      bundle: bundle,
    );
    await expectLater(conflicting.initialize(), throwsArgumentError);
    expect(bundle.loads, 0);
    expect(await repository.watchBooks().first, isEmpty);
    final duplicate = ReaderLibrary(
      repository: repository,
      catalog: const BookCatalog(
        books: [
          CatalogBook(assetPath: 'a.txt'),
          CatalogBook(assetPath: 'a.txt'),
        ],
      ),
      bundle: bundle,
    );
    await expectLater(duplicate.initialize(), throwsArgumentError);
    expect(bundle.loads, 0);
  });

  test('tag watch updates after tag synchronization', () async {
    final book = await repository.importBytes(
      Uint8List.fromList(utf8.encode('正文')),
      'a.txt',
    );
    final library = ReaderLibrary(
      repository: repository,
      catalog: const BookCatalog(books: []),
    );
    final stream = library.watchBooksByTags(BookTagsQuery(tags: [_Tags.novel]));
    final iterator = StreamIterator(stream);
    try {
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, isEmpty);
      await repository.syncCatalogTags(book.id, {'小说': null});
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.single.id, book.id);
    } finally {
      await iterator.cancel();
    }
  });

  test(
    'family keys ignore duplicate tags and order; scoped providers resolve',
    () async {
      final first = BookTagsQuery(
        tags: [_Tags.classic, _Tags.fortune, _Tags.classic],
      );
      final second = BookTagsQuery(tags: [_Tags.fortune, _Tags.classic]);
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      final container = ProviderContainer(
        overrides: [
          bookshelfRepositoryProvider.overrideWithValue(repository),
          readerCatalogProvider.overrideWithValue(const BookCatalog(books: [])),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(booksByTagsProvider(first).future), isEmpty);
    },
  );
}

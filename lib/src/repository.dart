import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'cover_pagination.dart';
import 'book_layout.dart';
import 'parser.dart';

enum ReaderNoteKind { bookmark, underline, comment }

class ShelfNoteMarker {
  const ShelfNoteMarker({
    required this.kind,
    required this.noteKey,
    required this.createdAt,
  });

  final ReaderNoteKind kind;
  final String noteKey;
  final int createdAt;
}

class ShelfEntry {
  const ShelfEntry({
    required this.book,
    required this.noteCount,
    required this.markers,
  });

  final Book book;
  final int noteCount;
  final List<ShelfNoteMarker> markers;
}

class ReaderNoteRef {
  const ReaderNoteRef({
    required this.bookId,
    required this.kind,
    required this.noteKey,
  });

  final String bookId;
  final ReaderNoteKind kind;
  final String noteKey;
}

class ExcerptItem {
  const ExcerptItem({
    required this.ref,
    required this.book,
    required this.chapterIndex,
    required this.startOffset,
    required this.chapterTitle,
    required this.createdAt,
    required this.quote,
    required this.comment,
    this.anchor,
  });

  final ReaderNoteRef ref;
  final Book book;
  final int chapterIndex;
  final int startOffset;
  final String chapterTitle;
  final int createdAt;
  final String quote;
  final String comment;
  final ReaderAnchor? anchor;

  bool get isComment => ref.kind == ReaderNoteKind.comment;
}

abstract interface class BookshelfRepository {
  Future<List<Map<String, dynamic>>> loadNotes(
    String bookId,
    ReaderNoteKind kind,
  );
  Future<void> saveNotes(
    String bookId,
    ReaderNoteKind kind,
    List<Map<String, dynamic>> notes,
  );
  Stream<List<Book>> watchBooks();
  Future<Book> importBytes(
    Uint8List bytes,
    String fileName, {
    BookSource source,
  });
  Future<BookImportResult> importBytesWithResult(
    Uint8List bytes,
    String fileName, {
    BookSource source,
  });
  Future<BookContent> openBook(Book book);
  Future<void> saveLocation(String bookId, ReadingLocation location);
  Future<void> removeBook(String bookId);
  Future<ReaderSettings> loadSettings();
  Future<void> saveSettings(ReaderSettings settings);
  Future<void> syncCatalogTags(String bookId, Map<String, String?> tags);
}

/// Optional aggregate queries used by the enhanced shelf. Keeping these in a
/// companion interface preserves compatibility with custom repositories.
abstract interface class BookshelfInsightsRepository {
  Stream<List<ShelfEntry>> watchShelfEntries();
  Stream<List<ExcerptItem>> watchExcerpts();
  Future<List<ExcerptItem>> loadExcerpts();
  Future<void> deleteReaderNote(ReaderNoteRef ref);
}

abstract interface class PublicationFileRepository {
  Future<String> publicationPath(Book book);
}

class BookImportResult {
  const BookImportResult({required this.book, required this.isDuplicate});
  final Book book;
  final bool isDuplicate;
}

Future<BookContent> _parseLocal((Uint8List, String) input) =>
    LocalBookParser().parse(input.$1, input.$2);

class LocalBookshelfRepository
    implements
        BookshelfRepository,
        BookshelfInsightsRepository,
        PublicationFileRepository,
        BookLayoutRepository,
        BookCoverPaginationRepository {
  @override
  Future<String> publicationPath(Book book) async =>
      p.join(directory.path, book.fileName);

  /// Version of the on-disk cache JSON and chapter files.
  static const cacheFormatVersion = 2;

  /// Version of parser-derived output (titles, TOC and anchors). Increment
  /// only when a parser change makes an existing parsed result stale.
  static const parserRevision = 7;

  static const _maxCoverBytes = 10 * 1024 * 1024;
  LocalBookshelfRepository._(this.directory, this._db, this.parser);
  final Directory directory;
  final Database _db;
  final BookParser parser;
  final _changes = StreamController<void>.broadcast();
  final _memoryCache = <String, BookContent>{};
  Future<void> _queue = Future.value();

  final _coverPagination = <String, Future<BookCoverPagination>>{};
  Future<void> _coverQueue = Future.value();

  @override
  Future<BookCoverPagination> loadCoverPagination(String bookId) =>
      _coverPagination.putIfAbsent(bookId, () {
        final result = _coverQueue.then((_) async {
          final rows = await _db.query(
            'books',
            where: 'id = ? AND is_hidden = 0',
            whereArgs: [bookId],
          );
          if (rows.isEmpty) throw const FormatException('图书已移除');
          final book = _book(rows.single);
          final content = await openBook(book);
          final file = File(
            p.join(directory.path, 'cache', bookId, 'cover_pages.json'),
          );
          if (await file.exists()) {
            try {
              final data =
                  jsonDecode(await file.readAsString()) as Map<String, dynamic>;
              if (data['version'] == 1 &&
                  data['parserRevision'] == parserRevision) {
                return BookCoverPagination.fromJson(data);
              }
            } catch (_) {
              /* Rebuild a partial or obsolete cache. */
            }
          }
          final pages = <List<int>>[];
          for (var i = 0; i < content.chapters.length; i++) {
            final chapter = content is LayoutBookContent
                ? await content.readOriginalChapter(i)
                : await content.readChapter(i);
            pages.add(
              Platform.environment['FLUTTER_TEST'] == 'true'
                  ? paginateCoverChapter(chapter)
                  : await compute(paginateCoverChapter, chapter),
            );
          }
          final pagination = BookCoverPagination(pages);
          try {
            await file.parent.create(recursive: true);
            await file.writeAsString(
              jsonEncode({
                ...pagination.toJson(),
                'parserRevision': parserRevision,
              }),
            );
          } catch (_) {
            /* The in-memory result remains usable without disk caching. */
          }
          return pagination;
        });
        _coverQueue = result.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            _coverPagination.remove(bookId);
          },
        );
        return result;
      });

  static Future<LocalBookshelfRepository> create({
    Directory? directory,
    DatabaseFactory? factory,
    BookParser? parser,
  }) async {
    final root = directory ?? await _defaultDirectory();
    await root.create(recursive: true);
    final db = await (factory ?? databaseFactory).openDatabase(
      p.join(root.path, 'reader.sqlite'),
      options: OpenDatabaseOptions(
        version: 10,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE books (id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL, format TEXT NOT NULL, source TEXT NOT NULL, file_name TEXT NOT NULL, cover_file_name TEXT, cover_checked INTEGER NOT NULL DEFAULT 0, cache_ready INTEGER NOT NULL DEFAULT 0, added_at INTEGER NOT NULL, last_read_at INTEGER, chapter INTEGER NOT NULL DEFAULT 0, block INTEGER NOT NULL DEFAULT 0, progress REAL NOT NULL DEFAULT 0, char_offset INTEGER, is_hidden INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute(
            'CREATE TABLE settings (id INTEGER PRIMARY KEY, font_size REAL NOT NULL, dark INTEGER NOT NULL, options TEXT)',
          );
          await _createNotesTable(db);
          await _createNotesIndexes(db);
          await _createTagsTables(db);
          await db.execute('ALTER TABLE books ADD COLUMN anchor_json TEXT');
        },
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 10) {
            await db.execute('ALTER TABLE books ADD COLUMN anchor_json TEXT');
          }
          if (oldVersion < 9) {
            await db.execute(
              'ALTER TABLE books ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (oldVersion < 7) await _createTagsTables(db);
          if (oldVersion < 6) {
            await db.execute(
              'ALTER TABLE books ADD COLUMN last_read_at INTEGER',
            );
          }
          if (oldVersion < 5) await _createNotesTable(db);
          if (oldVersion >= 5 && oldVersion < 8) {
            await _addNotesQueryColumns(db);
            await _backfillNotesQueryColumns(db);
          }
          if (oldVersion < 8) await _createNotesIndexes(db);
          if (oldVersion < 4) {
            await db.execute(
              'ALTER TABLE books ADD COLUMN char_offset INTEGER',
            );
            await db.execute('ALTER TABLE settings ADD COLUMN options TEXT');
          }
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE books ADD COLUMN cover_file_name TEXT',
            );
            await db.execute(
              'ALTER TABLE books ADD COLUMN cover_checked INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (oldVersion < 3) {
            await db.execute(
              'ALTER TABLE books ADD COLUMN cache_ready INTEGER NOT NULL DEFAULT 0',
            );
          }
        },
      ),
    );
    final repository = LocalBookshelfRepository._(
      root,
      db,
      parser ?? LocalBookParser(),
    );
    await repository._ensureHiddenBooksSchema();
    await repository._repairEncodedTxtTitles();
    return repository;
  }

  Future<void> _ensureHiddenBooksSchema() async {
    final columns = await _db.rawQuery('PRAGMA table_info(books)');
    if (columns.any((column) => column['name'] == 'is_hidden')) return;
    await _db.execute(
      'ALTER TABLE books ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0',
    );
  }

  static Future<void> _createNotesTable(Database db) => db.execute(
    'CREATE TABLE reader_notes (book_id TEXT NOT NULL, kind TEXT NOT NULL, '
    'note_key TEXT NOT NULL, payload TEXT NOT NULL, '
    'created_at INTEGER NOT NULL DEFAULT 0, '
    'chapter_index INTEGER NOT NULL DEFAULT 0, '
    'start_offset INTEGER NOT NULL DEFAULT 0, '
    'display_text TEXT NOT NULL DEFAULT \'\', '
    'quote_text TEXT NOT NULL DEFAULT \'\', '
    'PRIMARY KEY (book_id, kind, note_key))',
  );

  static Future<void> _addNotesQueryColumns(Database db) async {
    await db.execute(
      'ALTER TABLE reader_notes ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE reader_notes ADD COLUMN chapter_index INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE reader_notes ADD COLUMN start_offset INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      "ALTER TABLE reader_notes ADD COLUMN display_text TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE reader_notes ADD COLUMN quote_text TEXT NOT NULL DEFAULT ''",
    );
  }

  static Future<void> _createNotesIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS reader_notes_book_created '
      'ON reader_notes(book_id, created_at DESC, note_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS reader_notes_kind_created '
      'ON reader_notes(kind, created_at DESC, note_key)',
    );
  }

  static Map<String, Object?> _queryFields(
    ReaderNoteKind kind,
    Map<String, dynamic> note,
  ) => <String, Object?>{
    'created_at': note['createdAt'] as int? ?? 0,
    'chapter_index': note['chapterIndex'] as int? ?? 0,
    'start_offset': kind == ReaderNoteKind.bookmark
        ? note['charOffset'] as int? ?? 0
        : note['start'] as int? ?? 0,
    'display_text': kind == ReaderNoteKind.bookmark
        ? note['excerpt'] as String? ?? ''
        : kind == ReaderNoteKind.underline
        ? note['text'] as String? ?? ''
        : note['text'] as String? ?? '',
    'quote_text': kind == ReaderNoteKind.comment
        ? note['quote'] as String? ?? ''
        : '',
  };

  static Future<void> _backfillNotesQueryColumns(Database db) async {
    final rows = await db.query('reader_notes');
    final batch = db.batch();
    for (final row in rows) {
      try {
        final kind = ReaderNoteKind.values.byName(row['kind'] as String);
        final note =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        batch.update(
          'reader_notes',
          _queryFields(kind, note),
          where: 'book_id = ? AND kind = ? AND note_key = ?',
          whereArgs: [row['book_id'], row['kind'], row['note_key']],
        );
      } catch (_) {
        // Preserve malformed legacy payloads; aggregate views will ignore them.
      }
    }
    await batch.commit(noResult: true);
  }

  static Future<void> _createTagsTables(Database db) async {
    await db.execute(
      'CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'name TEXT NOT NULL UNIQUE, color TEXT, created_at INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE book_tags (book_id TEXT NOT NULL, tag_id INTEGER NOT NULL, '
      'is_catalog INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL, '
      'PRIMARY KEY (book_id, tag_id), '
      'FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE, '
      'FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE)',
    );
  }

  @override
  Future<List<Map<String, dynamic>>> loadNotes(
    String bookId,
    ReaderNoteKind kind,
  ) => _serial(() async {
    final rows = await _db.query(
      'reader_notes',
      where: 'book_id = ? AND kind = ?',
      whereArgs: [bookId, kind.name],
      orderBy: 'rowid',
    );
    return rows
        .map(
          (row) => jsonDecode(row['payload'] as String) as Map<String, dynamic>,
        )
        .toList();
  });

  @override
  Future<void> saveNotes(
    String bookId,
    ReaderNoteKind kind,
    List<Map<String, dynamic>> notes,
  ) {
    // Snapshot before queuing: callers may reuse and mutate their lists.
    final rows = notes
        .map(
          (note) => <String, Object?>{
            'book_id': bookId,
            'kind': kind.name,
            'note_key':
                note['id'] as String? ??
                (kind == ReaderNoteKind.bookmark
                    ? '${note['chapterIndex']}:${note['charOffset']}'
                    : '${note['chapterIndex']}:${note['start']}:${note['end']}'
                          '${kind == ReaderNoteKind.comment ? ':${note['createdAt']}' : ''}'),
            'payload': jsonEncode(note),
            ..._queryFields(kind, note),
          },
        )
        .toList();
    return _serial(
      () => _db.transaction((txn) async {
        // A queued write must not resurrect notes after a book was removed.
        if ((await txn.query(
          'books',
          columns: ['id'],
          where: 'id = ? AND is_hidden = 0',
          whereArgs: [bookId],
        )).isEmpty) {
          throw StateError('图书已移除，无法保存笔记');
        }
        await txn.delete(
          'reader_notes',
          where: 'book_id = ? AND kind = ?',
          whereArgs: [bookId, kind.name],
        );
        final batch = txn.batch();
        for (final row in rows) {
          batch.insert(
            'reader_notes',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }),
    ).then((_) => _changes.add(null));
  }

  static Future<Directory> _defaultDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final directory = Directory(p.join(supportDirectory.path, 'reader'));
    final legacyDirectory = Directory(
      p.join(supportDirectory.path, 'offline_reader'),
    );
    if (!await directory.exists() && await legacyDirectory.exists()) {
      // Preserve books imported before the module was renamed.
      await legacyDirectory.rename(directory.path);
    }
    return directory;
  }

  static String _decodeStoredTitle(String value) {
    final candidate = value.replaceAll('+', ' ');
    if (RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(candidate)) return value;
    try {
      final decoded = Uri.decodeComponent(candidate).trim();
      return decoded.isEmpty ? value : decoded;
    } catch (_) {
      return value;
    }
  }

  Future<void> _repairEncodedTxtTitles() async {
    final rows = await _db.query(
      'books',
      columns: ['id', 'title', 'format'],
      where: 'format = ?',
      whereArgs: ['txt'],
    );
    for (final row in rows) {
      final oldTitle = row['title'] as String;
      final newTitle = _decodeStoredTitle(oldTitle);
      if (newTitle != oldTitle) {
        await _db.update(
          'books',
          {'title': newTitle},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _notifyChanges() {
    if (_changes.isClosed) return;
    try {
      _changes.add(null);
    } catch (_) {
      // Persistence has already completed. A disposed observer must not make
      // the caller believe that its write failed.
    }
  }

  Book _book(Map<String, Object?> row) => Book(
    id: row['id'] as String,
    title: row['title'] as String,
    author: row['author'] as String,
    format: BookFormat.values.byName(row['format'] as String),
    source: BookSource.values.byName(row['source'] as String),
    fileName: row['file_name'] as String,
    coverPath: row['cover_file_name'] == null
        ? null
        : p.join(directory.path, row['cover_file_name'] as String),
    cacheReady: row['cache_ready'] == 1,
    addedAt: DateTime.fromMillisecondsSinceEpoch(row['added_at'] as int),
    lastReadAt: row['last_read_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['last_read_at'] as int),
    location: ReadingLocation(
      anchor: row['anchor_json'] == null
          ? null
          : ReaderAnchor.fromJson(jsonDecode(row['anchor_json'] as String)),
      chapter: row['chapter'] as int,
      block: row['block'] as int,
      charOffset: row['char_offset'] as int?,
      progress: (row['progress'] as num).toDouble(),
    ),
  );

  Future<List<Book>> _booksWithTags(List<Map<String, Object?>> rows) async {
    final result = <Book>[];
    for (final row in rows) {
      final book = _book(row);
      final tagRows = await _db.rawQuery(
        'SELECT tags.id, tags.name, tags.color FROM tags '
        'JOIN book_tags ON book_tags.tag_id = tags.id '
        'WHERE book_tags.book_id = ? ORDER BY tags.name',
        [book.id],
      );
      result.add(
        Book(
          id: book.id,
          title: book.title,
          author: book.author,
          format: book.format,
          source: book.source,
          fileName: book.fileName,
          addedAt: book.addedAt,
          coverPath: book.coverPath,
          cacheReady: book.cacheReady,
          location: book.location,
          lastReadAt: book.lastReadAt,
          tags: [
            for (final tag in tagRows)
              BookTag(
                id: tag['id'] as int,
                name: tag['name'] as String,
                color: tag['color'] as String?,
              ),
          ],
        ),
      );
    }
    return result;
  }

  @override
  Stream<List<Book>> watchBooks() {
    late StreamController<List<Book>> controller;
    StreamSubscription<void>? subscription;
    Future<void> pending = Future.value();
    void refresh() {
      pending = pending.then((_) async {
        try {
          await _cachePendingCovers();
          final rows = await _db.query(
            'books',
            where: 'is_hidden = 0',
            orderBy:
                'last_read_at IS NULL, last_read_at DESC, added_at DESC, title',
          );
          if (!controller.isClosed) {
            controller.add(await _booksWithTags(rows));
          }
        } catch (e, st) {
          if (!controller.isClosed) controller.addError(e, st);
        }
      });
    }

    controller = StreamController<List<Book>>(
      onListen: () {
        subscription = _changes.stream.listen((_) => refresh());
        refresh();
      },
      onCancel: () async {
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  Future<List<Book>> _loadBooksForShelf() async {
    await _cachePendingCovers();
    final rows = await _db.query(
      'books',
      where: 'is_hidden = 0',
      orderBy: 'last_read_at IS NULL, last_read_at DESC, added_at DESC, title',
    );
    return _booksWithTags(rows);
  }

  @override
  Stream<List<ShelfEntry>> watchShelfEntries() {
    late StreamController<List<ShelfEntry>> controller;
    StreamSubscription<void>? subscription;
    Future<void> pending = Future<void>.value();
    void refresh() {
      pending = pending.then((_) async {
        try {
          final books = await _loadBooksForShelf();
          final rows = await _db.query(
            'reader_notes',
            columns: ['book_id', 'kind', 'note_key', 'created_at'],
            orderBy: 'created_at DESC, note_key DESC',
          );
          final counts = <String, int>{};
          final markers = <String, List<ShelfNoteMarker>>{};
          for (final row in rows) {
            final bookId = row['book_id'] as String;
            counts[bookId] = (counts[bookId] ?? 0) + 1;
            final list = markers.putIfAbsent(bookId, () => []);
            try {
              list.add(
                ShelfNoteMarker(
                  kind: ReaderNoteKind.values.byName(row['kind'] as String),
                  noteKey: row['note_key'] as String,
                  createdAt: row['created_at'] as int? ?? 0,
                ),
              );
            } catch (_) {
              // Ignore unknown legacy kinds in the visual aggregate.
            }
          }
          if (!controller.isClosed) {
            controller.add([
              for (final book in books)
                ShelfEntry(
                  book: book,
                  noteCount: counts[book.id] ?? 0,
                  markers: List.unmodifiable(markers[book.id] ?? const []),
                ),
            ]);
          }
        } catch (error, stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        }
      });
    }

    controller = StreamController<List<ShelfEntry>>(
      onListen: () {
        subscription = _changes.stream.listen((_) => refresh());
        refresh();
      },
      onCancel: () async => subscription?.cancel(),
    );
    return controller.stream;
  }

  @override
  Future<List<ExcerptItem>> loadExcerpts() async {
    final books = await _loadBooksForShelf();
    final byId = {for (final book in books) book.id: book};
    final rows = await _db.rawQuery(
      "SELECT book_id, kind, note_key, payload, created_at, chapter_index, "
      "start_offset, display_text, quote_text FROM reader_notes "
      "WHERE kind IN ('underline', 'comment') "
      "AND (display_text <> '' OR quote_text <> '') "
      'ORDER BY created_at DESC, note_key DESC',
    );
    final result = <ExcerptItem>[];
    for (final row in rows) {
      final book = byId[row['book_id'] as String];
      if (book == null) continue;
      try {
        final kind = ReaderNoteKind.values.byName(row['kind'] as String);
        final payload =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        result.add(
          ExcerptItem(
            ref: ReaderNoteRef(
              bookId: book.id,
              kind: kind,
              noteKey: row['note_key'] as String,
            ),
            book: book,
            anchor: ReaderAnchor.fromJson(payload['anchor']),
            chapterIndex: row['chapter_index'] as int? ?? 0,
            startOffset: row['start_offset'] as int? ?? 0,
            chapterTitle: payload['chapterTitle'] as String? ?? '',
            createdAt: row['created_at'] as int? ?? 0,
            quote: kind == ReaderNoteKind.comment
                ? row['quote_text'] as String? ?? ''
                : row['display_text'] as String? ?? '',
            comment: kind == ReaderNoteKind.comment
                ? row['display_text'] as String? ?? ''
                : '',
          ),
        );
      } catch (_) {
        // Ignore malformed legacy rows without breaking the complete feed.
      }
    }
    return result;
  }

  @override
  Stream<List<ExcerptItem>> watchExcerpts() {
    late StreamController<List<ExcerptItem>> controller;
    StreamSubscription<void>? subscription;
    Future<void> pending = Future<void>.value();
    void refresh() {
      pending = pending.then((_) async {
        try {
          final items = await loadExcerpts();
          if (!controller.isClosed) controller.add(items);
        } catch (error, stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        }
      });
    }

    controller = StreamController<List<ExcerptItem>>(
      onListen: () {
        subscription = _changes.stream.listen((_) => refresh());
        refresh();
      },
      onCancel: () async => subscription?.cancel(),
    );
    return controller.stream;
  }

  @override
  Future<void> deleteReaderNote(ReaderNoteRef ref) => _serial(() async {
    await _db.delete(
      'reader_notes',
      where: 'book_id = ? AND kind = ? AND note_key = ?',
      whereArgs: [ref.bookId, ref.kind.name, ref.noteKey],
    );
    _changes.add(null);
  });

  Future<BookContent> _parse(Uint8List bytes, String name) =>
      parser is LocalBookParser
      ? compute(_parseLocal, (bytes, name))
      : parser.parse(bytes, name);

  Future<Book> importFile(
    File file, {
    BookSource source = BookSource.imported,
  }) async {
    return (await importFileWithResult(file, source: source)).book;
  }

  Future<BookImportResult> importFileWithResult(
    File file, {
    BookSource source = BookSource.imported,
  }) async {
    if (await file.length() > LocalBookParser.maxFileBytes) {
      throw const FormatException('图书超过 50 MB 导入上限');
    }
    return importBytesWithResult(
      await file.readAsBytes(),
      p.basename(file.path),
      source: source,
    );
  }

  /// Built-in assets and future completed downloads enter through this same API.
  @override
  Future<Book> importBytes(
    Uint8List bytes,
    String fileName, {
    BookSource source = BookSource.imported,
  }) async =>
      (await importBytesWithResult(bytes, fileName, source: source)).book;

  @override
  Future<BookImportResult> importBytesWithResult(
    Uint8List bytes,
    String fileName, {
    BookSource source = BookSource.imported,
  }) => _serial(() async {
    if (bytes.length > LocalBookParser.maxFileBytes) {
      throw const FormatException('图书超过 50 MB 导入上限');
    }
    final extension = p.extension(fileName).toLowerCase();
    if (extension != '.txt' && extension != '.epub' && extension != '.md') {
      throw const FormatException('请选择 EPUB、TXT 或 Markdown（MD）文件');
    }
    final id = sha256.convert(bytes).toString();
    final existing = await _db.query('books', where: 'id = ?', whereArgs: [id]);
    if (existing.isNotEmpty) {
      final hidden = existing.first['is_hidden'] == 1;
      if (!hidden || source == BookSource.builtIn) {
        return BookImportResult(book: _book(existing.first), isDuplicate: true);
      }
      // An explicit user import restores a previously hidden bundled book.
      await _db.transaction((txn) async {
        await txn.delete('book_tags', where: 'book_id = ?', whereArgs: [id]);
        await txn.delete('books', where: 'id = ?', whereArgs: [id]);
      });
    }
    final content = await _parse(bytes, fileName);
    final cacheReady = await _writeCache(id, content);
    final storedName = '$id$extension';
    final file = File(p.join(directory.path, storedName));
    final temporary = File('${file.path}.tmp');
    File? coverFile;
    File? temporaryCover;
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
      final cover = await content.cover();
      String? coverFileName;
      if (cover != null && cover.isNotEmpty && cover.length <= _maxCoverBytes) {
        coverFileName = p.join('covers', '$id.cover');
        coverFile = File(p.join(directory.path, coverFileName));
        temporaryCover = File('${coverFile.path}.tmp');
        await coverFile.parent.create(recursive: true);
        await temporaryCover.writeAsBytes(cover, flush: true);
        await temporaryCover.rename(coverFile.path);
      }
      final row = <String, Object?>{
        'id': id,
        'title': _decodeStoredTitle(content.title),
        'author': content.author,
        'format': extension.substring(1),
        'source': source.name,
        'file_name': storedName,
        'cover_file_name': coverFileName,
        'cover_checked': 1,
        'cache_ready': cacheReady ? 1 : 0,
        'added_at': DateTime.now().millisecondsSinceEpoch,
        'last_read_at': null,
        'chapter': 0,
        'block': 0,
        'progress': 0.0,
        'is_hidden': 0,
      };
      await _db.insert('books', row);
      _changes.add(null);
      return BookImportResult(book: _book(row), isDuplicate: false);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      if (await file.exists()) await file.delete();
      if (temporaryCover != null && await temporaryCover.exists()) {
        await temporaryCover.delete();
      }
      if (coverFile != null && await coverFile.exists()) {
        await coverFile.delete();
      }
      rethrow;
    }
  });

  @override
  Future<BookContent> openBook(Book book) async {
    final inMemory = _memoryCache[book.id];
    bool correctTitle(BookContent content) =>
        book.format == BookFormat.epub ||
        content.title == _decodeStoredTitle(book.title);
    if (inMemory != null && correctTitle(inMemory)) {
      return _withLayout(book, inMemory);
    }
    final cached = await _readCache(book.id, book: book);
    if (cached != null && correctTitle(cached)) {
      _memoryCache[book.id] = cached;
      if (!book.cacheReady) {
        await _db.update(
          'books',
          {'cache_ready': 1},
          where: 'id = ?',
          whereArgs: [book.id],
        );
        _changes.add(null);
      }
      return _withLayout(book, cached);
    }
    final file = File(p.join(directory.path, book.fileName));
    if (!await file.exists()) {
      throw const FormatException('本地图书文件不存在，请移除后重新导入');
    }
    // Managed filenames are content hashes. Preserve TXT/MD fallback titles
    // from shelf metadata, encoding separators before the parser takes basename.
    final parsingName = book.format == BookFormat.epub
        ? book.fileName
        : '${Uri.encodeComponent(_decodeStoredTitle(book.title))}${p.extension(book.fileName)}';
    final content = await _parse(await file.readAsBytes(), parsingName);
    if (await _writeCache(book.id, content)) {
      await _db.update(
        'books',
        {'cache_ready': 1},
        where: 'id = ?',
        whereArgs: [book.id],
      );
      _changes.add(null);
    }
    final rebuilt = await _readCache(book.id, book: book);
    final result = rebuilt != null && correctTitle(rebuilt) ? rebuilt : content;
    _memoryCache[book.id] = result;
    return _withLayout(book, result);
  }

  @override
  Future<void> saveBookLayout(String bookId, BookLayout layout) =>
      _serial(() async {
        if (layout.sourceHash != bookId ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(bookId)) {
          throw const FormatException('目录与图书内容不匹配');
        }
        final file = File(p.join(directory.path, 'layouts', '$bookId.json'));
        await file.parent.create(recursive: true);
        final json = jsonEncode(layout.toJson());
        if (await file.exists() && await file.readAsString() == json) return;
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(json, flush: true);
        await temporary.rename(file.path);
      });

  Future<BookContent> _withLayout(Book book, BookContent content) async {
    final file = File(p.join(directory.path, 'layouts', '${book.id}.json'));
    if (!await file.exists()) return content;
    final layout = BookLayout.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
    if (layout.sourceHash != book.id ||
        layout.headings.any((h) => h.chapter >= content.chapters.length)) {
      throw const FormatException('图书目录与缓存不匹配');
    }
    return LayoutBookContent(content, layout);
  }

  @override
  Future<void> saveLocation(String bookId, ReadingLocation location) =>
      _serial(() async {
        await _db.update(
          'books',
          {
            'chapter': location.chapter,
            'block': location.block,
            'char_offset': location.charOffset,
            'anchor_json': location.anchor == null
                ? null
                : jsonEncode(location.anchor!.toJson()),
            'progress': location.progress.clamp(0, 1),
            'last_read_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ? AND is_hidden = 0',
          whereArgs: [bookId],
        );
        _changes.add(null);
      });

  @override
  Future<void> removeBook(String bookId) => _serial(() async {
    // Also repairs a database kept open across a development hot reload, where
    // the normal versioned onUpgrade callback has not run yet.
    await _ensureHiddenBooksSchema();
    final rows = await _db.query('books', where: 'id = ?', whereArgs: [bookId]);
    if (rows.isEmpty) return;
    final row = rows.first;
    final builtIn = row['source'] == BookSource.builtIn.name;
    await _db.transaction((txn) async {
      await txn.delete(
        'reader_notes',
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      await txn.delete('book_tags', where: 'book_id = ?', whereArgs: [bookId]);
      if (builtIn) {
        // Keep a tombstone so startup asset synchronization does not restore a
        // bundled book that the user deliberately removed.
        await txn.update(
          'books',
          {'is_hidden': 1, 'cache_ready': 0},
          where: 'id = ?',
          whereArgs: [bookId],
        );
      } else {
        await txn.delete('books', where: 'id = ?', whereArgs: [bookId]);
      }
    });
    // The transaction above is the success boundary. Everything below is
    // cache invalidation or best-effort cleanup and cannot reverse the write.
    _memoryCache.remove(bookId);
    _coverPagination.remove(bookId);
    _notifyChanges();
    try {
      final file = File(p.join(directory.path, row['file_name'] as String));
      if (await file.exists()) await file.delete();
      final coverFileName = row['cover_file_name'] as String?;
      if (coverFileName != null) {
        final cover = File(p.join(directory.path, coverFileName));
        if (await cover.exists()) await cover.delete();
      }
      final cache = Directory(p.join(directory.path, 'cache', bookId));
      if (await cache.exists()) await cache.delete(recursive: true);
    } catch (_) {
      // The hidden/deleted database row prevents stale private files from
      // resurfacing. Platform cleanup can reclaim them later.
    }
  });

  @override
  Future<ReaderSettings> loadSettings() async {
    final rows = await _db.query('settings', where: 'id = 1');
    if (rows.isEmpty) return const ReaderSettings();
    final options = rows.first['options'] == null
        ? <String, dynamic>{}
        : jsonDecode(rows.first['options'] as String) as Map<String, dynamic>;
    return ReaderSettings(
      theme: options['theme'] as String? ?? 'yellow',
      flipMode: options['flipMode'] as String? ?? 'scrollVertical',
      epubScroll: options['epubScroll'] as bool? ?? true,
      lineHeight: (options['lineHeight'] as num?)?.toDouble() ?? 1.8,
      paragraphSpacing: (options['paragraphSpacing'] as num?)?.toDouble() ?? 8,
      firstLineIndent: options['firstLineIndent'] as int? ?? 2,
      justify: options['justify'] as bool? ?? true,
      dimLevel: (options['dimLevel'] as num?)?.toDouble() ?? 0,
      fontFamily: options['fontFamily'] as String?,
      fontSize: (rows.first['font_size'] as num).toDouble().clamp(14, 32),
      dark: rows.first['dark'] == 1,
    );
  }

  @override
  Future<void> saveSettings(ReaderSettings settings) => _serial(() async {
    await _db.insert('settings', {
      'id': 1,
      'font_size': settings.fontSize,
      'dark': settings.dark ? 1 : 0,
      'options': jsonEncode(settings.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  @override
  Future<void> syncCatalogTags(String bookId, Map<String, String?> tags) =>
      _serial(() async {
        await _db.transaction((txn) async {
          final desired = <String, String?>{
            for (final entry in tags.entries)
              if (entry.key.trim().isNotEmpty) entry.key.trim(): entry.value,
          };
          final desiredIds = <int>[];
          for (final entry in desired.entries) {
            final name = entry.key;
            await txn.insert('tags', {
              'name': name,
              'color': entry.value,
              'created_at': DateTime.now().millisecondsSinceEpoch,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
            final row = (await txn.query(
              'tags',
              where: 'name = ?',
              whereArgs: [name],
            )).single;
            final tagId = row['id'] as int;
            desiredIds.add(tagId);
            await txn.update(
              'tags',
              {'color': entry.value},
              where: 'id = ?',
              whereArgs: [tagId],
            );
            await txn.insert('book_tags', {
              'book_id': bookId,
              'tag_id': tagId,
              'is_catalog': 1,
              'created_at': DateTime.now().millisecondsSinceEpoch,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          final existing = await txn.query(
            'book_tags',
            columns: ['tag_id'],
            where: 'book_id = ? AND is_catalog = 1',
            whereArgs: [bookId],
          );
          for (final row in existing) {
            final tagId = row['tag_id'] as int;
            if (!desiredIds.contains(tagId)) {
              await txn.delete(
                'book_tags',
                where: 'book_id = ? AND tag_id = ? AND is_catalog = 1',
                whereArgs: [bookId, tagId],
              );
            }
          }
        });
        _changes.add(null);
      });

  Future<void> _cachePendingCovers() => _serial(() async {
    final rows = await _db.query(
      'books',
      columns: ['id', 'file_name'],
      where: 'format = ? AND cover_checked = 0 AND is_hidden = 0',
      whereArgs: [BookFormat.epub.name],
    );
    for (final row in rows) {
      final id = row['id'] as String;
      String? coverFileName;
      try {
        final file = File(p.join(directory.path, row['file_name'] as String));
        if (await file.exists()) {
          final content = await _parse(await file.readAsBytes(), file.path);
          final cover = await content.cover();
          if (cover != null &&
              cover.isNotEmpty &&
              cover.length <= _maxCoverBytes) {
            coverFileName = await _writeCover(id, cover);
          }
        }
      } catch (_) {
        // 旧书籍无法提取封面时，仍可继续阅读其原始文件。
      }
      await _db.update(
        'books',
        {'cover_file_name': coverFileName, 'cover_checked': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  });

  Future<String> _writeCover(String id, Uint8List bytes) async {
    final fileName = p.join('covers', '$id.cover');
    final file = File(p.join(directory.path, fileName));
    final temporary = File('${file.path}.tmp');
    await file.parent.create(recursive: true);
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    return fileName;
  }

  Future<bool> _writeCache(String id, BookContent content) async {
    if (content is! MemoryBookContent) return false;
    final cache = Directory(p.join(directory.path, 'cache', id));
    try {
      if (await cache.exists()) await cache.delete(recursive: true);
      final resources = Directory(p.join(cache.path, 'resources'));
      await resources.create(recursive: true);
      final paths = <String>{
        for (final chapter in content.chapters)
          for (final block in chapter.blocks) ..._resourcePaths(block),
        if (content.coverResourcePath != null) content.coverResourcePath!,
      };
      for (final path in paths) {
        final safePath = _safeResourcePath(path);
        final bytes = content.resources[path];
        if (safePath == null || bytes == null) continue;
        final file = File(p.join(resources.path, safePath));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      }
      final chapterDirectory = Directory(p.join(cache.path, 'chapters'));
      await chapterDirectory.create();
      for (var i = 0; i < content.chapters.length; i++) {
        await File(
          p.join(chapterDirectory.path, '$i.json'),
        ).writeAsString(jsonEncode(content.chapters[i].blocks), flush: true);
      }
      final manifest = <String, Object?>{
        'version': cacheFormatVersion,
        'parserRevision': parserRevision,
        'title': content.title,
        'author': content.author,
        'coverResourcePath': content.coverResourcePath,
        'chapters': [
          for (final chapter in content.chapters)
            {
              'id': chapter.id,
              'title': chapter.title,
              'kind': chapter.kind.name,
            },
        ],
        'toc': _tocToJson(content.toc),
      };
      await File(
        p.join(cache.path, 'content.json'),
      ).writeAsString(jsonEncode(manifest), flush: true);
      return true;
    } catch (_) {
      if (await cache.exists()) await cache.delete(recursive: true);
      return false;
    }
  }

  Future<BookContent?> _readCache(String id, {Book? book}) async {
    final cache = Directory(p.join(directory.path, 'cache', id));
    final manifest = File(p.join(cache.path, 'content.json'));
    try {
      if (!await manifest.exists()) return null;
      final data = jsonDecode(await manifest.readAsString());
      if (data is! Map<String, dynamic> ||
          data['version'] != cacheFormatVersion ||
          data['parserRevision'] != parserRevision) {
        return null;
      }
      if (book != null && book.format != BookFormat.epub) {
        final storedTitle = p.basenameWithoutExtension(book.fileName);
        // Repair only reader-generated hash titles, leaving genuine headings,
        // body text and note offsets untouched.
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(storedTitle) &&
            book.title != storedTitle) {
          var changed = false;
          final generatedTitle = RegExp(
            '^${RegExp.escape(storedTitle)}( · [0-9]+)?\$',
          );
          void repair(dynamic value) {
            if (value is Map<String, dynamic>) {
              final title = value['title'];
              if (title is String && generatedTitle.hasMatch(title)) {
                value['title'] =
                    '${book.title}${title.substring(storedTitle.length)}';
                changed = true;
              }
              for (final child in value.values) {
                repair(child);
              }
            } else if (value is List) {
              for (final child in value) {
                repair(child);
              }
            }
          }

          repair(data);
          if (changed) {
            final temporary = File('${manifest.path}.tmp');
            await temporary.writeAsString(jsonEncode(data), flush: true);
            await temporary.rename(manifest.path);
          }
        }
      }
      // A partial cache must be rebuilt from the original file.
      for (var i = 0; i < (data['chapters'] as List).length; i++) {
        if (!await File(p.join(cache.path, 'chapters', '$i.json')).exists()) {
          return null;
        }
      }
      return _CachedBookContent.fromJson(cache, data);
    } catch (_) {
      return null;
    }
  }

  static Iterable<String> _resourcePaths(String markup) sync* {
    final matches = RegExp(
      'data-reader-resource=["\\\']([^"\\\']+)["\\\']',
    ).allMatches(markup);
    for (final match in matches) {
      final path = match.group(1);
      if (path != null) yield path;
    }
  }

  static String? _safeResourcePath(String path) {
    final normalized = p.posix.normalize(path);
    if (normalized.isEmpty ||
        normalized == '.' ||
        normalized.startsWith('../') ||
        p.posix.isAbsolute(normalized)) {
      return null;
    }
    return normalized;
  }

  static List<Map<String, Object?>> _tocToJson(List<BookTocEntry> entries) => [
    for (final entry in entries)
      {
        'id': entry.id,
        'title': entry.title,
        'chapter': entry.chapter,
        'block': entry.block,
        'canonicalCharOffset': entry.canonicalCharOffset,
        'children': _tocToJson(entry.children),
      },
  ];

  Future<void> close() async {
    await _coverQueue;
    await _queue;
    await _changes.close();
    await _db.close();
  }
}

class _CachedBookContent implements OnDemandBookContent {
  _CachedBookContent({
    required this.directory,
    required this.title,
    required this.author,
    required this.chapters,
    required this.toc,
    required this.coverResourcePath,
  });

  factory _CachedBookContent.fromJson(
    Directory directory,
    Map<String, dynamic> json,
  ) {
    final chapters = (json['chapters'] as List<dynamic>? ?? []).map((value) {
      final chapter = value as Map<String, dynamic>;
      return BookChapter(
        id: chapter['id'] as String,
        title: chapter['title'] as String,
        kind: BookChapterKind.values.byName(chapter['kind'] as String),
        blocks: const [],
      );
    }).toList();
    return _CachedBookContent(
      directory: directory,
      title: json['title'] as String,
      author: json['author'] as String,
      chapters: chapters,
      toc: _tocFromJson(json['toc'] as List<dynamic>? ?? const []),
      coverResourcePath: json['coverResourcePath'] as String?,
    );
  }

  @override
  Future<BookChapter> loadChapter(int index) async {
    final metadata = chapters[index];
    final blocks =
        (jsonDecode(
                  await File(
                    p.join(directory.path, 'chapters', '$index.json'),
                  ).readAsString(),
                )
                as List<dynamic>)
            .cast<String>();
    return BookChapter(
      id: metadata.id,
      title: metadata.title,
      kind: metadata.kind,
      blocks: blocks,
    );
  }

  final Directory directory;
  @override
  final String title;
  @override
  final String author;
  @override
  final List<BookChapter> chapters;
  @override
  final List<BookTocEntry> toc;
  final String? coverResourcePath;

  @override
  Future<Uint8List?> resource(String path) async {
    final safePath = LocalBookshelfRepository._safeResourcePath(path);
    if (safePath == null) return null;
    final file = File(p.join(directory.path, 'resources', safePath));
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<Uint8List?> cover() async =>
      coverResourcePath == null ? null : resource(coverResourcePath!);

  static List<BookTocEntry> _tocFromJson(List<dynamic> entries) => [
    for (final value in entries)
      () {
        final entry = value as Map<String, dynamic>;
        return BookTocEntry(
          id: entry['id'] as String,
          title: entry['title'] as String,
          chapter: entry['chapter'] as int?,
          block: entry['block'] as int?,
          canonicalCharOffset: entry['canonicalCharOffset'] as int?,
          children: _tocFromJson(
            entry['children'] as List<dynamic>? ?? const [],
          ),
        );
      }(),
  ];
}

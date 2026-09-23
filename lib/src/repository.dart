import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'parser.dart';

enum ReaderNoteKind { bookmark, underline, comment }

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
}

class BookImportResult {
  const BookImportResult({required this.book, required this.isDuplicate});
  final Book book;
  final bool isDuplicate;
}

Future<BookContent> _parseLocal((Uint8List, String) input) =>
    LocalBookParser().parse(input.$1, input.$2);

class LocalBookshelfRepository implements BookshelfRepository {
  /// Version of the on-disk cache JSON and chapter files.
  static const cacheFormatVersion = 2;

  /// Version of parser-derived output (titles, TOC and anchors). Increment
  /// only when a parser change makes an existing parsed result stale.
  static const parserRevision = 5;

  static const _maxCoverBytes = 10 * 1024 * 1024;
  LocalBookshelfRepository._(this.directory, this._db, this.parser);
  final Directory directory;
  final Database _db;
  final BookParser parser;
  final _changes = StreamController<void>.broadcast();
  final _memoryCache = <String, BookContent>{};
  Future<void> _queue = Future.value();

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
        version: 6,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE books (id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL, format TEXT NOT NULL, source TEXT NOT NULL, file_name TEXT NOT NULL, cover_file_name TEXT, cover_checked INTEGER NOT NULL DEFAULT 0, cache_ready INTEGER NOT NULL DEFAULT 0, added_at INTEGER NOT NULL, last_read_at INTEGER, chapter INTEGER NOT NULL DEFAULT 0, block INTEGER NOT NULL DEFAULT 0, progress REAL NOT NULL DEFAULT 0, char_offset INTEGER)',
          );
          await db.execute(
            'CREATE TABLE settings (id INTEGER PRIMARY KEY, font_size REAL NOT NULL, dark INTEGER NOT NULL, options TEXT)',
          );
          await _createNotesTable(db);
        },
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 6) {
            await db.execute(
              'ALTER TABLE books ADD COLUMN last_read_at INTEGER',
            );
          }
          if (oldVersion < 5) await _createNotesTable(db);
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
    await repository._repairEncodedTxtTitles();
    return repository;
  }

  static Future<void> _createNotesTable(Database db) => db.execute(
    'CREATE TABLE reader_notes (book_id TEXT NOT NULL, kind TEXT NOT NULL, '
    'note_key TEXT NOT NULL, payload TEXT NOT NULL, '
    'PRIMARY KEY (book_id, kind, note_key))',
  );

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
            'note_key': kind == ReaderNoteKind.bookmark
                ? '${note['chapterIndex']}:${note['charOffset']}'
                : '${note['chapterIndex']}:${note['start']}:${note['end']}'
                      '${kind == ReaderNoteKind.comment ? ':${note['createdAt']}' : ''}',
            'payload': jsonEncode(note),
          },
        )
        .toList();
    return _serial(
      () => _db.transaction((txn) async {
        // A queued write must not resurrect notes after a book was removed.
        if ((await txn.query(
          'books',
          columns: ['id'],
          where: 'id = ?',
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
    );
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
      chapter: row['chapter'] as int,
      block: row['block'] as int,
      charOffset: row['char_offset'] as int?,
      progress: (row['progress'] as num).toDouble(),
    ),
  );

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
            orderBy:
                'last_read_at IS NULL, last_read_at DESC, added_at DESC, title',
          );
          if (!controller.isClosed) controller.add(rows.map(_book).toList());
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
    if (extension != '.txt' && extension != '.epub') {
      throw const FormatException('请选择 EPUB 或 TXT 文件');
    }
    final id = sha256.convert(bytes).toString();
    final existing = await _db.query('books', where: 'id = ?', whereArgs: [id]);
    if (existing.isNotEmpty) {
      return BookImportResult(book: _book(existing.first), isDuplicate: true);
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
    if (inMemory != null) return inMemory;
    final cached = await _readCache(book.id);
    if (cached != null) {
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
      return cached;
    }
    final file = File(p.join(directory.path, book.fileName));
    if (!await file.exists()) {
      throw const FormatException('本地图书文件不存在，请移除后重新导入');
    }
    final content = await _parse(await file.readAsBytes(), book.fileName);
    if (await _writeCache(book.id, content)) {
      await _db.update(
        'books',
        {'cache_ready': 1},
        where: 'id = ?',
        whereArgs: [book.id],
      );
      _changes.add(null);
    }
    final result = await _readCache(book.id) ?? content;
    _memoryCache[book.id] = result;
    return result;
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
            'progress': location.progress.clamp(0, 1),
            'last_read_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [bookId],
        );
        _changes.add(null);
      });

  @override
  Future<void> removeBook(String bookId) => _serial(() async {
    final rows = await _db.query('books', where: 'id = ?', whereArgs: [bookId]);
    if (rows.isEmpty) return;
    final file = File(
      p.join(directory.path, rows.first['file_name'] as String),
    );
    if (await file.exists()) await file.delete();
    final coverFileName = rows.first['cover_file_name'] as String?;
    if (coverFileName != null) {
      final cover = File(p.join(directory.path, coverFileName));
      if (await cover.exists()) await cover.delete();
    }
    _memoryCache.remove(bookId);
    final cache = Directory(p.join(directory.path, 'cache', bookId));
    if (await cache.exists()) await cache.delete(recursive: true);
    await _db.transaction((txn) async {
      await txn.delete(
        'reader_notes',
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      await txn.delete('books', where: 'id = ?', whereArgs: [bookId]);
    });
    _changes.add(null);
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

  Future<void> _cachePendingCovers() => _serial(() async {
    final rows = await _db.query(
      'books',
      columns: ['id', 'file_name'],
      where: 'format = ? AND cover_checked = 0',
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

  Future<BookContent?> _readCache(String id) async {
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
        'children': _tocToJson(entry.children),
      },
  ];

  Future<void> close() async {
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
          children: _tocFromJson(
            entry['children'] as List<dynamic>? ?? const [],
          ),
        );
      }(),
  ];
}

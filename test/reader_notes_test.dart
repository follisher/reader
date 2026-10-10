import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:reader/src/reader_notes.dart';
import 'package:reader/src/reader_comment_sheets.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'views_test.dart' show FakeRepository, app, book;

const underline = engine.Underline(
  chapterIndex: 1,
  start: 2,
  end: 12,
  text: '选中文字',
  chapterTitle: '第二章',
  createdAt: 123,
);
const comment = engine.Comment(
  chapterIndex: 1,
  start: 2,
  end: 12,
  quote: '选中文字',
  text: '本地评论',
  chapterTitle: '第二章',
  createdAt: 124,
);
const bookmark = engine.Bookmark(
  chapterIndex: 1,
  charOffset: 2,
  chapterTitle: '第二章',
  createdAt: 125,
);

class FailingNotesRepository extends FakeRepository {
  bool fail = true;
  @override
  Future<void> saveNotes(
    String id,
    ReaderNoteKind kind,
    List<Map<String, dynamic>> notes,
  ) async {
    if (fail) throw StateError('disk full');
    await super.saveNotes(id, kind, notes);
  }
}

void main() {
  test(
    'removed built-in book stays hidden after asset sync and restart',
    () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp(
        'reader-hidden-built-in-',
      );
      final bytes = utf8.encode('第一章\n这是一本文内置图书');
      var repo = await LocalBookshelfRepository.create(
        directory: dir,
        factory: databaseFactoryFfi,
      );
      try {
        final book = await repo.importBytes(
          bytes,
          'built-in.txt',
          source: BookSource.builtIn,
        );
        await repo.saveNotes(book.id, ReaderNoteKind.underline, [
          {
            'chapterIndex': 0,
            'start': 0,
            'end': 2,
            'text': '第一章',
            'createdAt': 1,
          },
        ]);

        await repo.removeBook(book.id);
        expect(await repo.watchBooks().first, isEmpty);
        expect(
          await repo.loadNotes(book.id, ReaderNoteKind.underline),
          isEmpty,
        );
        await repo.close();

        repo = await LocalBookshelfRepository.create(
          directory: dir,
          factory: databaseFactoryFfi,
        );
        final assetSync = await repo.importBytesWithResult(
          bytes,
          'built-in.txt',
          source: BookSource.builtIn,
        );
        expect(assetSync.isDuplicate, isTrue);
        expect(await repo.watchBooks().first, isEmpty);

        final restored = await repo.importBytesWithResult(
          bytes,
          'built-in.txt',
          source: BookSource.imported,
        );
        expect(restored.isDuplicate, isFalse);
        expect((await repo.watchBooks().first).single.id, book.id);
      } finally {
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'SQLite persists all note kinds, isolates books, replaces and removes notes',
    () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('reader-notes-');
      var repo = await LocalBookshelfRepository.create(
        directory: dir,
        factory: databaseFactoryFfi,
      );
      try {
        final a = await repo.importBytes(utf8.encode('第一章 开始\n正文甲'), 'a.txt');
        final b = await repo.importBytes(utf8.encode('第一章 开始\n正文乙'), 'b.txt');
        var notes = RepositoryReaderNotes(repo, a.id, (_) {});
        await notes.underlines.save('external-id', [underline]);
        await notes.comments.save('external-id', [comment]);
        await notes.bookmarks.save('external-id', [bookmark]);
        await repo.close();
        repo = await LocalBookshelfRepository.create(
          directory: dir,
          factory: databaseFactoryFfi,
        );
        notes = RepositoryReaderNotes(repo, a.id, (_) {});
        expect(
          (await notes.underlines.load('external-id')).single.toJson(),
          underline.toJson(),
        );
        expect(
          (await notes.comments.load('external-id')).single.toJson(),
          comment.toJson(),
        );
        expect(
          (await notes.bookmarks.load('external-id')).single.toJson(),
          bookmark.toJson(),
        );
        expect(await repo.loadNotes(b.id, ReaderNoteKind.comment), isEmpty);
        await notes.comments.save(a.id, [comment.copyWith(text: '修改后')]);
        expect(
          (await repo.loadNotes(a.id, ReaderNoteKind.comment)).single['text'],
          '修改后',
        );
        await notes.underlines.save(a.id, []);
        expect(await repo.loadNotes(a.id, ReaderNoteKind.underline), isEmpty);
        await repo.removeBook(a.id);
        for (final kind in ReaderNoteKind.values) {
          expect(await repo.loadNotes(a.id, kind), isEmpty);
        }
        await expectLater(
          repo.saveNotes(a.id, ReaderNoteKind.comment, [comment.toJson()]),
          throwsStateError,
        );
      } finally {
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'shelf aggregates recent markers and excerpt feed deletes one row',
    () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('reader-insights-');
      final repo = await LocalBookshelfRepository.create(
        directory: dir,
        factory: databaseFactoryFfi,
      );
      try {
        final savedBook = await repo.importBytes(
          utf8.encode('第一章 开始\n正文'),
          'insights.txt',
        );
        await repo.saveNotes(savedBook.id, ReaderNoteKind.bookmark, [
          bookmark.toJson(),
        ]);
        await repo.saveNotes(savedBook.id, ReaderNoteKind.underline, [
          underline.toJson(),
          underline.copyWith(start: 20, end: 25, text: '第二条划线').toJson(),
        ]);
        await repo.saveNotes(savedBook.id, ReaderNoteKind.comment, [
          comment.toJson(),
        ]);

        final shelf = await repo.watchShelfEntries().first;
        expect(shelf.single.noteCount, 4);
        expect(shelf.single.markers, hasLength(4));
        expect(shelf.single.markers.first.createdAt, bookmark.createdAt);

        final excerpts = await repo.loadExcerpts();
        expect(excerpts, hasLength(3));
        expect(excerpts.where((item) => item.isComment), hasLength(1));
        final target = excerpts.first;
        await repo.deleteReaderNote(target.ref);
        expect(await repo.loadExcerpts(), hasLength(2));
      } finally {
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'v4 upgrade preserves existing books and settings and creates notes table',
    () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('reader-notes-v4-');
      final db = await databaseFactoryFfi.openDatabase(
        '${dir.path}/reader.sqlite',
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE books (id TEXT PRIMARY KEY, title TEXT, author TEXT, format TEXT, source TEXT, file_name TEXT, cover_file_name TEXT, cover_checked INTEGER, cache_ready INTEGER, added_at INTEGER, chapter INTEGER, block INTEGER, progress REAL, char_offset INTEGER)',
            );
            await db.execute(
              'CREATE TABLE settings (id INTEGER PRIMARY KEY, font_size REAL, dark INTEGER, options TEXT)',
            );
            await db.insert('books', {
              'id': 'old',
              'title': '旧书',
              'author': '',
              'format': 'txt',
              'source': 'imported',
              'file_name': 'old.txt',
              'cover_checked': 1,
              'cache_ready': 0,
              'added_at': 123,
              'chapter': 1,
              'block': 2,
              'progress': .3,
              'char_offset': 7,
            });
            await db.insert('settings', {'id': 1, 'font_size': 24, 'dark': 1});
          },
        ),
      );
      await db.close();
      final repo = await LocalBookshelfRepository.create(
        directory: dir,
        factory: databaseFactoryFfi,
      );
      try {
        final restored = (await repo.watchBooks().first).single;
        expect(restored.title, '旧书');
        expect(restored.location.charOffset, 7);
        expect((await repo.loadSettings()).fontSize, 24);
        await repo.saveNotes('old', ReaderNoteKind.comment, [comment.toJson()]);
        expect(
          (await repo.loadNotes('old', ReaderNoteKind.comment)).single,
          comment.toJson(),
        );
      } finally {
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('v7 upgrade backfills excerpt query columns', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('reader-notes-v7-');
    final db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/reader.sqlite',
      options: OpenDatabaseOptions(
        version: 7,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE books (id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL, format TEXT NOT NULL, source TEXT NOT NULL, file_name TEXT NOT NULL, cover_file_name TEXT, cover_checked INTEGER NOT NULL DEFAULT 0, cache_ready INTEGER NOT NULL DEFAULT 0, added_at INTEGER NOT NULL, last_read_at INTEGER, chapter INTEGER NOT NULL DEFAULT 0, block INTEGER NOT NULL DEFAULT 0, progress REAL NOT NULL DEFAULT 0, char_offset INTEGER)',
          );
          await db.execute(
            'CREATE TABLE settings (id INTEGER PRIMARY KEY, font_size REAL NOT NULL, dark INTEGER NOT NULL, options TEXT)',
          );
          await db.execute(
            'CREATE TABLE reader_notes (book_id TEXT NOT NULL, kind TEXT NOT NULL, note_key TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (book_id, kind, note_key))',
          );
          await db.execute(
            'CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, color TEXT, created_at INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE book_tags (book_id TEXT NOT NULL, tag_id INTEGER NOT NULL, is_catalog INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL, PRIMARY KEY (book_id, tag_id))',
          );
          await db.insert('books', {
            'id': 'old',
            'title': '旧书',
            'author': '作者',
            'format': 'txt',
            'source': 'imported',
            'file_name': 'old.txt',
            'added_at': 1,
          });
          await db.insert('reader_notes', {
            'book_id': 'old',
            'kind': ReaderNoteKind.underline.name,
            'note_key': underline.key,
            'payload': jsonEncode(underline.toJson()),
          });
        },
      ),
    );
    await db.close();
    final repo = await LocalBookshelfRepository.create(
      directory: dir,
      factory: databaseFactoryFfi,
    );
    try {
      final excerpts = await repo.loadExcerpts();
      expect(excerpts.single.quote, underline.text);
      expect(excerpts.single.chapterIndex, underline.chapterIndex);
      expect(excerpts.single.startOffset, underline.start);
    } finally {
      await repo.close();
      await dir.delete(recursive: true);
    }
  });

  test(
    'failed engine writes retain latest snapshot and retry without losing other failures',
    () async {
      final repo = FailingNotesRepository();
      Object? error;
      final notes = RepositoryReaderNotes(
        repo,
        book.id,
        (value) => error = value,
      );
      await notes.underlines.save(book.id, [underline]);
      await notes.comments.save(book.id, [comment]);
      expect(error, isNotNull);
      expect((await notes.comments.load(book.id)).single.text, comment.text);
      repo.fail = false;
      await notes.comments.save(book.id, [comment.copyWith(text: '最新')]);
      expect(error, isNotNull);
      await notes.retry();
      expect(error, isNull);
      expect(
        (await repo.loadNotes(book.id, ReaderNoteKind.underline)).single,
        underline.toJson(),
      );
      expect(
        (await repo.loadNotes(book.id, ReaderNoteKind.comment)).single['text'],
        '最新',
      );
    },
  );

  testWidgets(
    'long press highlights, comments refresh, reopen restores and deletion persists',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = FakeRepository();
      await tester.pumpWidget(app(repo, ReaderView(book: book)));
      await tester.pumpAndSettle();
      Future<void> select() async {
        final prose = find.textContaining('段落 1-9', findRichText: true).first;
        final rect = tester.getRect(prose);
        await tester.longPressAt(Offset(rect.left + 80, rect.top + 25));
        await tester.pumpAndSettle();
      }

      await select();
      expect(find.text('划线'), findsOneWidget);
      await tester.tap(find.text('划线'));
      await tester.pumpAndSettle();
      expect(
        await repo.loadNotes(book.id, ReaderNoteKind.underline),
        hasLength(1),
      );
      await select();
      await tester.tap(find.text('评论'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderCommentInput), findsOneWidget);
      await tester.enterText(find.byType(TextField), '阅读想法');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final saved = (await repo.loadNotes(
        book.id,
        ReaderNoteKind.comment,
      )).single;
      expect(saved['text'], '阅读想法');
      expect(find.byType(engine.ReaderCommentBadge), findsNothing);
      expect(saved['end'] as int, greaterThan(saved['start'] as int));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(repo, ReaderView(book: book)));
      await tester.pumpAndSettle();
      final reader = tester.widget<engine.BookReader>(
        find.byType(engine.BookReader),
      );
      expect((await reader.underlineStore.load(book.id)), hasLength(1));
      final restored = (await reader.commentStore.load(book.id)).single;
      reader.onSegmentCommentTap!(
        engine.ReaderSegmentTap(
          chapterIndex: restored.chapterIndex,
          start: restored.start,
          end: restored.end,
          count: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('阅读想法'), findsOneWidget);
      final commentDetails = tester.widget<Text>(find.textContaining('原文：'));
      expect(
        commentDetails.data!.split('\n').last,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')),
      );
      await tester.tap(find.byTooltip('删除评论'));
      await tester.pumpAndSettle();
      expect(await repo.loadNotes(book.id, ReaderNoteKind.comment), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

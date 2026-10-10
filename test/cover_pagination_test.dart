import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:reader/src/cover_pagination.dart';

BookChapter chapter(String text) =>
    BookChapter(id: 'c', title: '章', blocks: ['<p>$text</p>']);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cover edition persists and keeps every note through repository restart',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp('cover-edition-');
      var repo = await LocalBookshelfRepository.create(
        directory: directory,
        factory: databaseFactoryFfi,
      );
      try {
        final book = await repo.importBytes(
          Uint8List.fromList(utf8.encode(List.filled(2000, '书').join())),
          '书.txt',
        );
        final pagination = await repo.loadCoverPagination(book.id);
        final cached = File(
          '${directory.path}/cache/${book.id}/cover_pages.json',
        );
        expect(await cached.exists(), isTrue);
        expect(
          identical(await repo.loadCoverPagination(book.id), pagination),
          isTrue,
        );
        await repo.saveNotes(book.id, ReaderNoteKind.underline, [
          for (var i = 0; i < 8; i++)
            {
              'chapterIndex': 0,
              'start': i * 100,
              'end': i * 100 + 2,
              'text': '书',
              'createdAt': i,
            },
        ]);
        expect((await repo.watchShelfEntries().first).single.markers.length, 8);
        await repo.close();
        repo = await LocalBookshelfRepository.create(
          directory: directory,
          factory: databaseFactoryFfi,
        );
        expect(
          (await repo.loadCoverPagination(book.id)).chapters,
          pagination.chapters,
        );
        expect(
          (await repo.loadNotes(book.id, ReaderNoteKind.underline)).length,
          8,
        );
      } finally {
        await repo.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test('fixed edition wraps CJK and retains engine indent coordinates', () {
    final starts = paginateCoverChapter(chapter(List.filled(1000, '书').join()));
    expect(starts, [0, 440, 920]);
    final edition = BookCoverPagination([
      starts,
      [0, 400],
    ]);
    expect(edition.pageCount, 5);
    expect(edition.pageFor(0, 439), 0);
    expect(edition.pageFor(0, 440), 1);
    expect(edition.pageFor(1, 400), 4);
    expect(edition.pageFor(-1, 0), isNull);
    expect(edition.pageFor(2, 0), isNull);
    expect(edition.pageFor(0, -1), isNull);
    expect(
      BookCoverPagination.fromJson(edition.toJson()).chapters,
      edition.chapters,
    );
  });
  test(
    'ASCII takes half a CJK column and supplementary runes retain UTF16 offsets',
    () {
      final ascii = paginateCoverChapter(
        chapter(List.filled(1000, 'a').join()),
      );
      final cjk = paginateCoverChapter(chapter(List.filled(1000, '书').join()));
      final supplementary = paginateCoverChapter(
        chapter(List.filled(1000, '𠀀').join()),
      );
      expect(ascii.length, 2);
      expect(cjk.length, 3);
      expect(supplementary, [0, 878, 1838]);
    },
  );
  test('paragraph indentation counts toward saved note coordinates', () {
    final data = BookChapter(
      id: 'c',
      title: '',
      blocks: [for (var i = 0; i < 25; i++) '<p>书</p>'],
    );
    expect(paginateCoverChapter(data), [0, 66]);
  });
}

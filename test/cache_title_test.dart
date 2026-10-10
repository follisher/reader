import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final extension in ['txt', 'md']) {
    for (final oldCache in [false, true]) {
      test(
        '$extension ${oldCache ? 'repairs hash metadata' : 'rebuilds missing cache'} without changing notes',
        () async {
          final dir = await Directory.systemTemp.createTemp('reader-title-');
          var repo = await LocalBookshelfRepository.create(
            directory: dir,
            factory: databaseFactoryFfi,
          );
          try {
            const title = '紫微斗數全書卷一';
            final body = extension == 'txt'
                ? List.generate(105, (i) => '正文第$i段。').join('\n')
                : '序言正文。\n\n# 第一章\n\n章节正文。';
            final book = await repo.importBytes(
              Uint8List.fromList(utf8.encode(body)),
              '$title.$extension',
            );
            final original = await repo.openBook(book);
            final bodies = <List<String>>[];
            for (var i = 0; i < original.chapters.length; i++) {
              bodies.add((await original.readChapter(i)).blocks);
            }
            const location = ReadingLocation(
              chapter: 0,
              block: 0,
              progress: .2,
              charOffset: 2,
            );
            await repo.saveLocation(book.id, location);
            final note = <String, dynamic>{
              'chapterIndex': 0,
              'start': 0,
              'end': 2,
              'text': '正文',
              'createdAt': 1,
            };
            await repo.saveNotes(book.id, ReaderNoteKind.underline, [note]);
            await repo.close();
            final cache = Directory('${dir.path}/cache/${book.id}');
            final manifest = File('${cache.path}/content.json');
            if (oldCache) {
              final data =
                  jsonDecode(await manifest.readAsString())
                      as Map<String, dynamic>;
              void corrupt(dynamic node) {
                if (node is Map<String, dynamic>) {
                  final t = node['title'];
                  if (t is String &&
                      (t == title || t.startsWith('$title · '))) {
                    node['title'] = '${book.id}${t.substring(title.length)}';
                  }
                  for (final child in node.values) {
                    corrupt(child);
                  }
                } else if (node is List) {
                  for (final child in node) {
                    corrupt(child);
                  }
                }
              }

              corrupt(data);
              await manifest.writeAsString(jsonEncode(data));
            } else {
              await cache.delete(recursive: true);
            }
            repo = await LocalBookshelfRepository.create(
              directory: dir,
              factory: databaseFactoryFfi,
            );
            final reopened = (await repo.watchBooks().first).single;
            final content = await repo.openBook(reopened);
            expect(content.title, title);
            expect(
              content.chapters.map((c) => c.title),
              original.chapters.map((c) => c.title),
            );
            expect(
              content.toc.map((t) => t.title),
              original.toc.map((t) => t.title),
            );
            for (var i = 0; i < content.chapters.length; i++) {
              expect((await content.readChapter(i)).blocks, bodies[i]);
            }
            expect(reopened.location.charOffset, location.charOffset);
            expect(reopened.location.progress, location.progress);
            expect(await repo.loadNotes(book.id, ReaderNoteKind.underline), [
              note,
            ]);
            final readerManifest = await RepositoryBookSource(
              repo,
              reopened,
            ).loadManifest();
            expect(readerManifest.title, title);
            expect(
              (jsonDecode(await manifest.readAsString()) as Map)['title'],
              title,
            );
          } finally {
            await repo.close();
            await dir.delete(recursive: true);
          }
        },
      );
    }
  }
}

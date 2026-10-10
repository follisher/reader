import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/book_reader_adapter.dart';
import 'package:reader/src/models.dart';
import 'package:reader/src/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final extension in ['txt', 'md']) {
    for (final corrupt in [false, true]) {
      test(
        '$extension cache ${corrupt ? 'repairs a hash title' : 'rebuilds after a parser update'} using its bookshelf name',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'reader_txt_title_',
          );
          var repository = await LocalBookshelfRepository.create(
            directory: directory,
            factory: databaseFactoryFfi,
          );
          try {
            final book = await repository.importBytes(
              Uint8List.fromList(utf8.encode('没有章节名的正文。\n第二段正文。')),
              '${Uri.encodeComponent('山间/阅读札记')}.$extension',
            );
            expect(book.title, '山间/阅读札记');
            expect(book.fileName, '${book.id}.$extension');
            await repository.saveLocation(
              book.id,
              const ReadingLocation(charOffset: 3, progress: .2),
            );
            await repository.close();
            final manifest = File(
              '${directory.path}/cache/${book.id}/content.json',
            );
            final json =
                jsonDecode(await manifest.readAsString())
                    as Map<String, dynamic>;
            if (corrupt) {
              json['title'] = book.id;
              for (final chapter in json['chapters'] as List) {
                (chapter as Map)['title'] = book.id;
              }
            } else {
              json['parserRevision'] =
                  LocalBookshelfRepository.parserRevision - 1;
            }
            await manifest.writeAsString(jsonEncode(json));
            repository = await LocalBookshelfRepository.create(
              directory: directory,
              factory: databaseFactoryFfi,
            );
            final reopened = (await repository.watchBooks().first).single;
            final content = await repository.openBook(reopened);
            expect(content.title, '山间/阅读札记');
            expect(content.chapters.first.title, '山间/阅读札记');
            final source = RepositoryBookSource(repository, reopened);
            expect((await source.loadManifest()).title, '山间/阅读札记');
            expect(reopened.location.charOffset, 3);
            expect(reopened.location.progress, .2);
            final saved = jsonDecode(await manifest.readAsString()) as Map;
            expect(saved['title'], '山间/阅读札记');
            expect(
              saved['parserRevision'],
              LocalBookshelfRepository.parserRevision,
            );
          } finally {
            await repository.close();
            await directory.delete(recursive: true);
          }
        },
      );
    }
  }
}

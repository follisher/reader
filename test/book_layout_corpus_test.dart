import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:reader/src/book_layout.dart';
import 'package:reader/src/book_reader_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('READER_BOOKS_DIRECTORY');
  test(
    'every curated book has exact text anchors and preserves original body',
    () async {
      final files = await Directory(root)
          .list()
          .where(
            (f) =>
                f is File &&
                (f.path.endsWith('.md') || f.path.endsWith('.txt')),
          )
          .cast<File>()
          .toList();
      expect(files, isNotEmpty);
      for (final file in files) {
        final bytes = await file.readAsBytes();
        final layout = BookLayout.fromJson(
          jsonDecode(await File('${file.path}.layout.json').readAsString())
              as Map<String, dynamic>,
        );
        expect(layout.sourceHash, sha256.convert(bytes).toString());
        final original = await LocalBookParser().parse(
          bytes,
          file.uri.pathSegments.last,
        );
        final wrapped = LayoutBookContent(original, layout);
        for (var c = 0; c < original.chapters.length; c++) {
          final raw = TextChapter.fromChapter(await original.readChapter(c));
          final rendered = await wrapped.renderChapter(c);
          final visual = TextChapter.fromChapter(rendered.chapter);
          expect(
            visual.paragraphs.join().replaceAll(RegExp(r'\s'), ''),
            raw.paragraphs.join().replaceAll(RegExp(r'\s'), ''),
            reason: file.path,
          );
          for (final h in layout.headings.where((h) => h.chapter == c)) {
            expect(h.offset + h.length, lessThanOrEqualTo(raw.length));
            expect(
              rendered.blockForOffset(h.offset),
              h.block,
              reason: '${file.path}: ${h.title}',
            );
            if (h.length > 0) {
              expect(
                rendered.chapter.blocks[h.block],
                startsWith('<h'),
                reason: h.title,
              );
            }
          }
        }
        expect(wrapped.toc, isNotEmpty);
      }
    },
    skip: root.isEmpty
        ? 'Set READER_BOOKS_DIRECTORY to validate a host corpus.'
        : false,
  );
}

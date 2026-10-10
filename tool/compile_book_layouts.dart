import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;
import 'package:reader/reader.dart';
import 'package:reader/src/book_layout.dart';
import 'package:reader/src/book_reader_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('compile curated corpus against existing parsed text', () async {
    const draftsPath = String.fromEnvironment('BOOK_DRAFTS');
    const rootPath = String.fromEnvironment('BOOK_ROOT');
    const reportPath = String.fromEnvironment('BOOK_REPORT');
    final drafts = jsonDecode(await File(draftsPath).readAsString()) as List;
    final reports = <Map<String, dynamic>>[];
    for (final draft in drafts.cast<Map<String, dynamic>>()) {
      final source = File('$rootPath/${draft['file']}');
      final lines = const LineSplitter().convert(await source.readAsString());
      final raw = await LocalBookParser().parse(
        await source.readAsBytes(),
        draft['file'] as String,
      );
      final chapters = <BookChapter>[];
      final texts = <TextChapter>[];
      final starts = <int>[];
      final buffer = StringBuffer();
      for (var i = 0; i < raw.chapters.length; i++) {
        starts.add(buffer.length);
        final chapter = await raw.readChapter(i);
        chapters.add(chapter);
        final text = TextChapter.fromChapter(chapter);
        texts.add(text);
        buffer.write(text.paragraphs.join());
      }
      final all = buffer.toString();
      final sourceLengths = <int>[];
      var sourceLength = 0;
      for (final line in lines) {
        sourceLengths.add(sourceLength);
        sourceLength += line.trim().length;
      }
      final headings = <LayoutHeading>[];
      final failed = <String>[];
      var previous = -1;
      for (final h
          in (draft['headings'] as List).cast<Map<String, dynamic>>()) {
        final quote = h['sourceText'] as String;
        final query = draft['file'].toString().endsWith('.md')
            ? (html
                          .parseFragment(
                            md.markdownToHtml(
                              quote,
                              extensionSet: md.ExtensionSet.gitHubFlavored,
                            ),
                          )
                          .text ??
                      '')
                  .split('\n')
                  .map((s) => s.trim())
                  .join()
            : quote.trim();
        final line = h['sourceLine'] as int;
        final within = lines[line - 1].indexOf(quote);
        final expected =
            ((sourceLengths[line - 1] + (within < 0 ? 0 : within)) /
                    sourceLength *
                    all.length)
                .round();
        final candidates = <int>[];
        var found = all.indexOf(query);
        while (found >= 0) {
          if (found > previous) candidates.add(found);
          found = all.indexOf(query, found + 1);
        }
        var chosen = -1;
        var length = query.length;
        var chapterIndex = 0;
        if (candidates.isNotEmpty) {
          candidates.sort(
            (a, b) => (a - expected).abs().compareTo((b - expected).abs()),
          );
          chosen = candidates.first;
          for (var c = 0; c < starts.length; c++) {
            if (starts[c] <= chosen) chapterIndex = c;
          }
        } else {
          for (var c = 0; c < chapters.length; c++) {
            if (chapters[c].title == query && starts[c] >= previous) {
              chosen = starts[c];
              chapterIndex = c;
              length = 0;
              break;
            }
          }
        }
        if (chosen < 0) {
          failed.add('$line:$quote');
          continue;
        }
        final offset = chosen - starts[chapterIndex];
        // Heading ranges must stay inside an original paragraph.
        var paragraphStart = 0;
        for (final p in texts[chapterIndex].paragraphs) {
          if (offset >= paragraphStart &&
              offset < paragraphStart + p.length &&
              offset + length > paragraphStart + p.length) {
            failed.add('cross-paragraph $line:$quote');
          }
          paragraphStart += p.length;
        }
        headings.add(
          LayoutHeading(
            title: h['title'] as String,
            chapter: chapterIndex,
            offset: offset,
            length: length,
            level: h['level'] as int,
            sourceLine: line,
          ),
        );
        previous = chosen;
      }
      expect(failed, isEmpty, reason: '${draft['file']}: $failed');
      final renderings = <RenderedLayoutChapter>[];
      for (var c = 0; c < chapters.length; c++) {
        final r = renderLayoutChapter(
          chapters[c],
          headings.where((h) => h.chapter == c).toList(),
        );
        renderings.add(r);
        // Visual whitespace is flexible, but every character remains in order.
        final visual = TextChapter.fromChapter(
          r.chapter,
        ).paragraphs.join().replaceAll(RegExp(r'\s'), '');
        final original = texts[c].paragraphs.join().replaceAll(
          RegExp(r'\s'),
          '',
        );
        expect(
          visual,
          original,
          reason: 'body changed: ${draft['file']} chapter $c',
        );
      }
      final resolved = [
        for (final h in headings)
          LayoutHeading(
            title: h.title,
            chapter: h.chapter,
            offset: h.offset,
            length: h.length,
            level: h.level,
            block: renderings[h.chapter].blockForOffset(h.offset),
            sourceLine: h.sourceLine,
          ),
      ];
      final layout = BookLayout(
        sourceHash: draft['sourceHash'] as String,
        headings: resolved,
      );
      BookLayout.fromJson(layout.toJson());
      await File('${source.path}.layout.json').writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(layout.toJson())}\n',
      );
      reports.add({
        ...draft,
        'headings': resolved.map((h) => h.toJson()).toList(),
        'originalChapters': chapters.length,
        'visualBlocks': renderings.fold<int>(
          0,
          (n, c) => n + c.chapter.blocks.length,
        ),
      });
      // ignore: avoid_print
      print(
        '${draft['file']}: ${resolved.length} headings, ${chapters.length} original chapters',
      );
    }
    await File(
      reportPath,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
  });
}

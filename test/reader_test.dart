import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List text(String value) => Uint8List.fromList(utf8.encode(value));
Uint8List epub({bool missingChapter = false, String? extraPath}) {
  final archive = Archive();
  void add(String name, String value) {
    final bytes = text(value);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add(
    'META-INF/container.xml',
    '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
  );
  add(
    'OPS/book.opf',
    '<package><metadata><title>测试书</title><creator>作者</creator></metadata><manifest><item id="b" href="b.xhtml"/><item id="a" href="a.xhtml"/><item id="cover" href="images/a.png" properties="cover-image"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
  );
  if (!missingChapter) {
    add(
      'OPS/a.xhtml',
      '<html><body><h1>第一章</h1><p>你好世界</p><script>alert(1)</script><img src="https://example.com/a.jpg"/><img src="images/a.png"/><a href="https://example.com">链接</a></body></html>',
    );
  }
  add(
    'OPS/b.xhtml',
    '<html><body><div><section><h1>第二章</h1><p>结束</p></section></div></body></html>',
  );
  add('OPS/images/a.png', 'fake-image');
  if (extraPath != null) add(extraPath, 'invalid');
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final parser = LocalBookParser();
  const localEpub = String.fromEnvironment('READER_TEST_EPUB');
  if (localEpub.isNotEmpty) {
    test('actual climbing book cover and title page targets', () async {
      final content = await parser.parse(
        await File(localEpub).readAsBytes(),
        '攀岩是个技术活.epub',
      );
      for (final pair in {
        '封面': 'text00000.html',
        '书名页': 'text00001.html',
      }.entries) {
        final entry = content.toc.firstWhere((e) => e.title == pair.key);
        expect(content.chapters[entry.chapter!].id, endsWith(pair.value));
      }
      expect(content.chapters.first.blocks.join(), contains('Image00000.jpg'));
      expect(await content.resource('OEBPS/Image00000.jpg'), isNotEmpty);
    });
  }
  const placeholderEpub = String.fromEnvironment(
    'READER_TEST_PLACEHOLDER_EPUB',
  );
  if (placeholderEpub.isNotEmpty) {
    test('placeholder page titles do not become reader headings', () async {
      final content = await parser.parse(
        await File(placeholderEpub).readAsBytes(),
        'placeholder.epub',
      );
      expect(content.chapters.take(2).map((chapter) => chapter.title), [
        'Cover',
        '',
      ]);
      expect(content.chapters.first.kind, BookChapterKind.cover);
      expect(
        content.chapters.take(2).every((chapter) => chapter.blocks.isNotEmpty),
        isTrue,
      );
    });
  }
  test(
    'nonlinear SVG cover remains before title page with visible image',
    () async {
      final archive = Archive();
      void add(String path, String source) {
        final bytes = text(source);
        archive.addFile(ArchiveFile(path, bytes.length, bytes));
      }

      add(
        'META-INF/container.xml',
        '<container><rootfile full-path="book.opf"/></container>',
      );
      add(
        'book.opf',
        '<package><manifest><item id="c" href="cover.xhtml"/><item id="t" href="titlepage.xhtml"/><item id="nav" href="nav.xhtml" properties="nav"/></manifest><spine><itemref idref="c" linear="no"/><itemref idref="t"/></spine></package>',
      );
      add(
        'cover.xhtml',
        '<html><body><svg><image xlink:href="cover.png"/></svg></body></html>',
      );
      add('titlepage.xhtml', '<html><body><h1>真实书名</h1></body></html>');
      add('cover.png', 'bitmap');
      add(
        'nav.xhtml',
        '<nav><ol><li><a href="cover.xhtml">封面</a></li><li><a href="titlepage.xhtml">书名页</a></li></ol></nav>',
      );
      final content = await parser.parse(
        Uint8List.fromList(ZipEncoder().encode(archive)!),
        'test.epub',
      );
      expect(content.toc.map((e) => e.chapter), [0, 1]);
      expect(content.chapters.first.kind, BookChapterKind.cover);
      expect(
        content.chapters.first.blocks.join(),
        contains('data-reader-resource="cover.png"'),
      );
      expect(content.chapters.last.blocks.join(), contains('真实书名'));
    },
  );
  for (final ncx in [false, true]) {
    test('nested ${ncx ? "NCX" : "nav"} anchors resolve distinct blocks', () async {
      final archive = Archive();
      void add(String path, String source) {
        final bytes = text(source);
        archive.addFile(ArchiveFile(path, bytes.length, bytes));
      }

      add(
        'META-INF/container.xml',
        '<container><rootfile full-path="book.opf"/></container>',
      );
      add(
        'book.opf',
        '<package><manifest><item id="c" href="c.xhtml"/><item id="toc" href="toc.xml" ${ncx ? 'media-type="application/x-dtbncx+xml"' : 'properties="nav"'}/></manifest><spine><itemref idref="c"/></spine></package>',
      );
      add(
        'c.xhtml',
        '<body><h1>章</h1><section id="one"><h2>节一</h2><p>甲</p></section><h2 id="two">节二</h2><p>乙</p></body>',
      );
      add(
        'toc.xml',
        ncx
            ? '<ncx><navMap><navPoint><navLabel><text>章</text></navLabel><content src="c.xhtml"/><navPoint><navLabel><text>节一</text></navLabel><content src="c.xhtml#one"/></navPoint><navPoint><navLabel><text>节二</text></navLabel><content src="c.xhtml#two"/></navPoint></navPoint></navMap></ncx>'
            : '<nav epub:type="toc"><ol><li><a href="c.xhtml">章</a><ol><li><a href="c.xhtml#one">节一</a></li><li><a href="c.xhtml#two">节二</a></li></ol></li></ol></nav>',
      );
      final content = await parser.parse(
        Uint8List.fromList(ZipEncoder().encode(archive)!),
        'test.epub',
      );
      expect(content.toc.single.block, isNull);
      expect(content.toc.single.children.map((e) => e.block), [0, 2]);
      expect(content.toc.single.children.map((e) => e.chapter), [0, 0]);
    });
  }
  test(
    'TXT handles BOM, Chinese chapter headings and escapes markup',
    () async {
      final content = await parser.parse(
        text('\uFEFF第一章 开始\n你好 <script>\n第二章 结束\n再见'),
        '测试.txt',
      );
      expect(content.title, '测试');
      expect(content.chapters.length, 2);
      expect(content.chapters.first.blocks.join(), contains('&lt;script&gt;'));
    },
  );
  test('TXT rejects empty and invalid encoding', () async {
    await expectLater(
      parser.parse(text(' \n'), 'empty.txt'),
      throwsFormatException,
    );
    await expectLater(
      parser.parse(Uint8List.fromList([255]), 'gbk.txt'),
      throwsFormatException,
    );
  });
  test(
    'EPUB follows spine, reads metadata and disables external/active content',
    () async {
      final content = await parser.parse(epub(), 'book.epub');
      expect(content.title, '测试书');
      expect(content.author, '作者');
      expect(content.chapters.last.blocks.length, 1);
      expect(content.chapters.map((c) => c.title), ['第一章', '第二章']);
      final markup = content.chapters.first.blocks.join();
      expect(markup, isNot(contains('<script')));
      expect(markup, isNot(contains('https://')));
      expect(markup, contains('data-reader-resource="OPS/images/a.png"'));
      expect(await content.resource('OPS/images/a.png'), isNotNull);
      expect(await content.cover(), text('fake-image'));
    },
  );
  test('repository stores EPUB cover and removes its cached file', () async {
    sqfliteFfiInit();
    final temp = await Directory.systemTemp.createTemp('reader_cover_test_');
    final root = Directory('${temp.path}/library');
    final repo = await LocalBookshelfRepository.create(
      directory: root,
      factory: databaseFactoryFfi,
    );
    try {
      final book = await repo.importBytes(epub(), 'book.epub');
      expect(book.coverPath, isNotNull);
      expect(await File(book.coverPath!).readAsBytes(), text('fake-image'));
      await repo.removeBook(book.id);
      expect(await File(book.coverPath!).exists(), isFalse);
    } finally {
      await repo.close();
      await temp.delete(recursive: true);
    }
  });
  test('malformed and unsafe EPUB fail without extracting files', () async {
    await expectLater(
      parser.parse(epub(missingChapter: true), 'book.epub'),
      throwsFormatException,
    );
    await expectLater(
      parser.parse(epub(extraPath: '../outside.txt'), 'book.epub'),
      throwsFormatException,
    );
    await expectLater(
      parser.parse(text('not a zip'), 'book.epub'),
      throwsA(anything),
    );
  });
  test(
    'repository deduplicates, persists progress/settings, and removes only managed copy',
    () async {
      sqfliteFfiInit();
      final temp = await Directory.systemTemp.createTemp('reader_test_');
      final root = Directory('${temp.path}/library');
      final original = File('${temp.path}/original.txt');
      await original.writeAsString('第一章\n正文\n第二章\n结尾');
      var repo = await LocalBookshelfRepository.create(
        directory: root,
        factory: databaseFactoryFfi,
      );
      try {
        final imported = await repo.importFileWithResult(original);
        final duplicate = await repo.importFileWithResult(original);
        final book = imported.book;
        expect(imported.isDuplicate, isFalse);
        expect(duplicate.book.id, book.id);
        expect(duplicate.isDuplicate, isTrue);
        expect((await repo.watchBooks().first).length, 1);
        await repo.saveLocation(
          book.id,
          const ReadingLocation(chapter: 1, block: 0, progress: .5),
        );
        await repo.saveSettings(const ReaderSettings(fontSize: 26, dark: true));
        await repo.close();
        repo = await LocalBookshelfRepository.create(
          directory: root,
          factory: databaseFactoryFfi,
        );
        final reopened = (await repo.watchBooks().first).single;
        expect(reopened.cacheReady, isTrue);
        expect(reopened.location.chapter, 1);
        expect(reopened.location.progress, .5);
        expect((await repo.loadSettings()).fontSize, 26);
        expect((await repo.loadSettings()).dark, isTrue);
        await File('${root.path}/${book.fileName}').delete();
        expect((await repo.openBook(reopened)).chapters.length, 2);
        await repo.removeBook(book.id);
        expect(await repo.watchBooks().first, isEmpty);
        expect(await original.exists(), isTrue);
        expect(await File('${root.path}/${book.fileName}').exists(), isFalse);
      } finally {
        await repo.close();
        await temp.delete(recursive: true);
      }
    },
  );
}

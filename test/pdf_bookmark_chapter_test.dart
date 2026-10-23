import 'package:flutter_readium/flutter_readium.dart' as rd;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/pdf_bookmark_chapter.dart';

void main() {
  const toc = [
    rd.Link(href: 'book.pdf#page=3', title: '第一章'),
    rd.Link(
      href: 'book.pdf#page=9',
      title: '第二章',
      children: [rd.Link(href: 'book.pdf#page=11', title: '第一节')],
    ),
    rd.Link(href: 'book.pdf#page=20', title: '第一章'),
  ];
  PdfBookmarkChapter chapter(int page, {List<rd.Link> links = toc}) =>
      resolvePdfBookmarkChapter(
        toc: links,
        page: page,
        locator: rd.Locator(
          href: 'book.pdf',
          type: 'application/pdf',
          locations: rd.Locations(position: page),
        ),
      );

  test('bookmarks on different pages share the enclosing chapter', () {
    expect(chapter(4).title, '第一章');
    expect(chapter(4).key, chapter(8).key);
    expect(chapter(9).title, '第二章');
    expect(chapter(12).title, '第一节');
    expect(chapter(21).title, '第一章');
    expect(chapter(21).key, isNot(chapter(4).key));
  });

  test('missing TOC or position before its first entry falls back to page', () {
    expect(chapter(2).title, '第 2 页');
    expect(chapter(7, links: []).title, '第 7 页');
  });

  test('catalogue index follows the current PDF page', () {
    rd.Locator atPage(int page) => rd.Locator(
      href: 'book.pdf',
      type: 'application/pdf',
      locations: rd.Locations(position: page),
    );

    expect(resolvePdfTocIndex(toc: toc, locator: atPage(4), page: 4), 0);
    expect(resolvePdfTocIndex(toc: toc, locator: atPage(10), page: 10), 1);
    // The flattened index includes the second chapter's child section.
    expect(resolvePdfTocIndex(toc: toc, locator: atPage(12), page: 12), 2);
    expect(resolvePdfTocIndex(toc: toc, locator: atPage(21), page: 21), 3);
  });

  test('native TOC locator is preferred for named destinations', () {
    final locator = rd.Locator(
      href: 'book.pdf',
      type: 'application/pdf',
      locations: const rd.Locations(
        position: 4,
        additionalProperties: {'tocHref': 'book.pdf#intro'},
      ),
    );
    expect(
      resolvePdfTocIndex(
        toc: const [rd.Link(href: 'book.pdf#intro', title: '引言')],
        locator: locator,
        page: 4,
      ),
      0,
    );
  });

  test('named destinations and saved chapter metadata are supported', () {
    final named = resolvePdfBookmarkChapter(
      toc: const [rd.Link(href: 'book.pdf#intro', title: '引言')],
      locator: const rd.Locator(
        href: 'book.pdf',
        type: 'application/pdf',
        locations: rd.Locations(
          additionalProperties: {'tocHref': 'book.pdf#intro'},
        ),
      ),
      page: 4,
    );
    expect(named.title, '引言');
    final restored = resolvePdfBookmarkChapter(
      toc: [],
      locator: null,
      page: 4,
      savedTitle: named.title,
      savedKey: named.key,
    );
    expect(restored.key, named.key);
    expect(restored.title, named.title);
  });

  test(
    'only preceding entries in the matching PDF resource are considered',
    () {
      final result = chapter(
        8,
        links: const [
          rd.Link(href: 'book.pdf#page=3&zoom=100', title: '正确章节'),
          rd.Link(href: 'other.pdf#page=7', title: '其他文件'),
          rd.Link(href: 'book.pdf#page=bad', title: '无效页码'),
          rd.Link(href: 'book.pdf#page=10', title: '后续章节'),
        ],
      );
      expect(result.title, '正确章节');
    },
  );
}

import 'package:flutter_readium/flutter_readium.dart' as rd;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/src/pdf_readium_adapter.dart';

void main() {
  final publication = rd.Publication(
    metadata: rd.Metadata(
      localizedTitle: rd.LocalizedString.fromStrings({'zh': 'PDF'}),
    ),
    readingOrder: const [
      rd.Link(href: 'book.pdf', type: 'application/pdf', title: '书名'),
    ],
  );
  test('directory jumps use PDF pages rather than reading order position', () {
    for (final page in [1, 2, 12, 100]) {
      final locator = pdfLocatorForLink(
        rd.Link(href: 'book.pdf#page=$page&zoom=100', title: '章节'),
        publication,
      )!;
      expect(locator.locations?.position, page);
      expect(locator.locations?.fragments, ['page=$page']);
      expect(locator.locations?.cssSelector, isNull);
      expect(locator.locations?.progression, isNull);
      expect(locator.title, '章节');
      expect(locator.href, 'book.pdf');
    }
  });
  test('named destinations retain their original fragment', () {
    final locator = pdfLocatorForLink(
      const rd.Link(href: 'book.pdf#nameddest=chapter1'),
      publication,
    )!;
    expect(locator.locations?.fragments, ['nameddest=chapter1']);
  });
}

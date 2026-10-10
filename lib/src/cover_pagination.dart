import 'models.dart';
import 'book_reader_adapter.dart' show TextChapter;

/// Stable cover-only edition: 20 CJK columns, 24 lines, two-character indent.
/// Offsets retain the reader engine's UTF-16 coordinates (including indent).
class BookCoverPagination {
  const BookCoverPagination(this.chapters);
  final List<List<int>> chapters;
  int get pageCount => chapters.fold(0, (sum, pages) => sum + pages.length);
  int? pageFor(int chapter, int offset) {
    if (chapter < 0 || chapter >= chapters.length || offset < 0) return null;
    final starts = chapters[chapter];
    var low = 0;
    var high = starts.length;
    while (low + 1 < high) {
      final mid = (low + high) ~/ 2;
      if (starts[mid] <= offset) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return chapters.take(chapter).fold<int>(0, (sum, p) => sum + p.length) +
        low;
  }

  Map<String, Object> toJson() => {'version': 1, 'chapters': chapters};
  factory BookCoverPagination.fromJson(Map<String, dynamic> json) =>
      BookCoverPagination(
        (json['chapters'] as List).map((p) => (p as List).cast<int>()).toList(),
      );
}

/// Runs together with HTML normalization in a background isolate.
List<int> paginateCoverChapter(BookChapter chapter) {
  final text = TextChapter.fromChapter(chapter);
  final starts = <int>[0];
  var row = 2; // reserve a heading on each chapter's first page
  var offset = 0;
  for (final paragraph in text.paragraphs) {
    if (row >= 24) {
      starts.add(offset);
      row = 0;
    }
    var column = 4; // two full-width indentation characters
    offset += 2;
    for (final rune in paragraph.runes) {
      final units = rune < 0x1100 ? 1 : 2;
      if (column + units > 40) {
        column = 0;
        row++;
        if (row >= 24) {
          starts.add(offset);
          row = 0;
        }
      }
      column += units;
      offset += rune > 0xffff ? 2 : 1;
    }
    row++;
  }
  return starts;
}

abstract interface class BookCoverPaginationRepository {
  Future<BookCoverPagination> loadCoverPagination(String bookId);
}

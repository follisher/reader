import 'dart:convert';
import 'dart:typed_data';

import 'book_reader_adapter.dart' show TextChapter, normalizeChapter;
import 'models.dart';

/// Presentation metadata anchored to the existing normalized chapter text.
/// Original files, chapter numbering and underline coordinates remain stable.
class BookLayout {
  BookLayout({required this.sourceHash, required this.headings});
  final String sourceHash;
  final List<LayoutHeading> headings;

  factory BookLayout.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('不支持的图书排版版本');
    final headings = (json['headings'] as List)
        .map((value) => LayoutHeading.fromJson(value as Map<String, dynamic>))
        .toList();
    if (headings.isEmpty) throw const FormatException('图书排版目录不能为空');
    for (var i = 0; i < headings.length; i++) {
      final h = headings[i];
      if (h.chapter < 0 ||
          h.offset < 0 ||
          h.block < 0 ||
          h.title.isEmpty ||
          (h.level != 1 && h.level != 2) ||
          (i > 0 &&
              (h.chapter < headings[i - 1].chapter ||
                  h.chapter == headings[i - 1].chapter &&
                      h.offset < headings[i - 1].offset))) {
        throw const FormatException('图书目录位置无效或顺序错误');
      }
    }
    return BookLayout(
      sourceHash: json['sourceHash'] as String,
      headings: headings,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'sourceHash': sourceHash,
    'headings': headings.map((h) => h.toJson()).toList(),
  };
}

class LayoutHeading {
  const LayoutHeading({
    required this.title,
    required this.chapter,
    required this.offset,
    required this.length,
    required this.level,
    this.block = 0,
    this.sourceLine = 0,
  });
  final String title;
  final int chapter, offset, length, level, block, sourceLine;
  factory LayoutHeading.fromJson(Map<String, dynamic> value) => LayoutHeading(
    title: value['title'] as String,
    chapter: value['chapter'] as int,
    offset: value['offset'] as int,
    length: value['length'] as int,
    level: value['level'] as int,
    block: value['block'] as int,
    sourceLine: value['sourceLine'] as int? ?? 0,
  );
  Map<String, dynamic> toJson() => {
    'title': title,
    'chapter': chapter,
    'offset': offset,
    'length': length,
    'level': level,
    'block': block,
    'sourceLine': sourceLine,
  };
}

/// Optional capability; custom shelf implementations need not implement it.
abstract interface class BookLayoutRepository {
  Future<void> saveBookLayout(String bookId, BookLayout layout);
}

class LayoutBookContent implements OnDemandBookContent {
  LayoutBookContent(this.original, this.layout);
  final BookContent original;
  final BookLayout layout;
  final _originalChapters = <int, Future<BookChapter>>{};
  final _originalTexts = <int, Future<TextChapter>>{};
  final _rendered = <int, Future<RenderedLayoutChapter>>{};
  @override
  String get title => original.title;
  @override
  String get author => original.author;
  @override
  List<BookChapter> get chapters => original.chapters;
  @override
  Future<Uint8List?> resource(String path) => original.resource(path);
  @override
  Future<Uint8List?> cover() => original.cover();
  Future<BookChapter> readOriginalChapter(int index) =>
      _originalChapters.putIfAbsent(index, () => original.readChapter(index));
  Future<TextChapter> originalTextChapter(int index) =>
      _originalTexts.putIfAbsent(
        index,
        () async => normalizeChapter(await readOriginalChapter(index)),
      );

  @override
  List<BookTocEntry> get toc {
    final roots = <BookTocEntry>[];
    List<BookTocEntry>? children;
    for (var i = 0; i < layout.headings.length; i++) {
      final h = layout.headings[i];
      final nested = <BookTocEntry>[];
      final entry = BookTocEntry(
        id: 'layout-$i',
        title: h.title,
        chapter: h.chapter,
        block: h.block,
        canonicalCharOffset: h.offset,
        children: nested,
      );
      if (h.level == 1 || children == null) {
        roots.add(entry);
        children = nested;
      } else {
        children.add(entry);
      }
    }
    return roots;
  }

  Future<RenderedLayoutChapter> renderChapter(int index) =>
      _rendered.putIfAbsent(
        index,
        () async => renderLayoutChapter(
          await readOriginalChapter(index),
          layout.headings.where((h) => h.chapter == index).toList(),
        ),
      );

  @override
  Future<BookChapter> loadChapter(int index) async =>
      (await renderChapter(index)).chapter;
}

class RenderedLayoutChapter {
  const RenderedLayoutChapter(this.chapter, this.canonicalOffsets);
  final BookChapter chapter;

  /// Each visual block points back to the original selectable text.
  final List<int> canonicalOffsets;
  int blockForOffset(int offset) {
    var result = 0;
    for (var i = 0; i < canonicalOffsets.length; i++) {
      if (canonicalOffsets[i] > offset) break;
      result = i;
    }
    return result;
  }
}

/// Reflow only visual blocks. The selectable reader still receives the original
/// chapter, so its stored underline/comment coordinate system is unchanged.
RenderedLayoutChapter renderLayoutChapter(
  BookChapter chapter,
  List<LayoutHeading> headings,
) {
  final text = TextChapter.fromChapter(chapter);
  final blocks = <String>[];
  final positions = <int>[];
  var offset = 0;
  const escape = HtmlEscape();
  void prose(String value, int start) {
    var current = start;
    for (final part in _proseParts(value)) {
      if (part.trim().isNotEmpty) {
        positions.add(current);
        final tabular =
            part.contains('\t') ||
            RegExp(r' {2,}').hasMatch(part) &&
                !RegExp(r'[。！？；]').hasMatch(part) &&
                RegExp(r'[甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥]').allMatches(part).length >=
                    4;
        final tag = tabular ? 'pre' : 'p';
        blocks.add('<$tag>${escape.convert(part)}</$tag>');
      }
      current += part.length;
    }
  }

  for (final paragraph in text.paragraphs) {
    final end = offset + paragraph.length;
    var cursor = offset;
    for (final h in headings.where(
      (h) => h.length > 0 && h.offset >= offset && h.offset < end,
    )) {
      if (h.offset < cursor || h.offset + h.length > end) {
        throw const FormatException('目录标题跨段或重叠');
      }
      if (h.offset > cursor) {
        prose(paragraph.substring(cursor - offset, h.offset - offset), cursor);
      }
      final headingEnd = h.offset + h.length;
      positions.add(h.offset);
      blocks.add(
        '<h${h.level + 1}>${escape.convert(paragraph.substring(h.offset - offset, headingEnd - offset))}</h${h.level + 1}>',
      );
      cursor = headingEnd;
    }
    if (cursor < end) prose(paragraph.substring(cursor - offset), cursor);
    offset = end;
  }
  return RenderedLayoutChapter(
    BookChapter(
      id: chapter.id,
      title: chapter.title,
      blocks: blocks,
      kind: chapter.kind,
    ),
    positions,
  );
}

List<String> _proseParts(String text) {
  if (text.isEmpty) return [];
  final result = <String>[];
  var start = 0;
  var bracketDepth = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if ('【（('.contains(c)) bracketDepth++;
    if ('】）)'.contains(c) && bracketDepth > 0) bracketDepth--;
    // Preserve poems, tables, annotation units and unpunctuated passages.
    // Split long prose only at an existing sentence/semicolon boundary.
    if (i - start >= 180 && bracketDepth == 0 && '。！？；'.contains(c)) {
      result.add(text.substring(start, i + 1));
      start = i + 1;
    }
  }
  if (start < text.length) result.add(text.substring(start));
  return result;
}

import 'dart:typed_data';

enum BookFormat { txt, epub }

enum BookSource { imported, builtIn, downloaded }

class ReadingLocation {
  const ReadingLocation({
    this.chapter = 0,
    this.block = 0,
    this.progress = 0,
    this.charOffset,
  });
  final int chapter;
  // Content block, never a screen pixel/page: stable when typography changes.
  final int block;
  final double progress;

  /// Offset in normalized chapter text, excluding layout indentation/newlines.
  /// Null identifies a legacy block-based position.
  final int? charOffset;
}

class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 20,
    this.dark = false,
    this.theme = 'yellow',
    this.flipMode = 'scrollVertical',
    this.lineHeight = 1.8,
    this.paragraphSpacing = 8,
    this.firstLineIndent = 2,
    this.justify = true,
    this.dimLevel = 0,
    this.fontFamily,
  });
  final double fontSize;
  final bool dark;
  final String theme, flipMode;
  final double lineHeight, paragraphSpacing, dimLevel;
  final int firstLineIndent;
  final bool justify;
  final String? fontFamily;

  ReaderSettings copyWith({double? fontSize, bool? dark}) => ReaderSettings(
    fontSize: fontSize ?? this.fontSize,
    dark: dark ?? this.dark,
    theme: dark == false && theme == 'night' ? 'yellow' : theme,
    flipMode: flipMode,
    lineHeight: lineHeight,
    paragraphSpacing: paragraphSpacing,
    firstLineIndent: firstLineIndent,
    justify: justify,
    dimLevel: dimLevel,
    fontFamily: fontFamily,
  );

  Map<String, Object?> toJson() => {
    'theme': theme,
    'flipMode': flipMode,
    'lineHeight': lineHeight,
    'paragraphSpacing': paragraphSpacing,
    'firstLineIndent': firstLineIndent,
    'justify': justify,
    'dimLevel': dimLevel,
    'fontFamily': fontFamily,
  };
}

class Book {
  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.format,
    required this.source,
    required this.fileName,
    required this.addedAt,
    this.coverPath,
    this.cacheReady = false,
    this.location = const ReadingLocation(),
    this.lastReadAt,
  });
  final String id, title, author, fileName;
  final BookFormat format;
  final BookSource source;
  final DateTime addedAt;
  final String? coverPath;
  final bool cacheReady;
  final ReadingLocation location;

  /// The last time the reader persisted a position for this book.
  final DateTime? lastReadAt;

  /// Alias matching the user-facing notion of recent reading time.
  DateTime? get recentReadAt => lastReadAt;
}

enum BookChapterKind { content, cover, titlePage, copyright, backCover }

class BookChapter {
  const BookChapter({
    required this.id,
    required this.title,
    required this.blocks,
    this.kind = BookChapterKind.content,
  });
  final String id, title;
  final List<String> blocks;
  final BookChapterKind kind;
}

class BookTocEntry {
  const BookTocEntry({
    required this.id,
    required this.title,
    this.chapter,
    this.block,
    this.children = const [],
  });
  final String id, title;
  final int? chapter, block;
  final List<BookTocEntry> children;
}

/// A reader consumes chapters/resources, independently of file/download origin.
/// A future encrypted implementation can decrypt one chapter/resource on demand.
abstract interface class BookContent {
  String get title;
  String get author;
  List<BookChapter> get chapters;
  List<BookTocEntry> get toc;
  Future<Uint8List?> resource(String path);
  Future<Uint8List?> cover();
}

/// [chapters] contains metadata only; bodies are read individually.
abstract interface class OnDemandBookContent implements BookContent {
  Future<BookChapter> loadChapter(int index);
}

extension BookContentLoading on BookContent {
  Future<BookChapter> readChapter(int index) async {
    final content = this;
    return content is OnDemandBookContent
        ? content.loadChapter(index)
        : chapters[index];
  }
}

class MemoryBookContent implements BookContent {
  MemoryBookContent({
    required this.title,
    required this.author,
    required this.chapters,
    List<BookTocEntry>? toc,
    Map<String, Uint8List>? resources,
    this.coverResourcePath,
  }) : toc =
           toc ??
           [
             for (var index = 0; index < chapters.length; index++)
               BookTocEntry(
                 id: chapters[index].id,
                 title: chapters[index].title,
                 chapter: index,
               ),
           ],
       _resources = resources ?? {};
  @override
  final String title, author;
  @override
  final List<BookChapter> chapters;
  @override
  final List<BookTocEntry> toc;
  final Map<String, Uint8List> _resources;
  Map<String, Uint8List> get resources => Map.unmodifiable(_resources);
  final String? coverResourcePath;
  @override
  Future<Uint8List?> resource(String path) async => _resources[path];

  @override
  Future<Uint8List?> cover() async =>
      coverResourcePath == null ? null : _resources[coverResourcePath];
}

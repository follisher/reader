import 'dart:typed_data';

enum BookFormat { txt, epub }

enum BookSource { imported, builtIn, downloaded }

class ReadingLocation {
  const ReadingLocation({this.chapter = 0, this.block = 0, this.progress = 0});
  final int chapter;
  // Content block, never a screen pixel/page: stable when typography changes.
  final int block;
  final double progress;
}

class ReaderSettings {
  const ReaderSettings({this.fontSize = 20, this.dark = false});
  final double fontSize;
  final bool dark;
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
  });
  final String id, title, author, fileName;
  final BookFormat format;
  final BookSource source;
  final DateTime addedAt;
  final String? coverPath;
  final bool cacheReady;
  final ReadingLocation location;
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

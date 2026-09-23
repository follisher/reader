import 'package:flutter/material.dart';

/// 目录条目，支持章节下的嵌套小节。
@immutable
class BookTocEntry {
  const BookTocEntry({
    required this.id,
    required this.title,
    required this.chapterIndex,
    this.charOffset = 0,
    this.children = const <BookTocEntry>[],
  });

  final String id;
  final String title;
  final int chapterIndex;
  final int charOffset;
  final List<BookTocEntry> children;
}

/// 书籍清单：书籍元信息与目录（正文按章懒加载）。
///
/// 章节正文不在清单内，按需通过 [BookSource.loadChapterBody] 拉取。
@immutable
class BookManifest {
  const BookManifest({
    required this.id,
    required this.title,
    required this.author,
    required this.intro,
    required this.coverColor,
    required this.chapterTitles,
    List<BookTocEntry>? toc,
  }) : toc = toc ?? const <BookTocEntry>[];

  final Object id;
  final String title;
  final String author;
  final String intro;
  final Color coverColor;
  final List<String> chapterTitles;
  final List<BookTocEntry> toc;

  int get chapterCount => chapterTitles.length;
}

/// 书籍数据源抽象。
///
/// 阅读器只依赖这个接口，不关心数据来自 JSON 资源、网络还是数据库。
/// 商用接入时实现自己的 [BookSource]（如 `HttpBookSource`、`DbBookSource`）即可，
/// 无需改动阅读器本身。约定：
/// - [loadManifest] 返回书籍信息与目录，通常一次调用；
/// - [loadChapterBody] 按章号懒加载正文，允许耗时（网络/IO），阅读器会显示加载态。
abstract class BookSource {
  const BookSource();

  Future<BookManifest> loadManifest();

  Future<String> loadChapterBody(int chapterIndex);
}

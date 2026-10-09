import 'package:reader/reader.dart';

// Add new tags here in the host; the reader package has no fixed categories.
abstract final class AppBookTags {
  static const novel = CatalogTag(name: '小说', color: '#D97706');
  static const classic = CatalogTag(name: '经典', color: '#7C3AED');
  static const fortune = CatalogTag(name: '命理', color: '#2563EB');
  static const ancient = CatalogTag(name: '古籍', color: '#9C8F7D');
}

const demoCatalog = BookCatalog(
  books: [
    CatalogBook(
      assetPath: 'assets/books/紫微斗數全書卷一.txt',
      tags: [AppBookTags.classic, AppBookTags.fortune, AppBookTags.ancient],
    ),
    CatalogBook(
      assetPath: 'assets/books/紫微斗數全書卷二.txt',
      tags: [AppBookTags.classic, AppBookTags.fortune, AppBookTags.ancient],
    ),
    CatalogBook(
      assetPath: 'assets/books/紫微斗數全書卷三.txt',
      tags: [AppBookTags.classic, AppBookTags.fortune, AppBookTags.ancient],
    ),
    CatalogBook(
      assetPath: 'assets/books/太白金星有点烦 -- 马伯庸.txt',
      tags: [AppBookTags.novel],
    ),
  ],
);

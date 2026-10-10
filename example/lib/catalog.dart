import 'package:reader/reader.dart';

// Add new tags here in the host; the reader package has no fixed categories.
abstract final class AppBookTags {
  static const novel = CatalogTag(name: '小说', color: '#D97706');
  static const classic = CatalogTag(name: '经典', color: '#7C3AED');
  static const fortune = CatalogTag(name: '命理', color: '#2563EB');
  static const ancient = CatalogTag(name: '古籍', color: '#9C8F7D');
  static const finance = CatalogTag(name: '经济', color: '#0F766E');
  static const sports = CatalogTag(name: '运动', color: '#16A34A');
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
    CatalogBook(
      assetPath: 'assets/books/《第一序列》(校对版全本)  会说话的肘子.epub',
      tags: [AppBookTags.novel],
    ),
    CatalogBook(
      assetPath: 'assets/books/半小时漫画经济学2金融危机篇xg.epub',
      tags: [AppBookTags.finance],
    ),
    CatalogBook(
      assetPath: 'assets/books/攀岩是个技术活.epub',
      tags: [AppBookTags.sports],
    ),
  ],
);

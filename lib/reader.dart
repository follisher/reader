library;

export 'src/models.dart';
export 'src/parser.dart' show BookParser, LocalBookParser;
export 'src/repository.dart';
export 'src/providers.dart';
export 'src/bookshelf_view.dart' show BookshelfView;
export 'src/reader_view.dart';

export 'src/book_reader_adapter.dart' show RepositoryBookSource;
export 'src/html_reader_view.dart' show HtmlReaderView;
export 'src/theme/reader_palette.dart' show ReaderPalette;
export 'package:flutter_book_reader/flutter_book_reader.dart'
    show BookReaderController, BookManifest, ReaderConfig, FlipType;

library;

export 'src/models.dart';
export 'src/parser.dart' show BookParser, LocalBookParser;
export 'src/repository.dart';
export 'src/providers.dart';
export 'src/bookshelf_view.dart'
    show BookshelfView, BookshelfLayout, BookshelfLayoutControlsBuilder;
export 'src/reader_view.dart';

export 'src/book_reader_adapter.dart' show RepositoryBookSource;
export 'src/theme/reader_palette.dart' show ReaderPalette;
export 'package:flutter_book_reader/flutter_book_reader.dart'
    show BookReaderController, BookManifest, ReaderConfig, FlipType;

export 'src/catalog.dart';
export 'src/navigation.dart';
export 'src/widget/book_cover.dart' show BookCover, RepositoryBookCover;

export 'src/book_layout.dart' show BookLayout, BookLayoutRepository;

export 'src/cover_pagination.dart' show BookCoverPagination;

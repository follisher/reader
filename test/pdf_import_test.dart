import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as pdf;
import 'package:reader/reader.dart';
import 'package:reader/src/pdf_reader_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'views_test.dart' show FakeRepository, app;

/// Small valid PDFs with a real xref table, for exercising PDFium itself.
Uint8List samplePdf({bool text = true}) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>',
    '',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>',
    '',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  for (final index in [3, 5]) {
    final stream = text ? 'BT /F1 20 Tf 30 330 Td (Hello PDF) Tj ET' : '';
    objects[index] =
        '<< /Length ${stream.length} >>\nstream\n$stream\nendstream';
  }
  final output = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(ascii.encode(output.toString()));
}

class _PdfViewerRepository extends FakeRepository
    implements PublicationFileRepository {
  _PdfViewerRepository(this.path);
  final String path;
  @override
  Future<String> publicationPath(Book book) async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late LocalBookshelfRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('reader_pdf_');
    pdf.Pdfrx.cacheDirectoryPath = directory.path;
    repository = await LocalBookshelfRepository.create(
      directory: directory,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test('PDF imports with first-page cover, text, tags, duplicate protection and resume', () async {
    final bytes = samplePdf();
    final imported = await repository.importBytesWithResult(bytes, '测试图书.PDF');
    expect(imported.isDuplicate, false);
    final book = imported.book;
    expect(book.format, BookFormat.pdf);
    expect(book.collection, BookCollection.personal);
    expect(book.title, '测试图书');
    expect(book.cacheReady, true);
    final cover = await File(book.coverPath!).readAsBytes();
    expect(cover.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final content = await repository.openBook(book);
    expect(content.chapters, hasLength(2));
    expect((await content.readChapter(0)).blocks.join(), contains('Hello PDF'));
    final metrics = await repository.loadCoverPagination(book.id);
    expect(metrics.wordCount, 16);
    await repository.setBookTags(book.id, {'古籍': null, '私藏笔记': null});
    await repository.saveLocation(
      book.id,
      const ReadingLocation(
        chapter: 1,
        progress: 1,
        anchor: ReaderAnchor(type: 'pdf', value: {'page': 2}),
      ),
    );
    expect(
      (await repository.importBytesWithResult(bytes, '重选.pdf')).isDuplicate,
      true,
    );
    await repository.close();
    repository = await LocalBookshelfRepository.create(
      directory: directory,
      factory: databaseFactoryFfi,
    );
    final saved = (await repository.watchBooks().first).single;
    expect(saved.format, BookFormat.pdf);
    expect(saved.tags.map((tag) => tag.name).toSet(), {'古籍', '私藏笔记'});
    expect(saved.location.anchor?.value['page'], 2);
    expect(saved.location.chapter, 1);
    expect(File(await repository.publicationPath(saved)).existsSync(), true);
    expect((await repository.openBook(saved)).chapters, hasLength(2));
    // Rebuilding an extracted cache must retain the non-ASCII display title.
    await Directory('${directory.path}/cache/${book.id}')
        .delete(recursive: true);
    await repository.close();
    repository = await LocalBookshelfRepository.create(
      directory: directory,
      factory: databaseFactoryFfi,
    );
    expect((await repository.openBook(saved)).title, '测试图书');
  });

  test(
    'PDF pages without extractable text remain importable and have a cover',
    () async {
      final book = await repository.importBytes(
        samplePdf(text: false),
        '扫描版.pdf',
      );
      expect(book.format, BookFormat.pdf);
      expect(File(book.coverPath!).existsSync(), true);
      expect((await repository.openBook(book)).chapters, hasLength(2));
      expect((await repository.loadCoverPagination(book.id)).wordCount, 0);
    },
  );

  test('invalid PDF and oversized PDF do not create shelf entries', () async {
    await expectLater(
      repository.importBytes(
        Uint8List.fromList(ascii.encode('not a PDF')),
        '损坏.pdf',
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      repository.importBytes(
        Uint8List(LocalBookParser.maxFileBytes + 1),
        '过大.pdf',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await repository.watchBooks().first, isEmpty);
  });

  testWidgets(
    'PDF viewer renders original pages, turns pages and saves progress',
    (tester) async {
      final book = await tester.runAsync(
        () => repository.importBytes(samplePdf(), '阅读测试.pdf'),
      );
      final viewerRepository = _PdfViewerRepository(
        '${directory.path}/${book!.fileName}',
      );
      await tester.pumpWidget(app(viewerRepository, ReaderView(book: book)));
      for (var i = 0; i < 30 && find.text('1 / 2').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(pdf.PdfViewer), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.text('下一页'));
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('2 / 2'), findsOneWidget);
      expect(viewerRepository.saves.last.anchor?.value['page'], 2);
      expect(viewerRepository.saves.last.progress, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('PDF opens the PDF reader and explains missing file access', (
    tester,
  ) async {
    final book = Book(
      id: 'pdf',
      title: 'PDF图书',
      author: '',
      format: BookFormat.pdf,
      source: BookSource.imported,
      fileName: 'test.pdf',
      addedAt: DateTime(2026),
    );
    await tester.pumpWidget(app(FakeRepository(), ReaderView(book: book)));
    await tester.pumpAndSettle();
    expect(find.byType(PdfReaderView), findsOneWidget);
    expect(find.textContaining('当前书库不支持打开 PDF 原文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

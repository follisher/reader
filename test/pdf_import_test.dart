import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:reader/src/reader_comment_sheets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as pdf;
import 'package:reader/reader.dart';
import 'package:reader/src/pdf_reader_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'views_test.dart' show FakeRepository, app;

/// Small valid PDFs with a real xref table, for exercising PDFium itself.
Uint8List samplePdf({bool text = true, bool outline = false}) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R ${outline ? '/Outlines 8 0 R' : ''} >>',
    '<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>',
    '',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>',
    '',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  if (outline) {
    String title(String text) =>
        '<FEFF${text.codeUnits.map((c) => c.toRadixString(16).padLeft(4, '0')).join()}>';
    objects.addAll([
      '<< /Type /Outlines /First 9 0 R /Last 11 0 R /Count 3 >>',
      '<< /Title ${title('第一章：开篇')} /Parent 8 0 R /Next 11 0 R /First 10 0 R /Last 10 0 R /Count 1 /Dest [3 0 R /XYZ 0 360 1] >>',
      '<< /Title ${title('第一节：导读')} /Parent 9 0 R /Dest [3 0 R /XYZ 0 180 1] >>',
      '<< /Title ${title('第二章：续篇')} /Parent 8 0 R /Prev 9 0 R /Dest [5 0 R /Fit] >>',
    ]);
  }
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
  bool failNotes = false;
  @override
  Future<void> saveNotes(
    String bookId,
    ReaderNoteKind kind,
    List<Map<String, dynamic>> value,
  ) async {
    if (failNotes) throw StateError('test write failure');
    await super.saveNotes(bookId, kind, value);
  }

  @override
  Future<String> publicationPath(Book book) async => path;
}

class _Selection extends Fake implements pdf.PdfTextSelectionDelegate {
  _Selection(this.ranges);
  final List<pdf.PdfPageTextRange> ranges;
  VoidCallback? onClear;
  @override
  bool get hasSelectedText => true;
  @override
  bool get isCopyAllowed => true;
  @override
  Future<List<pdf.PdfPageTextRange>> getSelectedTextRanges() async => ranges;
  @override
  Future<void> clearTextSelection() async {
    onClear?.call();
  }
}

Future<void> _waitForPdf(WidgetTester tester) async {
  for (var i = 0; i < 40 && find.text('1 / 2').evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.text('1 / 2'), findsOneWidget);
}

Future<void> _openMenu(WidgetTester tester) async {
  if (!tester
      .widget<engine.ReaderMenu>(find.byType(engine.ReaderMenu))
      .visible) {
    await tester.tapAt(tester.getCenter(find.byType(pdf.PdfViewer)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }
  expect(
    tester.widget<engine.ReaderMenu>(find.byType(engine.ReaderMenu)).visible,
    isTrue,
  );
}

Future<void> _openNotes(WidgetTester tester) async {
  await _openMenu(tester);
  await tester.tap(find.text('目录'));
  for (
    var i = 0;
    i < 30 && find.byType(engine.CatalogSheet).evaluate().isEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
  expect(find.byType(engine.CatalogSheet), findsOneWidget);
  await tester.tap(find.byType(Tab).last);
  await tester.pumpAndSettle();
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
      await _openMenu(tester);
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

  testWidgets(
    'PDF bookmarks, cross-page marks and comments survive reopening',
    (tester) async {
      final book = (await tester.runAsync(
        () => repository.importBytes(samplePdf(), '笔记.pdf'),
      ))!;
      final repo = _PdfViewerRepository('${directory.path}/${book.fileName}');
      await tester.pumpWidget(app(repo, ReaderView(book: book)));
      await _waitForPdf(tester);
      await _openMenu(tester);
      repo.failNotes = true;
      await tester.tap(find.byTooltip('加入书签'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('加入书签'), findsOneWidget);
      expect(await repo.loadNotes(book.id, ReaderNoteKind.bookmark), isEmpty);
      expect(find.textContaining('笔记保存失败'), findsOneWidget);
      repo.failNotes = false;
      await tester.tap(find.byTooltip('加入书签'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除书签'), findsOneWidget);
      expect(
        (await repo.loadNotes(
          book.id,
          ReaderNoteKind.bookmark,
        )).single['anchor'],
        containsPair('type', 'pdf'),
      );

      final doc = (await tester.runAsync(
        () => pdf.PdfDocument.openData(samplePdf()),
      ))!;
      final texts = (await tester.runAsync(
        () async => [
          for (final page in doc.pages) await page.loadStructuredText(),
        ],
      ))!;
      final selection = _Selection([
        for (final text in texts)
          pdf.PdfPageTextRange(pageText: text, start: 0, end: 5),
      ]);
      // Render the same selection toolbar used by TXT and EPUB and tap its actions.
      Future<void> selectAction(String label) async {
        final viewer = find.byType(pdf.PdfViewer);
        final toolbar =
            tester.widget<pdf.PdfViewer>(viewer).params.buildContextMenu!(
              tester.element(viewer),
              pdf.PdfViewerContextMenuBuilderParams(
                isTextSelectionEnabled: true,
                anchorA: const Offset(180, 220),
                textSelectionDelegate: selection,
                dismissContextMenu: () {},
                contextMenuFor: pdf.PdfViewerPart.selectedText,
              ),
            )!;
        final overlay = OverlayEntry(
          builder: (_) => Positioned(left: 8, top: 120, child: toolbar),
        );
        selection.onClear = overlay.remove;
        Overlay.of(tester.element(viewer)).insert(overlay);
        await tester.pumpAndSettle();
        expect(find.byType(engine.ReaderSelectionToolbar), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(engine.ReaderSelectionToolbar),
            matching: find.text(label),
          ),
        );
        await tester.pumpAndSettle();
        overlay.dispose();
      }

      await selectAction('划线');
      var marks = await repo.loadNotes(book.id, ReaderNoteKind.underline);
      expect(marks.single['text'], 'Hello\nHello');
      final anchor = ReaderAnchor.fromJson(marks.single['anchor'])!;
      expect((anchor.value['ranges'] as List).map((r) => r['page']), [1, 2]);
      expect(anchor.value['ranges'][0]['rects'], isNotEmpty);
      // Selecting the same range again must not duplicate a mark.
      await selectAction('划线');
      expect(
        await repo.loadNotes(book.id, ReaderNoteKind.underline),
        hasLength(1),
      );

      await selectAction('评论');
      await tester.enterText(find.byType(TextField), '跨页读书心得');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final comments = await repo.loadNotes(book.id, ReaderNoteKind.comment);
      expect(comments.single['text'], '跨页读书心得');
      expect(comments.single['quote'], 'Hello\nHello');
      // Verify the native PDF anchor also survives the actual SQLite store.
      await tester.runAsync(() async {
        for (final kind in ReaderNoteKind.values) {
          await repository.saveNotes(
            book.id,
            kind,
            await repo.loadNotes(book.id, kind),
          );
        }
        await repository.close();
        repository = await LocalBookshelfRepository.create(
          directory: directory,
          factory: databaseFactoryFfi,
        );
        for (final kind in ReaderNoteKind.values) {
          expect(
            await repository.loadNotes(book.id, kind),
            await repo.loadNotes(book.id, kind),
          );
        }
        final excerpts = await repository.loadExcerpts();
        expect(excerpts, hasLength(2));
        expect(excerpts.every((item) => item.anchor?.type == 'pdf'), isTrue);
      });
      await tester.runAsync(doc.dispose);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(app(repo, ReaderView(book: book)));
      await _waitForPdf(tester);
      expect(find.byTooltip('移除书签'), findsOneWidget);
      await _openNotes(tester);
      expect(
        tester
            .widget<engine.CatalogSheet>(find.byType(engine.CatalogSheet))
            .toc,
        isEmpty,
      );
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('书签'), findsOneWidget);
      expect(find.text('划线'), findsOneWidget);
      await tester.tap(find.text('评论').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('跨页读书心得'), findsOneWidget);
      await tester.tap(find.text('划线'));
      await tester.pumpAndSettle();
      // Failed deletion must keep the card so the user can retry.
      repo.failNotes = true;
      await tester.tap(find.byType(PopupMenuButton<int>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('Hello\nHello'), findsOneWidget);
      expect(find.text('删除失败，请重试'), findsOneWidget);
      repo.failNotes = false;
      await tester.tap(find.byType(PopupMenuButton<int>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('Hello\nHello'), findsNothing);
      expect(await repo.loadNotes(book.id, ReaderNoteKind.underline), isEmpty);
      await tester.tap(find.text('书签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 页').last);
      await tester.pumpAndSettle();
      expect(find.byType(engine.CatalogSheet), findsNothing);
      await _openMenu(tester);
      await tester.tap(find.byTooltip('移除书签'));
      await tester.pumpAndSettle();
      expect(await repo.loadNotes(book.id, ReaderNoteKind.bookmark), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'PDF long press opens the shared selection toolbar and comment editor',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final book = (await tester.runAsync(
        () => repository.importBytes(samplePdf(), '选文评论.pdf'),
      ))!;
      final repo = _PdfViewerRepository('${directory.path}/${book.fileName}');
      await tester.pumpWidget(app(repo, ReaderView(book: book)));
      await _waitForPdf(tester);
      final viewer = tester.widget<pdf.PdfViewer>(find.byType(pdf.PdfViewer));
      final controller = viewer.controller!;
      final text = (await tester.runAsync(
        () => controller.document.pages.first.loadStructuredText(),
      ))!;
      final word = pdf.PdfPageTextRange(pageText: text, start: 0, end: 5);
      final target = controller.documentToGlobal(
        controller
            .calcRectForRectInsidePage(pageNumber: 1, rect: word.bounds)
            .center,
      )!;
      await tester.longPressAt(target);
      for (
        var i = 0;
        i < 30 && find.byType(engine.ReaderSelectionToolbar).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(engine.ReaderSelectionToolbar), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('划线'), findsOneWidget);
      final toolbarRect = tester.getRect(
        find.byType(engine.ReaderSelectionToolbar),
      );
      expect(toolbarRect.left, greaterThanOrEqualTo(0));
      expect(toolbarRect.right, lessThanOrEqualTo(390));
      await tester.tap(
        find.descendant(
          of: find.byType(engine.ReaderSelectionToolbar),
          matching: find.text('评论'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ReaderCommentInput), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(await repo.loadNotes(book.id, ReaderNoteKind.comment), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'PDF catalog uses embedded Chinese titles, nested entries and destinations',
    (tester) async {
      final book = (await tester.runAsync(
        () => repository.importBytes(samplePdf(outline: true), '原生目录.pdf'),
      ))!;
      final repo = _PdfViewerRepository('${directory.path}/${book.fileName}');
      await tester.pumpWidget(app(repo, ReaderView(book: book)));
      await _waitForPdf(tester);
      await _openMenu(tester);
      await tester.tap(find.text('目录'));
      // Outline extraction runs in PDFium's native worker.
      for (
        var i = 0;
        i < 30 && find.byType(engine.CatalogSheet).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      final sheet = tester.widget<engine.CatalogSheet>(
        find.byType(engine.CatalogSheet),
      );
      final cover = find.descendant(
        of: find.byType(engine.CatalogSheet),
        matching: find.byKey(const ValueKey('book-original-cover')),
      );
      expect(cover, findsOneWidget);
      final image = tester.widget<Image>(cover).image;
      final source = image is ResizeImage ? image.imageProvider : image;
      expect((source as FileImage).file.path, book.coverPath);
      expect(find.byKey(const ValueKey('book-cover-title-slip')), findsNothing);
      expect(sheet.toc.map((e) => e.title), ['第一章：开篇', '第二章：续篇']);
      expect(sheet.toc.first.children.single.title, '第一节：导读');
      expect(sheet.toc.first.chapterIndex, 0);
      expect(sheet.toc.last.chapterIndex, 1);
      expect(find.text('共 3 项'), findsOneWidget);
      await tester.tap(find.text('第二章：续篇'));
      await tester.pumpAndSettle();
      expect(find.byType(engine.CatalogSheet), findsNothing);
      expect(find.text('2 / 2'), findsOneWidget);
      await _openMenu(tester);
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第一节：导读'));
      await tester.pumpAndSettle();
      final viewer = tester.widget<pdf.PdfViewer>(find.byType(pdf.PdfViewer));
      final controller = viewer.controller!;
      expect(controller.currentZoom, closeTo(1, .001));
      // XYZ specifies a location within the first page, not just its page number.
      final expected = controller.calcMatrixForClampedToNearestBoundary(
        controller.calcMatrixForDest(
          const pdf.PdfDest(1, pdf.PdfDestCommand.xyz, [0, 180, 1]),
        )!,
        viewSize: controller.viewSize,
      );
      for (var i = 0; i < 16; i++) {
        expect(controller.value.storage[i], closeTo(expected.storage[i], .001));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('scanned PDF supports page comments without text selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final book = (await tester.runAsync(
      () => repository.importBytes(samplePdf(text: false), '扫描笔记.pdf'),
    ))!;
    final repo = _PdfViewerRepository('${directory.path}/${book.fileName}');
    await tester.pumpWidget(app(repo, ReaderView(book: book)));
    await _waitForPdf(tester);
    await _openMenu(tester);
    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 页（整页评论）'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '扫描页也能记笔记');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final note = (await repo.loadNotes(book.id, ReaderNoteKind.comment)).single;
    expect(note['text'], '扫描页也能记笔记');
    expect(ReaderAnchor.fromJson(note['anchor'])!.value['page'], 1);
    expect(find.byKey(const ValueKey('pdf-page-comments-1')), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('pdf-page-comments-1'))),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderParagraphComments), findsOneWidget);
    expect(find.text('扫描页也能记笔记'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await _openMenu(tester);
    await tester.tap(find.byTooltip('隐藏段评'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pdf-page-comments-1')), findsNothing);
    expect(await repo.loadNotes(book.id, ReaderNoteKind.comment), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

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

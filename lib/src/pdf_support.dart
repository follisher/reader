import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart' as pdf;

import 'models.dart';

/// PDFium performs document work asynchronously on its worker. Initialization
/// and image encoding stay on Flutter's main isolate.
Future<BookContent> parsePdfBook(Uint8List bytes, String fileName) async {
  pdf.PdfDocument? document;
  try {
    await pdf.pdfrxFlutterInitialize();
    document = await pdf.PdfDocument.openData(bytes, sourceName: fileName);
    if (document.pages.isEmpty) {
      throw const FormatException('PDF 没有可阅读的页面');
    }
    final chapters = <BookChapter>[];
    var extractedBytes = 0;
    for (final page in document.pages) {
      final text = (await page.loadText())?.fullText ?? '';
      extractedBytes += utf8.encode(text).length;
      if (extractedBytes > 150 * 1024 * 1024) {
        throw const FormatException('PDF 文本内容超过解析上限');
      }
      chapters.add(
        BookChapter(
          id: 'page-${page.pageNumber}',
          title: '第 ${page.pageNumber} 页',
          blocks: text.trim().isEmpty
              ? const []
              : ['<p>${const HtmlEscape().convert(text)}</p>'],
        ),
      );
    }
    final page = document.pages.first;
    // Bound both dimensions even for unusually tall or wide first pages.
    final scale = 480 / (page.width > page.height ? page.width : page.height);
    final rendered = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
      backgroundColor: 0xFFFFFFFF,
    );
    Uint8List? cover;
    if (rendered != null) {
      try {
        final image = await rendered.createImage();
        try {
          cover = (await image.toByteData(format: ui.ImageByteFormat.png))
              ?.buffer
              .asUint8List();
        } finally {
          image.dispose();
        }
      } finally {
        rendered.dispose();
      }
    }
    var title = p.basenameWithoutExtension(fileName);
    if (title.contains('%')) {
      try {
        title = Uri.decodeComponent(title);
      } catch (_) {
        // A literal percent sign or non-encoded Unicode filename is valid.
      }
    }
    return MemoryBookContent(
      title: title,
      author: '',
      chapters: chapters,
      coverResourcePath: cover == null ? null : 'pdf/cover.png',
      resources: {'pdf/cover.png': ?cover},
    );
  } on pdf.PdfPasswordException {
    throw const FormatException('PDF 需要密码，请先解密后再导入');
  } on pdf.PdfException {
    throw const FormatException('无法读取 PDF，请确认文件完整且未损坏');
  } finally {
    await document?.dispose();
  }
}

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'PDF layout migrates legacy pagination and persists either reading mode',
    () async {
      final directory = await Directory.systemTemp.createTemp('pdf_settings_');
      final repository = await LocalBookshelfRepository.create(
        directory: directory,
        factory: databaseFactoryFfi,
      );
      try {
        expect((await repository.loadSettings()).pdfLayout, 'scrollHorizontal');
        for (final stored in [
          'paginated',
          'scrollHorizontal',
          'scrollVertical',
        ]) {
          await repository.saveSettings(
            ReaderSettings(pdfLayout: stored, fontSize: 24, epubScroll: false),
          );
          final restored = await repository.loadSettings();
          expect(
            restored.pdfLayout,
            stored == 'scrollVertical' ? 'scrollVertical' : 'scrollHorizontal',
          );
          expect(restored.fontSize, 24);
          expect(restored.epubScroll, isFalse);
        }
      } finally {
        await repository.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('PDF receives a lightweight native-reader manifest', () async {
    final content = await LocalBookParser().parse(
      Uint8List.fromList(const [0x25, 0x50, 0x44, 0x46]),
      '示例文档.pdf',
    );

    expect(content.title, '示例文档');
    expect(content.chapters, hasLength(1));
    expect(content.chapters.single.blocks, isEmpty);
  });

  test('PDF first-page thumbnail is cached as the bookshelf cover', () async {
    final directory = await Directory.systemTemp.createTemp('pdf_cover_');
    final repository = await LocalBookshelfRepository.create(
      directory: directory,
      factory: databaseFactoryFfi,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('dk.nota.flutter_readium/main');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'renderPdfCover') {
        expect(call.arguments, {'path': isA<String>(), 'maxWidth': 360});
        return Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]);
      }
      return null;
    });
    try {
      final book = await repository.importBytes(
        Uint8List.fromList(const [0x25, 0x50, 0x44, 0x46]),
        '有封面的文档.pdf',
      );
      expect(book.coverPath, isNotNull);
      expect(await File(book.coverPath!).readAsBytes(), [
        0x89,
        0x50,
        0x4E,
        0x47,
      ]);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      await repository.close();
      await directory.delete(recursive: true);
    }
  });
}

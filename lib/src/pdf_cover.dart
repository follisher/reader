import 'package:flutter/services.dart';

/// Renders the first PDF page with the Readium native runtime.
///
/// Keeping this at cover-thumbnail size avoids loading a full PDF into Dart
/// memory. Unsupported platforms simply keep the bookshelf's generated cover.
class PdfCoverRenderer {
  PdfCoverRenderer._();

  static const _channel = MethodChannel('dk.nota.flutter_readium/main');

  static Future<Uint8List?> firstPage(String path) async {
    try {
      return await _channel.invokeMethod<Uint8List>('renderPdfCover', {
        'path': path,
        'maxWidth': 360,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      // A damaged or password-protected PDF remains readable when supported
      // by the native navigator, even if no thumbnail can be produced.
      return null;
    }
  }
}

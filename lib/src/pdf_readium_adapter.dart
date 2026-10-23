import 'package:flutter_readium/flutter_readium.dart';

/// PDF fragments contain 1-based pages, not reading-order resource indices.
Locator? pdfLocatorForLink(Link link, Publication publication) {
  final locator = publication.locatorFromLink(link);
  if (locator == null) return null;
  final fragment = Uri.tryParse(link.href)?.fragment ?? '';
  final match = RegExp(r'(?:^|&)page=(\d+)(?:&|$)').firstMatch(fragment);
  final page = int.tryParse(match?.group(1) ?? '');
  if (page == null || page < 1) return locator;
  return Locator(
    href: locator.href,
    type: locator.type,
    title: link.title ?? locator.title,
    locations: Locations(position: page, fragments: ['page=$page']),
  );
}

/// Owns the singleton Readium PDF session for one reader route.
class PdfReadiumAdapter {
  static PdfReadiumAdapter? _owner;
  static Future<void> _closing = Future.value();

  final FlutterReadium _reader = FlutterReadium();
  Future<Publication>? _opening;
  bool _disposed = false;

  Future<Publication> open(String path) async {
    await _closing;
    if (_disposed) throw StateError('阅读器已关闭');
    if (_owner != null && _owner != this) {
      throw StateError('请先关闭已打开的 PDF 阅读器');
    }
    _owner = this;
    try {
      _opening = _reader.openPublication(Uri.file(path).toString());
      return await _opening!;
    } catch (_) {
      await _reader.closePublication();
      if (_owner == this) _owner = null;
      rethrow;
    }
  }

  Stream<Locator> get positions => _reader.onTextLocatorChanged;
  Stream<ReadiumError> get errors => _reader.onErrorEvent;
  Future<void> previous() => _reader.goBackward();
  Future<void> next() => _reader.goForward();
  Future<bool> goTo(Locator locator) => _reader.goToLocator(locator);
  Future<bool> goByLink(Link link, Publication publication) async {
    final locator = pdfLocatorForLink(link, publication);
    return locator != null && await goTo(locator);
  }

  Future<bool> goToProgression(double progression) =>
      _reader.goToProgression(progression);
  Future<void> configure(PDFPreferences preferences) =>
      _reader.setPDFPreferences(preferences);

  Future<void> dispose() {
    _disposed = true;
    if (_owner != this) return Future.value();
    final opening = _opening;
    _closing = () async {
      try {
        await opening;
      } catch (_) {
        // Opening errors are reported by the view.
      }
      if (_owner != this) return;
      try {
        await _reader.closePublication();
      } finally {
        if (_owner == this) _owner = null;
      }
    }();
    _closing = _closing.catchError((Object _) {});
    return _closing;
  }
}

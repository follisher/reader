import 'package:flutter_readium/flutter_readium.dart';

/// Owns the plugin's singleton publication. A second reader cannot accidentally
/// replace or close the first reader's native session.
class EpubReadiumAdapter {
  static EpubReadiumAdapter? _owner;
  static Future<void> _closing = Future.value();
  final FlutterReadium _reader = FlutterReadium();
  Future<Publication>? _opening;
  bool _disposed = false;

  Future<Publication> open(String path, EPUBPreferences preferences) async {
    await _closing;
    if (_disposed) throw StateError('阅读器已关闭');
    if (_owner != null && _owner != this) throw StateError('请先关闭已打开的 EPUB 阅读器');
    _owner = this;
    try {
      _reader.setDefaultPreferences(preferences);
      _opening = _reader.openPublication(Uri.file(path).toString());
      return await _opening!;
    } catch (_) {
      await _reader.closePublication();
      if (_owner == this) _owner = null;
      rethrow;
    }
  }

  Stream<Locator> get positions => _reader.onTextLocatorChanged;
  Stream<ReadiumReaderStatus> get statuses => _reader.onReaderStatusChanged;
  Stream<ReadiumError> get errors => _reader.onErrorEvent;
  Future<void> next() => _reader.goForward();
  Future<bool> goTo(Locator locator) => _reader.goToLocator(locator);
  Future<bool> goByLink(Link link, Publication publication) =>
      _reader.goByLink(link, publication);
  Future<void> configure(EPUBPreferences preferences) =>
      _reader.setEPUBPreferences(preferences);
  Future<void> decorate(List<ReaderDecoration> decorations) =>
      _reader.applyDecorations('reader-notes', decorations);

  Future<void> dispose() {
    _disposed = true;
    if (_owner != this) return Future.value();
    final opening = _opening;
    _closing = () async {
      try {
        await opening;
      } catch (_) {
        /* Open errors are reported by open. */
      }
      if (_owner != this) return;
      try {
        await _reader.closePublication();
      } finally {
        if (_owner == this) _owner = null;
      }
    }();
    // Keep a failed close from poisoning all future opens.
    _closing = _closing.catchError((Object _) {});
    return _closing;
  }
}

import 'dart:ui';

enum ReaderPointerResult { tap, drag, selection, cancelled }

/// Kept across widget rebuilds: selection callbacks commonly rebuild the reader
/// between pointer-down and pointer-up.
class ReaderPointerSession {
  Duration? _started;
  Offset? _origin;
  bool _moved = false;
  bool _selected = false;

  void start(Duration time, Offset position) {
    _started = time;
    _origin = position;
    _moved = false;
    _selected = false;
  }

  bool move(Offset position) {
    if (_origin == null || _moved) return false;
    if ((position - _origin!).distance <= 3) return false;
    _moved = true;
    return true;
  }

  void selected() => _selected = true;

  ReaderPointerResult finish(Duration time) {
    final started = _started;
    cancel();
    if (started == null) return ReaderPointerResult.cancelled;
    if (_selected) return ReaderPointerResult.selection;
    if (_moved) return ReaderPointerResult.drag;
    // Android/iOS own long-press selection. Releasing it must never toggle the
    // Flutter reader menu, even if the asynchronous selection event is late.
    if (time - started >= const Duration(milliseconds: 400)) {
      return ReaderPointerResult.selection;
    }
    return ReaderPointerResult.tap;
  }

  void cancel() {
    _started = null;
    _origin = null;
  }
}

import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;

import 'repository.dart';

/// One reading session, keyed by the shelf ID even for external book sources.
/// Retain failed snapshots because the engine fires store writes without awaiting.
class RepositoryReaderNotes {
  RepositoryReaderNotes(this.repository, this.bookId, this.onError);
  final BookshelfRepository repository;
  final String bookId;
  final void Function(Object?) onError;
  final _latest = <ReaderNoteKind, List<Map<String, dynamic>>>{};
  final _failed = <ReaderNoteKind, Object>{};
  Future<void> _pending = Future.value();
  late final bookmarks = RepositoryBookmarkStore(this);
  late final underlines = RepositoryUnderlineStore(this);
  late final comments = RepositoryCommentStore(this);

  Future<void> get pending => _pending;
  Object? errorFor(ReaderNoteKind kind) => _failed[kind];

  Future<List<Map<String, dynamic>>> load(ReaderNoteKind kind) async {
    await _pending;
    final rows = _latest[kind] ??= await repository.loadNotes(bookId, kind);
    return rows.map((row) => Map<String, dynamic>.of(row)).toList();
  }

  Future<void> save(ReaderNoteKind kind, List<Map<String, dynamic>> rows) {
    final snapshot = rows.map((row) => Map<String, dynamic>.of(row)).toList();
    _latest[kind] = snapshot;
    _pending = _pending.then((_) async {
      try {
        await repository.saveNotes(bookId, kind, snapshot);
        _failed.remove(kind);
      } catch (error) {
        _failed[kind] = error;
      }
      onError(_failed.isEmpty ? null : _failed.values.first);
    });
    return _pending;
  }

  Future<void> retry() async {
    await _pending;
    for (final kind in _failed.keys.toList()) {
      await save(kind, _latest[kind]!);
    }
  }
}

class RepositoryBookmarkStore extends engine.ReaderBookmarkStore {
  RepositoryBookmarkStore(this.notes);
  final RepositoryReaderNotes notes;
  @override
  Future<List<engine.Bookmark>> load(Object bookId) async => (await notes.load(
    ReaderNoteKind.bookmark,
  )).map(engine.Bookmark.fromJson).toList();
  @override
  Future<void> save(Object bookId, List<engine.Bookmark> bookmarks) => notes
      .save(ReaderNoteKind.bookmark, bookmarks.map((v) => v.toJson()).toList());
}

class RepositoryUnderlineStore extends engine.ReaderUnderlineStore {
  RepositoryUnderlineStore(this.notes);
  final RepositoryReaderNotes notes;
  @override
  Future<List<engine.Underline>> load(Object bookId) async => (await notes.load(
    ReaderNoteKind.underline,
  )).map(engine.Underline.fromJson).toList();
  @override
  Future<void> save(Object bookId, List<engine.Underline> underlines) =>
      notes.save(
        ReaderNoteKind.underline,
        underlines.map((v) => v.toJson()).toList(),
      );
}

class RepositoryCommentStore extends engine.ReaderCommentStore {
  RepositoryCommentStore(this.notes);
  final RepositoryReaderNotes notes;
  @override
  Future<List<engine.Comment>> load(Object bookId) async => (await notes.load(
    ReaderNoteKind.comment,
  )).map(engine.Comment.fromJson).toList();
  @override
  Future<void> save(Object bookId, List<engine.Comment> comments) => notes.save(
    ReaderNoteKind.comment,
    comments.map((v) => v.toJson()).toList(),
  );
}

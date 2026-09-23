import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:html/parser.dart' as html;

import 'models.dart';
import 'repository.dart';

/// Bridges the existing shelf to the engine. Opening loads metadata only;
/// chapter HTML is read and normalized on demand with a bounded local cache.
class RepositoryBookSource extends engine.BookSource {
  RepositoryBookSource(this.repository, this.book);
  final BookshelfRepository repository;
  final Book book;
  Future<BookContent>? _content;
  final _chapters = <int, TextChapter>{};
  final _pending = <int, Future<TextChapter>>{};

  Future<BookContent> content() async {
    try {
      return await (_content ??= repository.openBook(book));
    } catch (_) {
      _content = null;
      rethrow;
    }
  }

  @override
  Future<engine.BookManifest> loadManifest() async {
    final data = await content();
    if (data.chapters.isEmpty) throw const FormatException('这本书没有可阅读的章节');
    final chapterTexts = <int, Future<TextChapter>>{};
    Future<TextChapter> textFor(int index) => chapterTexts.putIfAbsent(
      index,
      () async => TextChapter.fromChapter(await data.readChapter(index)),
    );
    Future<engine.BookTocEntry?> mapEntry(BookTocEntry entry) async {
      final chapter = entry.chapter;
      if (chapter == null || chapter < 0 || chapter >= data.chapters.length) {
        return null;
      }
      final children = <engine.BookTocEntry>[];
      for (final child in entry.children) {
        final mapped = await mapEntry(child);
        if (mapped != null) children.add(mapped);
      }
      final text = entry.block == null && children.isEmpty
          ? null
          : await textFor(chapter);
      return engine.BookTocEntry(
        id: entry.id,
        title:entry.title,
        chapterIndex: chapter,
        charOffset: text == null
            ? 0
            : text.toEngine(text.canonicalForBlock(entry.block ?? 0), 2),
        children: children,
      );
    }

    final toc = <engine.BookTocEntry>[];
    for (final entry in data.toc) {
      final mapped = await mapEntry(entry);
      if (mapped != null) toc.add(mapped);
    }

    return engine.BookManifest(
      id: book.id,
      title: data.title,
      author: data.author,
      intro: '',
      coverColor: const Color(0xFF728577),
      chapterTitles: data.chapters.map((c) => c.title).toList(),
      toc: toc,
    );
  }

  Future<TextChapter> textChapter(int index) async {
    final cached = _chapters.remove(index);
    if (cached != null) {
      _chapters[index] = cached;
      return cached;
    }
    return _pending.putIfAbsent(index, () async {
      try {
        final data = await content();
        final result = TextChapter.fromChapter(await data.readChapter(index));
        _chapters[index] = result;
        while (_chapters.length > 8) {
          _chapters.remove(_chapters.keys.first);
        }
        return result;
      } finally {
        _pending.remove(index);
      }
    });
  }

  @override
  Future<String> loadChapterBody(int chapterIndex) async =>
      (await textChapter(chapterIndex)).body;
}

/// Canonical offsets omit newlines and reader-owned indentation. The engine's
/// offsets include indentation, so conversion is required when saving/resuming.
class TextChapter {
  TextChapter(this.paragraphs, this.blockIndices);
  final List<String> paragraphs;
  final List<int> blockIndices;
  String get body => paragraphs.join('\n');
  int get length => paragraphs.fold(0, (n, p) => n + p.length);

  factory TextChapter.fromChapter(BookChapter chapter) {
    final paragraphs = <String>[];
    final blocks = <int>[];
    for (var i = 0; i < chapter.blocks.length; i++) {
      final fragment = html.parseFragment(chapter.blocks[i]);
      for (final node in fragment.querySelectorAll('script,style')) {
        node.remove();
      }
      for (final image in fragment.querySelectorAll('img')) {
        final alt = image.attributes['alt']?.trim();
        image.replaceWith(
          html.parseFragment('<p></p>').nodes.first
            ..text = alt?.isNotEmpty == true ? '【图片：$alt】' : '【图片，请切换图文阅读查看】',
        );
      }
      for (final br in fragment.querySelectorAll('br')) {
        br.replaceWith(html.parseFragment('\n').nodes.first);
      }
      for (final node in fragment.querySelectorAll(
        'p,div,h1,h2,h3,h4,li,tr,blockquote',
      )) {
        node.append(html.parseFragment('\n').nodes.first);
      }
      for (final line in (fragment.text ?? '').split('\n')) {
        final text = line.trim();
        if (text.isEmpty) continue;
        paragraphs.add(text);
        blocks.add(i);
      }
    }
    if (paragraphs.isEmpty) {
      paragraphs.add('本章没有文本内容，请切换图文阅读查看。');
      blocks.add(0);
    }
    return TextChapter(paragraphs, blocks);
  }

  int canonicalForBlock(int block) {
    var offset = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      if (blockIndices[i] >= block) return offset;
      offset += paragraphs[i].length;
    }
    return offset;
  }

  int blockForCanonical(int offset) {
    var sum = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      sum += paragraphs[i].length;
      if (offset < sum) return blockIndices[i];
    }
    return blockIndices.last;
  }

  int toCanonical(int engineOffset, int indent) {
    var engineStart = 0;
    var canonicalStart = 0;
    for (final p in paragraphs) {
      if (engineOffset < engineStart + indent + p.length) {
        return canonicalStart +
            (engineOffset - engineStart - indent).clamp(0, p.length);
      }
      engineStart += indent + p.length;
      canonicalStart += p.length;
    }
    return canonicalStart;
  }

  int toEngine(int canonicalOffset, int indent) {
    var canonicalStart = 0;
    var engineStart = 0;
    for (final p in paragraphs) {
      if (canonicalOffset < canonicalStart + p.length) {
        final within = (canonicalOffset - canonicalStart).clamp(0, p.length);
        return engineStart + (within == 0 ? 0 : indent + within);
      }
      canonicalStart += p.length;
      engineStart += indent + p.length;
    }
    return engineStart;
  }
}

/// The engine debounces for 400 ms and flushes on background/dispose. This
/// adapter serializes writes and reports failures instead of dropping futures.
class RepositoryProgressStore extends engine.ReaderProgressStore {
  RepositoryProgressStore({
    required this.repository,
    required this.book,
    required this.source,
    required this.config,
    required this.manifest,
    required this.canSave,
    required this.onError,
  });
  final BookshelfRepository repository;
  final Book book;
  final engine.BookSource source;
  final engine.ReaderConfig config;
  final engine.BookManifest manifest;
  final bool Function() canSave;
  final void Function(Object?) onError;
  ReadingLocation? latest;
  Future<void> _queue = Future.value();
  engine.ReadingPosition? _retryPosition;
  int _retryIndent = 2;

  @override
  Future<engine.ReadingPosition?> load(Object bookId) async {
    if (manifest.chapterCount == 0) return null;
    final chapter = book.location.chapter.clamp(0, manifest.chapterCount - 1);
    var offset = book.location.charOffset ?? 0;
    if (source case final RepositoryBookSource local) {
      final text = await local.textChapter(chapter);
      offset = text.toEngine(
        book.location.charOffset ?? text.canonicalForBlock(book.location.block),
        config.firstLineIndent,
      );
    }
    return engine.ReadingPosition(chapterIndex: chapter, charOffset: offset);
  }

  @override
  Future<void> save(Object bookId, engine.ReadingPosition position) {
    if (!canSave()) return _queue;
    return _enqueue(position, config.firstLineIndent);
  }

  Future<void> _enqueue(engine.ReadingPosition position, int indent) {
    _retryPosition = position;
    _retryIndent = indent;
    _queue = _queue.then((_) async {
      try {
        var offset = position.charOffset;
        var block = 0;
        var fraction = 0.0;
        if (source case final RepositoryBookSource local) {
          final text = await local.textChapter(position.chapterIndex);
          offset = text.toCanonical(offset, indent);
          block = text.blockForCanonical(offset);
          fraction = text.length == 0 ? 0 : offset / text.length;
        }
        final location = ReadingLocation(
          chapter: position.chapterIndex,
          block: block,
          charOffset: offset,
          progress: ((position.chapterIndex + fraction) / manifest.chapterCount)
              .clamp(0, 1),
        );
        await repository.saveLocation(book.id, location);
        latest = location;
        onError(null);
      } catch (error) {
        onError(error);
      }
    });
    return _queue;
  }

  Future<void> retry() =>
      _retryPosition == null ? _queue : _enqueue(_retryPosition!, _retryIndent);
  Future<void> get pending => _queue;
}

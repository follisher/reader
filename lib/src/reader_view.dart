import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader/src/widget/share_card_sheet.dart';
import 'package:url_launcher/url_launcher.dart';

import 'book_reader_adapter.dart';
import 'html_reader_view.dart';
import 'models.dart';
import 'providers.dart';
import 'repository.dart';
import 'reader_notes.dart';
import 'reader_comment_sheets.dart';

/// Default text reader. Supply [source] for network/decrypted/custom chapters.
/// Change book/source by giving the view a new key.
class ReaderView extends ConsumerStatefulWidget {
  const ReaderView({
    super.key,
    required this.book,
    this.source,
    this.controller,
  });
  final Book book;
  final engine.BookSource? source;
  final engine.BookReaderController? controller;

  @override
  ConsumerState<ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends ConsumerState<ReaderView>
    with WidgetsBindingObserver {
  late final BookshelfRepository _repository;
  late final engine.BookSource _source;
  late final engine.BookReaderController _controller;
  final _config = engine.ReaderConfig();
  late final RepositoryReaderNotes _notes;
  final _commentsRefresh = ValueNotifier<int>(0);
  Object? _notesError;
  RepositoryProgressStore? _progress;
  Object? _error;
  Object? _saveError;
  bool _loaded = false;
  bool _closing = false;
  bool _disposed = false;
  Timer? _settingsTimer;
  Future<void> _settingsWrites = Future.value();

  @override
  void initState() {
    super.initState();
    _repository = ref.read(bookshelfRepositoryProvider);
    _notes = RepositoryReaderNotes(_repository, widget.book.id, (error) {
      if (_disposed) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _notesError = error);
      });
    });
    _source = widget.source ?? RepositoryBookSource(_repository, widget.book);
    _controller = widget.controller ?? engine.BookReaderController();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object>([
        _repository.loadSettings(),
        _source.loadManifest(),
      ]);
      if (!mounted) return;
      if ((values.last as engine.BookManifest).chapterCount == 0) {
        throw const FormatException('这本书没有可阅读的章节');
      }
      final settings = values.first as ReaderSettings;
      while (_config.fontSize < settings.fontSize.round().clamp(14, 32)) {
        _config.increaseFont();
      }
      while (_config.fontSize > settings.fontSize.round().clamp(14, 32)) {
        _config.decreaseFont();
      }
      _config
        ..setTheme(
          settings.dark
              ? engine.ReaderTheme.night
              : engine.ReaderTheme.fromAlias(settings.theme),
        )
        ..setFlipType(
          engine.FlipType.values.firstWhere(
            (v) => v.name == settings.flipMode,
            orElse: () => engine.FlipType.scrollVertical,
          ),
        )
        ..setLineHeight(settings.lineHeight)
        ..setParagraphSpacing(settings.paragraphSpacing)
        ..setFirstLineIndent(2)
        ..setJustify(true)
        ..setDimLevel(settings.dimLevel)
        ..setFontFamily(settings.fontFamily)
        //段尾评论角标
        ..setSegmentCommentsVisible(visible: true);
      _config.addListener(_settingsChanged);
      _progress = RepositoryProgressStore(
        repository: _repository,
        book: widget.book,
        source: _source,
        config: _config,
        manifest: values.last as engine.BookManifest,
        canSave: () => _controller.position != null,
        onError: _reportSaveError,
      );
      setState(() {
        _loaded = true;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _reportSaveError(Object? error) {
    if (_disposed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _saveError = error);
    });
  }

  ReaderSettings _settings() => ReaderSettings(
    fontSize: _config.fontSize,
    dark: _config.theme.isDark,
    theme: _config.theme.alias,
    flipMode: _config.flipType.name,
    lineHeight: _config.lineHeight,
    paragraphSpacing: _config.paragraphSpacing,
    firstLineIndent: 2,
    justify: true,
    dimLevel: _config.dimLevel,
    fontFamily: _config.fontFamily,
  );

  void _settingsChanged() {
    _settingsTimer?.cancel();
    _settingsTimer = Timer(const Duration(milliseconds: 400), _saveSettings);
  }

  Future<void> _saveSettings() {
    final settings = _settings();
    _settingsWrites = _settingsWrites.then((_) async {
      try {
        await _repository.saveSettings(settings);
      } catch (error) {
        _reportSaveError(error);
      }
    });
    return _settingsWrites;
  }

  Future<void> _flush() async {
    _settingsTimer?.cancel();
    final position = _controller.position;
    if (position != null) await _progress?.save(widget.book.id, position);
    await _progress?.pending;
    await _notes.pending;
    if (_loaded) await _saveSettings();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveComments(List<engine.Comment> comments) async {
    await _notes.comments.save(widget.book.id, comments);
    if (!_disposed) _commentsRefresh.value++;
    final error = _notes.errorFor(ReaderNoteKind.comment);
    if (error != null) throw error;
  }

  Future<void> _onTextAction(
    engine.ReaderTextAction action,
    engine.ReaderSelection selection,
  ) async {
    _controller.stopAutoTurn();
    try {
      switch (action) {
        case engine.ReaderTextAction.copy:
          await Clipboard.setData(ClipboardData(text: selection.text));
          _toast('已复制');
        case engine.ReaderTextAction.comment:
          if (selection.start < 0 || selection.end <= selection.start) {
            _toast('无法定位选中文字，请重新选择');
            return;
          }
          final createdAt = DateTime.now().millisecondsSinceEpoch;
          await showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => ReaderCommentInput(
              quote: selection.text,
              onSave: (text) async {
                final comment = engine.Comment(
                  chapterIndex: selection.chapterIndex,
                  start: selection.start,
                  end: selection.end,
                  quote: selection.text,
                  text: text,
                  chapterTitle: selection.chapterTitle,
                  createdAt: createdAt,
                );
                final comments = await _notes.comments.load(widget.book.id);
                comments.removeWhere((c) => c.key == comment.key);
                comments.add(comment);
                await _saveComments(comments);
              },
            ),
          );
        case engine.ReaderTextAction.query:
          final uri = Uri.https('www.baidu.com', '/s', {'wd': selection.text});
          if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            _toast('无法打开浏览器');
          }
        case engine.ReaderTextAction.share:
          if (!mounted) return;
          await ShareCardSheet.show(
            context,
            bookTitle: widget.book.title,
            author: widget.book.author,
            coverPath: widget.book.coverPath,
            chapterTitle: selection.chapterTitle,
            quote: selection.text,
            readerTheme: _config.theme,
            textStyle: _config.textStyle,
          );
        case engine.ReaderTextAction.highlight:
          break;
      }
    } catch (_) {
      _toast('操作失败，请重试');
    }
  }

  Future<void> _onSegmentTap(engine.ReaderSegmentTap segment) async {
    _controller.stopAutoTurn();
    try {
      final comments = (await _notes.comments.load(
        widget.book.id,
      )).where(segment.contains).toList();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ReaderParagraphComments(
          comments: comments,
          onDelete: (comment) async {
            final all = await _notes.comments.load(widget.book.id);
            all.removeWhere((c) => c.key == comment.key);
            await _saveComments(all);
          },
        ),
      );
    } catch (_) {
      _toast('读取评论失败，请重试');
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _controller.stopAutoTurn();
    await _flush();
    if (mounted) await Navigator.of(context).maybePop();
    _closing = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _controller.stopAutoTurn();
      unawaited(_flush());
    }
  }

  Future<void> _openHtml() async {
    _controller.stopAutoTurn();
    await _flush();
    if (!mounted) return;
    final b = widget.book;
    final book = Book(
      id: b.id,
      title: b.title,
      author: b.author,
      format: b.format,
      source: b.source,
      fileName: b.fileName,
      addedAt: b.addedAt,
      coverPath: b.coverPath,
      cacheReady: b.cacheReady,
      location: _progress?.latest ?? b.location,
    );
    // Replace to prevent the hidden text reader from overwriting HTML progress.
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => HtmlReaderView(book: book)),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _settingsTimer?.cancel();
    _config.removeListener(_settingsChanged);
    unawaited(_flush());
    // Child BookReader still reads config during its own disposal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _commentsRefresh.dispose();
      _config.dispose();
      if (widget.controller == null) _controller.dispose();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.book.title)),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error is FormatException
                          ? (_error as FormatException).message
                          : '打开图书失败：$_error',
                    ),
                    TextButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
        ),
      );
    }
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) unawaited(_flush());
      },
      child: Scaffold(
        body: Stack(
          children: [
            engine.BookReader(
              source: _source,
              config: _config,
              controller: _controller,
              progressStore: _progress!,
              bookmarkStore: _notes.bookmarks,
              underlineStore: _notes.underlines,
              commentStore: _notes.comments,
              commentsRefresh: _commentsRefresh,
              onSegmentCommentTap: _onSegmentTap,
              labels: engine.ReaderLabels.forLanguageCode('zh'),
              showSystemBarsWithMenu: false,
              //长按划线
              enableTextSelection: true,
              onClose: _close,
              onTextAction: _onTextAction,
            ),
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                if (!_controller.isMenuVisible ||
                    _controller.isMenuPanelExpanded) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  top: MediaQuery.paddingOf(context).top + 56,
                  right: 12,
                  child: Material(
                    borderRadius: BorderRadius.circular(12),
                    color: _config.theme.panelColor,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.book.format == BookFormat.epub &&
                            widget.source == null)
                          TextButton(
                            onPressed: _openHtml,
                            style: TextButton.styleFrom(
                              foregroundColor: _config.theme.textColor,
                            ),
                            child: const Text('图文阅读'),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (_saveError != null || _notesError != null)
              Positioned(
                top: 100,
                left: 16,
                right: 16,
                child: Material(
                  child: ListTile(
                    title: const Text('保存失败，请重试'),
                    trailing: TextButton(
                      onPressed: () async {
                        await _notes.retry();
                        await _progress?.retry();
                        await _saveSettings();
                      },
                      child: const Text('重试'),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

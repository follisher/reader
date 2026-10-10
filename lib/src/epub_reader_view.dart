import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;
import 'package:flutter_readium/flutter_readium.dart' as rd;
import 'package:flutter_readium/reader_channel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';
import 'epub_readium_adapter.dart';
import 'epub_underline_range.dart';
import 'epub_selection_script.dart';
import 'epub_selection_toolbar_layout.dart';
import 'epub_continuous_view.dart';
import 'epub_continuous_document.dart';
import 'providers.dart';
import 'reader_comment_sheets.dart';
import 'reader_notes.dart';
import 'repository.dart';
import 'widget/share_card_sheet.dart';

/// EPUB surface using the same menu, comment editor and share card as TXT.
class EpubReaderView extends ConsumerStatefulWidget {
  const EpubReaderView({
    super.key,
    required this.book,
    this.initialAnchor,
    this.initialChapter,
  });
  final Book book;
  final ReaderAnchor? initialAnchor;
  final int? initialChapter;
  @override
  ConsumerState<EpubReaderView> createState() => _EpubReaderViewState();
}

class _EpubReaderViewState extends ConsumerState<EpubReaderView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _reader = EpubReadiumAdapter();
  final _config = engine.ReaderConfig();
  final _menu = ValueNotifier(false);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  late final BookshelfRepository _repository;
  late final RepositoryReaderNotes _notes;
  final _rows = <ReaderNoteKind, List<Map<String, dynamic>>>{};
  rd.Publication? _publication;
  rd.Locator? _position, _initial;
  ReaderSettings _settings = const ReaderSettings();
  Timer? _saveTimer, _settingsTimer, _autoResumeTimer;
  Future<void> _writes = Future.value();
  String? _error;
  bool _ready = false, _closing = false, _turning = false;
  bool _opening = false;
  Set<String> _selectedUnderlineIds = const <String>{};
  rd.TextSelectionEvent? _activeSelection;
  Rect? _selectionBounds;
  bool _exiting = false;
  final _readerSurface = GlobalKey();
  final _nativeSurface = GlobalKey();
  ReadiumReaderChannel? _selectionChannel;
  bool _selectionBusy = false;
  bool _acceptSelectionEvents = true;
  Object? _positionError;
  Duration _autoInterval = const Duration(milliseconds: 32500);
  late final AnimationController _autoProgress;
  bool _autoReading = false, _autoBarCollapsed = false;
  bool _autoSheetOpen = false,
      _settingsPanelOpen = false,
      _autoResumePending = false;
  bool _foreground = true;
  int _autoGeneration = 0;
  bool get _autoPaused =>
      _menu.value ||
      _autoSheetOpen ||
      _settingsPanelOpen ||
      _autoResumePending ||
      !_foreground ||
      _activeSelection != null ||
      _closing;
  final _continuous = GlobalKey<EpubContinuousViewState>();
  Future<BookContent>? _continuousContent;
  List<rd.ReaderDecoration> _decorations = const [];
  bool _lastScrollMode = true;
  int _modeGeneration = 0;
  bool _nativeReady = false;
  rd.Locator? _pendingNativeLocator;
  bool get _continuousMode =>
      _config.flipType == engine.FlipType.scrollVertical;

  Future<void> _goTo(rd.Locator locator) async {
    if (_continuousMode) {
      await _continuous.currentState?.goTo(locator);
    } else {
      await _reader.goTo(locator);
    }
  }

  Future<void> _goByLink(rd.Link link, rd.Publication publication) async {
    final locator = publication.locatorFromLink(link);
    if (locator != null) await _goTo(locator);
  }

  Future<void> _restoreNativePosition() async {
    final locator = _pendingNativeLocator;
    if (!_nativeReady || _continuousMode || _closing || locator == null) return;
    final generation = _modeGeneration;
    await _reader.configure(_preferences());
    if (generation != _modeGeneration || _continuousMode || _closing) return;
    await _reader.goTo(locator);
    if (generation == _modeGeneration) _pendingNativeLocator = null;
  }

  @override
  void initState() {
    super.initState();
    _autoProgress = AnimationController(vsync: this, duration: _autoInterval)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) unawaited(_turnAutoPage());
      });
    _repository = ref.read(bookshelfRepositoryProvider);
    _notes = RepositoryReaderNotes(_repository, widget.book.id, (error) {
      if (error != null) _report(error);
    });
    WidgetsBinding.instance.addObserver(this);
    _menu.addListener(_menuChanged);
    unawaited(_open());
  }

  void _report(Object error) {
    if (mounted && !_closing && !_exiting) {
      setState(() => _error = '操作失败：$error');
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    if (mounted) setState(() => _error = null);
    try {
      if (_repository is! PublicationFileRepository) {
        throw StateError('仓库需要实现 PublicationFileRepository 才能打开 EPUB');
      }
      _settings = await _repository.loadSettings();
      for (final kind in ReaderNoteKind.values) {
        _rows[kind] = await _notes.load(kind);
      }
      if (!mounted) return;
      while (_config.fontSize < _settings.fontSize.round().clamp(14, 32)) {
        _config.increaseFont();
      }
      while (_config.fontSize > _settings.fontSize.round().clamp(14, 32)) {
        _config.decreaseFont();
      }
      _config
        ..setTheme(
          engine.ReaderTheme.fromAlias(
            _settings.dark ? 'night' : _settings.theme,
          ),
        )
        ..setLineHeight(_settings.lineHeight)
        ..setParagraphSpacing(_settings.paragraphSpacing)
        ..setFontFamily(_settings.fontFamily)
        ..setDimLevel(_settings.dimLevel)
        ..setFlipType(
          _settings.epubScroll
              ? engine.FlipType.scrollVertical
              : engine.FlipType.slideHorizontal,
        );
      final path = await (_repository as PublicationFileRepository)
          .publicationPath(widget.book);
      final publication = await _reader.open(path, _preferences());
      if (!mounted) {
        await _reader.dispose();
        return;
      }
      await _repairNoteSelections(publication);
      if (!mounted) return;
      // An explicit excerpt chapter takes precedence over saved progress.
      _initial = _locator(widget.initialAnchor);
      if (_initial == null && widget.initialChapter == null) {
        _initial = _locator(widget.book.location.anchor);
      }
      // Old character offsets cannot locate an EPUB DOM range; use its chapter.
      if (_initial == null && publication.readingOrder.isNotEmpty) {
        final index = (widget.initialChapter ?? widget.book.location.chapter)
            .clamp(0, publication.readingOrder.length - 1);
        _initial = publication.locatorFromLink(publication.readingOrder[index]);
      }
      _subscriptions.add(
        _reader.positions.listen((locator) {
          if (!_continuousMode && _pendingNativeLocator == null) {
            _onPosition(locator);
          }
        }, onError: _report),
      );
      _subscriptions.add(_reader.errors.listen(_report));
      _subscriptions.add(
        _reader.statuses.listen((status) {
          if (status == rd.ReadiumReaderStatus.ready) {
            _ready = true;
            unawaited(_guard(_decorate));
          } else if (!_continuousMode &&
              status == rd.ReadiumReaderStatus.reachedEndOfPublication) {
            _stopAuto();
          }
        }),
      );
      _lastScrollMode = _continuousMode;
      if (_continuousMode) {
        _continuousContent ??= _repository.openBook(widget.book);
      }
      _config.addListener(_settingsChanged);
      setState(() => _publication = publication);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (error) {
      _report(error);
    } finally {
      _opening = false;
    }
  }

  Future<void> _repairNoteSelections(rd.Publication publication) async {
    EpubContinuousDocument? document;
    for (final kind in [ReaderNoteKind.underline, ReaderNoteKind.comment]) {
      var changed = false;
      for (final row in _rows[kind]!) {
        final original = _locator(ReaderAnchor.fromJson(row['anchor']));
        if (original == null || original.locations?.domRange != null) continue;
        document ??= EpubContinuousDocument(
          await (_continuousContent ??= _repository.openBook(widget.book)),
          publication,
        );
        final chapter = publication.readingOrder.indexWhere(
          (link) => EpubContinuousDocument.samePath(link.href, original.href),
        );
        if (chapter < 0) continue;
        await document.load(chapter);
        final repaired = document.repairSelection(chapter, original);
        if (identical(repaired, original)) continue;
        row['anchor'] = _anchor(repaired).toJson();
        row['chapterIndex'] = chapter;
        changed = true;
      }
      if (changed) await _notes.save(kind, _rows[kind]!);
    }
  }

  rd.Locator? _locator(ReaderAnchor? anchor) =>
      anchor?.type == 'readium' ? rd.Locator.fromJson(anchor!.value) : null;
  ReaderAnchor _anchor(rd.Locator locator) =>
      ReaderAnchor(type: 'readium', value: locator.toJson());
  int get _chapter =>
      (_publication?.readingOrder.indexWhere(
                (link) =>
                    link.href.split('#').first ==
                    _position?.href.split('#').first,
              ) ??
              0)
          .clamp(0, 1000000);
  double get _progress =>
      (_position?.locations?.totalProgression ??
              (_chapter + (_position?.locations?.progression ?? 0)) /
                  (_publication?.readingOrder.length ?? 1))
          .clamp(0, 1);

  rd.EPUBPreferences _preferences() => rd.EPUBPreferences(
    fontSize: _config.fontSize / 20,
    fontFamily: _config.fontFamily,
    backgroundColor: _config.theme.paperColor,
    textColor: _config.theme.textColor,
    lineHeight: _config.lineHeight,
    paragraphSpacing: _config.paragraphSpacing / _config.fontSize,
    scroll: _config.flipType == engine.FlipType.scrollVertical,
    publisherStyles: false,
    columnCount: rd.EpubColumnCount.one,
  );

  void _settingsChanged() {
    if (_lastScrollMode != _continuousMode) {
      _stopAuto();
      _continuous.currentState?.clearSelection();
      _activeSelection = null;
      _acceptSelectionEvents = true;
      _lastScrollMode = _continuousMode;
      _modeGeneration++;
      if (!_continuousMode && _position != null) {
        _pendingNativeLocator = _position;
        unawaited(_guard(_restoreNativePosition));
      } else {
        _pendingNativeLocator = null;
      }
    }
    if (mounted) setState(() {});
    // Update mark colors on the existing page when the reading theme changes.
    if (_ready && !_closing) unawaited(_guard(_decorate));
    _settingsTimer?.cancel();
    _settingsTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_guard(_saveSettings)),
    );
  }

  Future<void> _saveSettings() async {
    final previous = await _repository.loadSettings();
    _settings = ReaderSettings(
      fontSize: _config.fontSize,
      dark: _config.theme.isDark,
      theme: _config.theme.alias,
      flipMode: previous.flipMode,
      epubScroll: _config.flipType == engine.FlipType.scrollVertical,
      lineHeight: _config.lineHeight,
      paragraphSpacing: _config.paragraphSpacing,
      dimLevel: _config.dimLevel,
      fontFamily: _config.fontFamily,
    );
    await _repository.saveSettings(_settings);
    if (_ready && !_closing) await _reader.configure(_preferences());
    if (_ready && !_closing) await _decorate();
  }

  void _onPosition(rd.Locator locator) {
    if (!mounted || _closing) return;
    final changed = _position != locator;
    if (_continuousMode && !_ready) {
      _ready = true;
      unawaited(_guard(_decorate));
    }
    if (_continuousMode && !_menu.value) {
      _position = locator;
    } else {
      setState(() => _position = locator);
    }
    if (!_continuousMode && _autoReading && changed && !_turning) {
      _autoProgress.value = 0;
      _syncAutoMotion();
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _savePosition);
  }

  void _savePosition() {
    final locator = _position;
    if (locator == null) return;
    final location = ReadingLocation(
      chapter: _chapter,
      progress: _progress,
      anchor: _anchor(locator),
    );
    _writes = _writes
        .then((_) async {
          await _repository.saveLocation(widget.book.id, location);
          _positionError = null;
        })
        .catchError((Object e) {
          _positionError = e;
          _report(e);
        });
  }

  Future<void> _flush() async {
    _saveTimer?.cancel();
    _settingsTimer?.cancel();
    _savePosition();
    await _writes;
    if (_positionError != null) throw _positionError!;
    await _notes.pending;
    for (final kind in ReaderNoteKind.values) {
      final error = _notes.errorFor(kind);
      if (error != null) throw error;
    }
    if (_publication != null) await _saveSettings();
  }

  void _menuChanged() {
    if (_menu.value && _activeSelection != null) {
      _menu.value = false;
      unawaited(_guard(_dismissSelection));
      return;
    }
    _autoOverlayChanged();
    if (mounted) setState(() {});
  }

  void _autoOverlayChanged() {
    _autoResumeTimer?.cancel();
    _autoResumePending = false;
    if (_autoReading &&
        !_menu.value &&
        !_settingsPanelOpen &&
        !_autoSheetOpen &&
        _foreground) {
      _autoResumePending = true;
      _autoResumeTimer = Timer(const Duration(milliseconds: 350), () {
        if (!mounted || !_autoReading) return;
        setState(() => _autoResumePending = false);
        _syncAutoMotion();
      });
    }
    _syncAutoMotion();
  }

  void _syncAutoMotion() {
    if (_autoReading &&
        !_autoPaused &&
        !_continuousMode &&
        _nativeReady &&
        !_turning) {
      _autoProgress.duration = _autoInterval;
      if (!_autoProgress.isAnimating) _autoProgress.forward();
    } else {
      _autoProgress.stop();
    }
  }

  void _stopAuto() {
    _autoGeneration++;
    _autoResumeTimer?.cancel();
    _autoReading = false;
    _autoResumePending = false;
    _autoBarCollapsed = false;
    _autoProgress.reset();
    if (mounted) setState(() {});
  }

  void _startAuto() {
    _menu.value = false;
    _autoResumeTimer?.cancel();
    _autoResumePending = false;
    _autoReading = true;
    _autoBarCollapsed = false;
    _autoProgress.reset();
    _syncAutoMotion();
    if (mounted) setState(() {});
  }

  Future<void> _turnAutoPage() async {
    if (!_autoReading ||
        _autoPaused ||
        _continuousMode ||
        _turning ||
        _closing) {
      return;
    }
    final generation = _autoGeneration;
    _turning = true;
    try {
      await _reader.next();
      if (mounted && generation == _autoGeneration && _autoReading) {
        setState(() => _autoBarCollapsed = true);
        _autoProgress.value = 0;
      }
    } catch (error) {
      _stopAuto();
      _report(error);
    } finally {
      _turning = false;
      if (mounted) _syncAutoMotion();
    }
  }

  Future<void> _openAutoReadSettings() async {
    if (_autoSheetOpen || !_autoReading) return;
    final wasReading = _autoReading;
    _autoSheetOpen = true;
    _stopAuto();
    final resume = await engine.showReaderAutoReadSettings(
      context: context,
      theme: _config.theme,
      labels: engine.ReaderLabels.chinese,
      interval: _autoInterval,
      onIntervalChanged: (interval) {
        if (mounted) setState(() => _autoInterval = interval);
      },
    );
    if (!mounted) return;
    _autoSheetOpen = false;
    if (!wasReading || !resume || !_foreground || _closing) return;
    _autoResumeTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted &&
          !_menu.value &&
          !_settingsPanelOpen &&
          _foreground &&
          !_closing) {
        _startAuto();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _stopAuto();
      unawaited(_guard(_flush));
    }
  }

  Future<void> _persist(ReaderNoteKind kind) async {
    await _notes.save(kind, _rows[kind]!);
    final error = _notes.errorFor(kind);
    if (error != null) throw error;
    if (mounted) setState(() {});
    await _decorate();
  }

  Future<void> _add(
    ReaderNoteKind kind,
    rd.Locator locator,
    String quote, {
    String comment = '',
    String? id,
  }) async {
    if (kind != ReaderNoteKind.bookmark &&
        locator.locations?.domRange == null &&
        _publication != null) {
      final document = EpubContinuousDocument(
        await (_continuousContent ??= _repository.openBook(widget.book)),
        _publication!,
      );
      final chapter = document.chapterFor(locator);
      await document.load(chapter);
      locator = document.repairSelection(chapter, locator);
    }
    final now = DateTime.now();
    final noteId = id ?? '${kind.name}:${now.microsecondsSinceEpoch}';
    _rows[kind]!.removeWhere((row) => row['id'] == noteId);
    _rows[kind]!.add({
      'id': noteId,
      'anchor': _anchor(locator).toJson(),
      'createdAt': now.millisecondsSinceEpoch,
      'chapterIndex': _chapter,
      'chapterTitle': locator.title ?? '',
      'text': kind == ReaderNoteKind.comment ? comment : quote,
      'quote': quote,
      'excerpt': quote,
    });
    await _persist(kind);
  }

  Map<String, dynamic>? get _bookmark {
    if (_position == null) return null;
    for (final row
        in _rows[ReaderNoteKind.bookmark] ?? <Map<String, dynamic>>[]) {
      final loc = _locator(ReaderAnchor.fromJson(row['anchor']));
      if (loc?.href == _position!.href &&
          (loc?.locations?.progression ?? -1) ==
              (_position!.locations?.progression ?? -2)) {
        return row;
      }
    }
    return null;
  }

  Future<void> _toggleBookmark() async {
    if (_position == null) return;
    final existing = _bookmark;
    if (existing != null) {
      _rows[ReaderNoteKind.bookmark]!.remove(existing);
      await _persist(ReaderNoteKind.bookmark);
    } else {
      await _add(
        ReaderNoteKind.bookmark,
        _position!,
        _position!.text?.highlight ?? _position!.title ?? '书签',
      );
    }
  }

  Future<void> _decorate() async {
    if (!_ready || _closing) return;
    final decorations = <rd.ReaderDecoration>[];
    final underlineRanges = <String>{};
    for (final kind in [ReaderNoteKind.underline, ReaderNoteKind.comment]) {
      if (kind == ReaderNoteKind.comment && !_config.showSegmentComments) {
        continue;
      }
      for (final row in _rows[kind]!) {
        final locator = _locator(ReaderAnchor.fromJson(row['anchor']));
        if (locator == null) continue;
        if (kind == ReaderNoteKind.underline) {
          final key = jsonEncode(<String, dynamic>{
            'href': locator.href.split('#').first,
            'range':
                locator.locations?.domRange?.toJson() ??
                locator.locations?.partialCfi ??
                locator.toJson(),
          });
          if (!underlineRanges.add(key)) continue;
        }
        decorations.add(
          rd.ReaderDecoration(
            id: row['id'] as String,
            locator: locator,
            style: rd.ReaderDecorationStyle(
              style: kind == ReaderNoteKind.comment
                  ? rd.DecorationStyle.highlight
                  : rd.DecorationStyle.underline,
              tint: kind == ReaderNoteKind.comment
                  ? _config.theme.commentHighlightColor
                  : _config.theme.underlineColor,
            ),
          ),
        );
      }
    }
    if (mounted) setState(() => _decorations = decorations);
    await _reader.decorate(decorations);
  }

  Future<void> _selection(rd.SelectionActionEvent event) async {
    if (!mounted || _closing || _exiting || _selectionBusy) return;
    _selectionBusy = true;
    _acceptSelectionEvents = false;
    var selectionCleared = false;
    _stopAuto();
    if (mounted) {
      setState(() {
        _activeSelection = null;
        _error = null;
      });
    }
    try {
      Map<String, dynamic> result;
      if (_continuousMode) {
        result = _continuous.currentState!.selectionResult(
          event.locator,
          _decorations
              .where((mark) => mark.style.style == rd.DecorationStyle.underline)
              .toList(),
          merge: event.actionId == 'underline',
        );
      } else {
        final channel = _selectionChannel;
        if (channel == null) throw StateError('阅读器尚未准备好');
        final input = {
          'action': event.actionId,
          'selection': event.locator.toJson(),
          'rows': [
            for (final row in _rows[ReaderNoteKind.underline]!)
              if (_locator(ReaderAnchor.fromJson(row['anchor']))
                  case final locator?)
                if (EpubUnderlineRange.sameResource(locator, event.locator))
                  {'id': row['id'], 'locator': locator.toJson()},
          ],
        };
        final raw = await channel
            .evaluateSelectionScript(
              '($epubSelectionScript)(${jsonEncode(input)})',
            )
            .timeout(const Duration(seconds: 5));
        if (raw == null) throw StateError('无法读取选区，请重新选择文字');
        dynamic decoded = jsonDecode(raw);
        if (decoded is String) decoded = jsonDecode(decoded);
        result = Map<String, dynamic>.from(decoded as Map);
      }
      final current = rd.Locator.fromJson(
        result['selection'] as Map<String, dynamic>,
      )!;
      final text = current.text?.highlight ?? '';
      final ids = (result['ids'] as List).cast<String>().toSet();
      if (_continuousMode) {
        _continuous.currentState?.clearSelection();
      } else {
        await _selectionChannel?.clearSelection().timeout(
          const Duration(seconds: 3),
        );
      }
      selectionCleared = true;
      if (!mounted || _closing || _exiting) return;
      switch (event.actionId) {
        case 'copy':
          await Clipboard.setData(ClipboardData(text: text));
        case 'underline':
          final merged = rd.Locator.fromJson(
            result['locator'] as Map<String, dynamic>,
          )!;
          _rows[ReaderNoteKind.underline]!.removeWhere(
            (row) => ids.contains(row['id']),
          );
          await _add(
            ReaderNoteKind.underline,
            merged,
            merged.text?.highlight ?? text,
            id: ids.firstOrNull,
          );
        case 'removeUnderline':
          if (ids.isNotEmpty) {
            _rows[ReaderNoteKind.underline]!.removeWhere(
              (row) => ids.contains(row['id']),
            );
            await _persist(ReaderNoteKind.underline);
          }
          if (mounted) setState(() => _selectedUnderlineIds = const <String>{});
        case 'comment':
          final id = 'comment:${DateTime.now().microsecondsSinceEpoch}';
          await showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => ReaderCommentInput(
              quote: text,
              onSave: (value) => _add(
                ReaderNoteKind.comment,
                current,
                text,
                comment: value,
                id: id,
              ),
            ),
          );
        case 'query':
          if (!await launchUrl(
            Uri.https('www.baidu.com', '/s', {'wd': text}),
            mode: LaunchMode.externalApplication,
          )) {
            throw StateError('无法打开浏览器');
          }
        case 'share':
          await ShareCardSheet.show(
            context,
            bookTitle: widget.book.title,
            author: widget.book.author,
            coverPath: widget.book.coverPath,
            chapterTitle: current.title ?? '',
            quote: text,
            readerTheme: _config.theme,
            textStyle: _config.textStyle,
          );
      }
    } finally {
      if (!selectionCleared) {
        _continuous.currentState?.clearSelection();
        try {
          await _selectionChannel?.clearSelection().timeout(
            const Duration(seconds: 3),
          );
        } catch (error) {
          _report(error);
        }
      }
      _selectionBusy = false;
      if (mounted) {
        setState(() {
          _activeSelection = null;
          _selectedUnderlineIds = const {};
        });
      }
    }
  }

  List<Map<String, dynamic>> _overlappingUnderlineRows(
    rd.Locator selection,
    String selectedText, {
    bool allowTextFallback = true,
  }) {
    bool overlaps(rd.Locator underline) {
      if (EpubUnderlineRange.overlaps(underline, selection)) return true;
      if (!allowTextFallback ||
          !EpubUnderlineRange.sameResource(underline, selection)) {
        return false;
      }
      final aBlock = underline.locations?.additionalProperties['readerBlock'];
      final bBlock = selection.locations?.additionalProperties['readerBlock'];
      if (aBlock is int && bBlock is int && aBlock != bBlock) return false;
      // 跨 DOM 节点时 Readium 不提供可直接比较的全局字符偏移；以同资源内的
      // 引用文字包含关系兜底，覆盖长按单词落在较长划线中的常见场景。
      final underlineText = underline.text?.highlight ?? '';
      return selectedText.isNotEmpty &&
          underlineText.isNotEmpty &&
          (selectedText.contains(underlineText) ||
              underlineText.contains(selectedText));
    }

    return <Map<String, dynamic>>[
      for (final row in _rows[ReaderNoteKind.underline]!)
        if (_locator(ReaderAnchor.fromJson(row['anchor'])) case final locator?)
          if (overlaps(locator)) row,
    ];
  }

  void _textSelected(rd.TextSelectionEvent event) {
    if (!mounted ||
        _closing ||
        _exiting ||
        _selectionBusy ||
        !_acceptSelectionEvents) {
      return;
    }
    _menu.value = false;
    final text = event.selectedText ?? event.locator.text?.highlight ?? '';
    final ids = _continuousMode
        ? ((_continuous.currentState?.selectionResult(
                        event.locator,
                        _decorations
                            .where(
                              (mark) =>
                                  mark.style.style ==
                                  rd.DecorationStyle.underline,
                            )
                            .toList(),
                        merge: false,
                      )['ids']
                      as List?) ??
                  const [])
              .cast<String>()
              .toSet()
        : <String>{
            for (final row in _overlappingUnderlineRows(event.locator, text))
              row['id'] as String,
          };
    if (mounted) {
      setState(() {
        if (_activeSelection == null) _selectionBounds = null;
        _activeSelection = event;
        _selectedUnderlineIds = ids;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_guard(() => _refreshSelectionGeometry(event)));
      });
      if (!_continuousMode) {
        unawaited(_guard(() => _refreshNativeSelectionHits(event)));
      }
    }
  }

  Future<void> _refreshSelectionGeometry(rd.TextSelectionEvent event) async {
    if (!mounted ||
        _exiting ||
        _closing ||
        !identical(_activeSelection, event)) {
      return;
    }
    Rect? bounds;
    if (_continuousMode) {
      bounds = _continuous.currentState?.selectionBounds;
    } else {
      final raw = await _selectionChannel?.evaluateSelectionScript(r"""
        (() => {
          const selection = window.getSelection();
          if (!selection || !selection.rangeCount || selection.isCollapsed) return null;
          const rects = Array.from(selection.getRangeAt(0).getClientRects())
            .filter(r => r.width > 0 && r.height > 0 && r.right > 0 &&
              r.left < innerWidth && r.bottom > 0 && r.top < innerHeight);
          if (!rects.length) return null;
          return JSON.stringify({left: Math.min(...rects.map(r => r.left)),
            right: Math.max(...rects.map(r => r.right)),
            top: Math.min(...rects.map(r => r.top)), bottom: Math.max(...rects.map(r => r.bottom)),
            width: innerWidth, height: innerHeight});
        })()
      """);
      if (!mounted ||
          _exiting ||
          _closing ||
          !identical(_activeSelection, event)) {
        return;
      }
      if (raw != null) {
        dynamic data = jsonDecode(raw);
        if (data is String) data = jsonDecode(data);
        final box = _nativeSurface.currentContext?.findRenderObject();
        if (data is Map &&
            box is RenderBox &&
            box.hasSize &&
            (data['width'] as num) > 0 &&
            (data['height'] as num) > 0) {
          final scaleX = box.size.width / (data['width'] as num);
          final scaleY = box.size.height / (data['height'] as num);
          bounds = Rect.fromPoints(
            box.localToGlobal(
              Offset(
                (data['left'] as num) * scaleX,
                (data['top'] as num) * scaleY,
              ),
            ),
            box.localToGlobal(
              Offset(
                (data['right'] as num) * scaleX,
                (data['bottom'] as num) * scaleY,
              ),
            ),
          );
        }
      }
    }
    if (mounted &&
        identical(_activeSelection, event) &&
        bounds != null &&
        bounds != _selectionBounds) {
      setState(() => _selectionBounds = bounds);
    }
  }

  Widget _positionedSelectionToolbar() {
    final box = _readerSurface.currentContext?.findRenderObject();
    if (box is! RenderBox || _selectionBounds == null) {
      return const SizedBox.shrink();
    }
    final bounds = Rect.fromPoints(
      box.globalToLocal(_selectionBounds!.topLeft),
      box.globalToLocal(_selectionBounds!.bottomRight),
    );
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: EpubSelectionToolbarLayout(
          selection: bounds,
          padding: MediaQuery.paddingOf(context),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: _selectionToolbar(),
        ),
      ),
    );
  }

  Future<void> _refreshNativeSelectionHits(rd.TextSelectionEvent event) async {
    if (!mounted || _exiting || _closing) return;
    final channel = _selectionChannel;
    if (channel == null) return;
    final input = {
      'action': 'inspect',
      'selection': event.locator.toJson(),
      'rows': [
        for (final row in _rows[ReaderNoteKind.underline]!)
          if (_locator(ReaderAnchor.fromJson(row['anchor']))
              case final locator?)
            if (EpubUnderlineRange.sameResource(locator, event.locator))
              {'id': row['id'], 'locator': locator.toJson()},
      ],
    };
    final raw = await channel.evaluateSelectionScript(
      '($epubSelectionScript)(${jsonEncode(input)})',
    );
    if (raw == null ||
        !mounted ||
        _exiting ||
        _closing ||
        _selectionBusy ||
        !identical(_activeSelection, event)) {
      return;
    }
    dynamic result = jsonDecode(raw);
    if (result is String) result = jsonDecode(result);
    setState(
      () => _selectedUnderlineIds = (result['ids'] as List)
          .cast<String>()
          .toSet(),
    );
  }

  Future<void> _dismissSelection() async {
    _acceptSelectionEvents = false;
    if (mounted) {
      setState(() {
        _activeSelection = null;
        _selectionBounds = null;
        _selectedUnderlineIds = const {};
      });
    }
    _continuous.currentState?.clearSelection();
    if (!_continuousMode) {
      await _selectionChannel?.clearSelection().timeout(
        const Duration(seconds: 3),
      );
    }
  }

  Widget _selectionToolbar() {
    final selection = _activeSelection!;
    final hasText =
        (selection.selectedText ?? selection.locator.text?.highlight ?? '')
            .trim()
            .isNotEmpty;
    void action(String id) => unawaited(
      _guard(
        () => _selection(
          rd.SelectionActionEvent(
            actionId: id,
            locator: selection.locator,
            selectedText: selection.selectedText,
          ),
        ),
      ),
    );

    return engine.ReaderSelectionToolbar(
      actions: <engine.ReaderSelectionToolbarAction>[
        engine.ReaderSelectionToolbarAction(
          icon: Icons.content_copy_rounded,
          label: '复制',
          onTap: () => action('copy'),
        ),
        if (hasText)
          engine.ReaderSelectionToolbarAction(
            icon: Icons.border_color_outlined,
            label: '划线',
            onTap: () => action('underline'),
          ),
        if (hasText)
          engine.ReaderSelectionToolbarAction(
            icon: Icons.mode_comment_outlined,
            label: '评论',
            onTap: () => action('comment'),
          ),
        if (_selectedUnderlineIds.isNotEmpty)
          engine.ReaderSelectionToolbarAction(
            icon: Icons.format_color_reset_outlined,
            label: '删除划线',
            onTap: () => action('removeUnderline'),
          ),
        if (hasText)
          engine.ReaderSelectionToolbarAction(
            icon: Icons.search_rounded,
            label: '查询',
            onTap: () => action('query'),
          ),
        if (hasText)
          engine.ReaderSelectionToolbarAction(
            icon: Icons.ios_share_rounded,
            label: '分享',
            onTap: () => action('share'),
          ),
      ],
    );
  }

  Future<void> _catalog({String? selectedId}) async {
    _stopAuto();
    _menu.value = false;
    final publication = _publication!;
    final destinations = <String, rd.Link>{};
    final noteRows = <String, Map<String, dynamic>>{};
    final bookmarkRows = <engine.Bookmark, Map<String, dynamic>>{};
    final underlineRows = <engine.Underline, Map<String, dynamic>>{};
    final commentRows = <engine.Comment, Map<String, dynamic>>{};
    final ordinalByChapter = <int, int>{};

    String positionKey(int chapter, int offset) => '$chapter:$offset';
    int chapterFor(rd.Link link) {
      final href = link.href.split('#').first;
      final index = publication.readingOrder.indexWhere(
        (entry) => entry.href.split('#').first == href,
      );
      return index < 0 ? 0 : index;
    }

    engine.BookTocEntry mapLink(rd.Link link) {
      final chapter = chapterFor(link);
      final offset = ordinalByChapter.update(
        chapter,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      destinations[positionKey(chapter, offset)] = link;
      return engine.BookTocEntry(
        id: link.id ?? link.href,
        title: link.title ?? link.href,
        chapterIndex: chapter,
        charOffset: offset,
        children: link.children.map(mapLink).toList(),
      );
    }

    final tocLinks = publication.tableOfContents.isEmpty
        ? publication.readingOrder
        : publication.tableOfContents;
    final toc = tocLinks.map(mapLink).toList();
    var noteOffset = 1000000;
    for (final kind in ReaderNoteKind.values) {
      for (final row in _rows[kind]!) {
        final chapter = (row['chapterIndex'] as int? ?? 0).clamp(
          0,
          publication.readingOrder.isEmpty
              ? 0
              : publication.readingOrder.length - 1,
        );
        final offset = noteOffset++;
        noteRows[positionKey(chapter, offset)] = row;
        final createdAt = row['createdAt'] as int? ?? 0;
        final chapterTitle = row['chapterTitle'] as String? ?? '';
        final text = (row['text'] ?? row['excerpt'] ?? '') as String;
        switch (kind) {
          case ReaderNoteKind.bookmark:
            final note = engine.Bookmark(
              chapterIndex: chapter,
              charOffset: offset,
              chapterTitle: chapterTitle,
              createdAt: createdAt,
              excerpt: text,
            );
            bookmarkRows[note] = row;
          case ReaderNoteKind.underline:
            final note = engine.Underline(
              chapterIndex: chapter,
              start: offset,
              end: offset + 1,
              text: text,
              chapterTitle: chapterTitle,
              createdAt: createdAt,
            );
            underlineRows[note] = row;
          case ReaderNoteKind.comment:
            final note = engine.Comment(
              chapterIndex: chapter,
              start: offset,
              end: offset + 1,
              quote: row['quote'] as String? ?? '',
              text: text,
              chapterTitle: chapterTitle,
              createdAt: createdAt,
            );
            commentRows[note] = row;
        }
      }
    }

    Future<void> deleteRow(
      ReaderNoteKind kind,
      Map<String, dynamic>? row,
    ) async {
      if (row == null) return;
      _rows[kind]!.remove(row);
      await _guard(() => _persist(kind));
    }

    final picked = await showModalBottomSheet<engine.ReadingPosition>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.92,
        builder: (context, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: ColoredBox(
            color: _config.theme.paperColor,
            child: engine.CatalogSheet(
              bookTitle: widget.book.title,
              author: widget.book.author,
              intro: publication.metadata.description ?? '',
              coverColor: const Color(0xFFA6A6A6),
              chapterTitles: publication.readingOrder
                  .map((link) => link.title ?? link.href)
                  .toList(),
              toc: toc,
              currentIndex: _chapter,
              currentOffset: 0,
              bookmarks: bookmarkRows.keys.toList(),
              underlines: underlineRows.keys.toList(),
              comments: commentRows.keys.toList(),
              onDeleteBookmark: (note) => unawaited(
                deleteRow(ReaderNoteKind.bookmark, bookmarkRows[note]),
              ),
              onDeleteUnderline: (note) => unawaited(
                deleteRow(ReaderNoteKind.underline, underlineRows[note]),
              ),
              onDeleteComment: (note) => unawaited(
                deleteRow(ReaderNoteKind.comment, commentRows[note]),
              ),
              theme: _config.theme,
              scrollController: scrollController,
              initialTabIndex: selectedId == null ? 1 : 2,
            ),
          ),
        ),
      ),
    );
    if (picked == null) return;
    final key = positionKey(picked.chapterIndex, picked.charOffset);
    final link = destinations[key];
    if (link != null) {
      await _goByLink(link, publication);
      return;
    }
    final row = noteRows[key];
    if (row == null) return;
    final locator = _locator(ReaderAnchor.fromJson(row['anchor']));
    if (locator == null) {
      final links = publication.readingOrder;
      if (links.isNotEmpty) {
        final index = (row['chapterIndex'] as int? ?? 0).clamp(
          0,
          links.length - 1,
        );
        await _goByLink(links[index], publication);
      }
    } else {
      await _goTo(locator);
    }
  }

  Future<void> _decorationInteraction(
    rd.DecorationInteractionEvent event,
  ) async {
    Map<String, dynamic>? row;
    for (final candidate in _rows[ReaderNoteKind.comment]!) {
      if (candidate['id'] == event.decorationId) {
        row = candidate;
        break;
      }
    }
    if (row == null) {
      Map<String, dynamic>? underline;
      for (final candidate in _rows[ReaderNoteKind.underline]!) {
        if (candidate['id'] == event.decorationId) {
          underline = candidate;
          break;
        }
      }
      // 划线装饰本身不弹窗。长按时只标记当前划线，让原生文字选区菜单把
      // “划线”替换为“删除划线”；真正删除由选择菜单动作完成。
      if (underline != null &&
          event.type == rd.DecorationInteractionType.longPress &&
          mounted) {
        setState(() {
          _selectedUnderlineIds = <String>{underline!['id'] as String};
        });
      }
      return;
    }
    if (event.type != rd.DecorationInteractionType.tap) return;
    if (_activeSelection != null) {
      await _dismissSelection();
      return;
    }
    await _openParagraphComments([row['id'] as String]);
  }

  Future<void> _openParagraphComments(Iterable<String> ids) async {
    final selectedIds = ids.toSet();
    final rows = _rows[ReaderNoteKind.comment]!
        .where((row) => selectedIds.contains(row['id']))
        .toList();
    if (rows.isEmpty || !mounted) return;
    _stopAuto();
    final commentRows = Map<engine.Comment, Map<String, dynamic>>.identity();
    for (final row in rows) {
      commentRows[engine.Comment(
            chapterIndex: row['chapterIndex'] as int? ?? _chapter,
            start: row['start'] as int? ?? 0,
            end: row['end'] as int? ?? 1,
            quote: row['quote'] as String? ?? '',
            text: row['text'] as String? ?? '',
            chapterTitle: row['chapterTitle'] as String? ?? '',
            createdAt: row['createdAt'] as int? ?? 0,
          )] =
          row;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ReaderParagraphComments(
        comments: commentRows.keys.toList(),
        onDelete: (comment) async {
          final row = commentRows[comment];
          _rows[ReaderNoteKind.comment]!.remove(row);
          await _persist(ReaderNoteKind.comment);
        },
      ),
    );
  }

  Future<void> _seek(double progress) async {
    // Chapter-weighted seek: no assumption that EPUB positions are screen pages.
    final links = _publication!.readingOrder;
    if (links.isEmpty) return;
    final scaled = progress.clamp(0, .999999) * links.length;
    final loc = _publication!.locatorFromLink(links[scaled.floor()]);
    if (loc == null) return;
    final json = loc.toJson();
    json['locations'] = {'progression': scaled - scaled.floor()};
    await _goTo(rd.Locator.fromJson(json)!);
  }

  Future<void> _close() async {
    if (_closing || _exiting) return;
    _exiting = true;
    _stopAuto();
    try {
      // Remove Flutter controls before any asynchronous save/native teardown.
      try {
        await _dismissSelection();
      } catch (_) {
        // A closing native view may already have discarded its selection.
      }
      await _flush();
      if (!mounted) return;
      setState(() => _closing = true);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      _exiting = false;
      _acceptSelectionEvents = true;
      _report(error);
    }
  }

  @override
  void dispose() {
    _closing = true;
    _exiting = true;
    _acceptSelectionEvents = false;
    _activeSelection = null;
    _selectionBounds = null;
    _selectedUnderlineIds = const {};
    _selectionChannel = null;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _settingsTimer?.cancel();
    _autoResumeTimer?.cancel();
    _autoProgress.dispose();
    _savePosition();
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _config.removeListener(_settingsChanged);
    _menu.removeListener(_menuChanged);
    unawaited(_reader.dispose());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _config.dispose();
      _menu.dispose();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final publication = _publication;
    return PopScope(
      canPop: _closing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        appBar: publication == null
            ? AppBar(
                title: Text(widget.book.title),
                leading: BackButton(onPressed: () => unawaited(_close())),
              )
            : null,
        backgroundColor: _config.theme.paperColor,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            if (_activeSelection != null) {
              unawaited(_guard(_dismissSelection));
            }
          },
          child: Stack(
            key: _readerSurface,
            children: [
              if (publication == null)
                const Center(child: CircularProgressIndicator())
              else
                Offstage(
                  offstage: _continuousMode,
                  child: Listener(
                    key: _nativeSurface,
                    onPointerDown: (_) {
                      if (!_selectionBusy) _acceptSelectionEvents = true;
                    },
                    child: rd.ReadiumReaderWidget(
                      publication: publication,
                      initialLocator: _initial,
                      shouldShowControls: _menu,
                      allowedDefaultActions: const {},
                      suppressNativeSelectionMenu: true,
                      selectionHandleColor: _config.theme.accentColor,
                      initialPreferences: _preferences(),
                      goBackwardSemanticLabel: '上一页',
                      goForwardSemanticLabel: '下一页',
                      toggleShowControlsSemanticLabel: '阅读菜单',
                      selectionActions: const [
                        rd.SelectionAction(id: 'copy', title: '复制'),
                        rd.SelectionAction(id: 'underline', title: '划线'),
                        rd.SelectionAction(id: 'comment', title: '评论'),
                        rd.SelectionAction(
                          id: 'removeUnderline',
                          title: '删除划线',
                        ),
                        rd.SelectionAction(id: 'query', title: '查询'),
                        rd.SelectionAction(id: 'share', title: '分享'),
                      ],
                      onTextSelected: _textSelected,
                      onReaderChannelReady: (channel) =>
                          _selectionChannel = channel,
                      onReaderReady: () {
                        _nativeReady = true;
                        _syncAutoMotion();
                        unawaited(
                          _guard(() async {
                            await _restoreNativePosition();
                            if (_ready && !_closing) await _decorate();
                          }),
                        );
                      },
                      onSelectionAction: (event) =>
                          unawaited(_guard(() => _selection(event))),
                      onDecorationInteraction: (event) => unawaited(
                        _guard(() => _decorationInteraction(event)),
                      ),
                    ),
                  ),
                ),
              if (publication != null && _continuousMode)
                EpubContinuousView(
                  key: _continuous,
                  content: _continuousContent ??= _repository.openBook(
                    widget.book,
                  ),
                  publication: publication,
                  config: _config,
                  initialLocator: _position ?? _initial,
                  decorations: _decorations,
                  autoReading: _autoReading,
                  autoPaused: _autoPaused,
                  autoInterval: _autoInterval,
                  onPosition: _onPosition,
                  onSelection: (event) {
                    _acceptSelectionEvents = true;
                    _textSelected(event);
                  },
                  onSelectionGeometryChanged: () {
                    final event = _activeSelection;
                    if (event != null) {
                      unawaited(_guard(() => _refreshSelectionGeometry(event)));
                    }
                  },
                  onSelectionCleared: () {
                    if (mounted &&
                        (_activeSelection != null ||
                            _selectedUnderlineIds.isNotEmpty)) {
                      setState(() {
                        _activeSelection = null;
                        _selectedUnderlineIds = const {};
                      });
                    }
                  },
                  onTap: () {
                    if (_activeSelection != null) {
                      _continuous.currentState?.clearSelection();
                      setState(() => _activeSelection = null);
                    } else {
                      _menu.value = !_menu.value;
                    }
                  },
                  onError: _report,
                  onEnd: _stopAuto,
                  onDecorationTap: (marks) => unawaited(
                    _guard(() async {
                      if (_activeSelection != null) {
                        await _dismissSelection();
                      } else {
                        await _openParagraphComments(
                          marks.map((mark) => mark.id),
                        );
                      }
                    }),
                  ),
                ),
              if (_activeSelection != null) _positionedSelectionToolbar(),
              if (_config.dimLevel > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: _config.dimLevel),
                    ),
                  ),
                ),
              if (publication != null)
                engine.ReaderMenu(
                  visible: _menu.value && _activeSelection == null,
                  bookTitle: widget.book.title,
                  chapterTitle: _position?.title ?? '',
                  chapterIndex: _chapter,
                  chapterCount: publication.readingOrder.length,
                  progress: _progress,
                  config: _config,
                  bookmarked: _bookmark != null,
                  supportedFlipTypes: const [
                    engine.FlipType.scrollVertical,
                    engine.FlipType.slideHorizontal,
                  ],
                  onToggleBookmark: () => unawaited(_guard(_toggleBookmark)),
                  onBack: () => unawaited(_close()),
                  onOpenCatalog: () => unawaited(_guard(_catalog)),
                  onPrevChapter: () => unawaited(
                    _guard(() async {
                      if (_chapter > 0) {
                        await _goByLink(
                          publication.readingOrder[_chapter - 1],
                          publication,
                        );
                      }
                    }),
                  ),
                  onNextChapter: () => unawaited(
                    _guard(() async {
                      if (_chapter + 1 < publication.readingOrder.length) {
                        await _goByLink(
                          publication.readingOrder[_chapter + 1],
                          publication,
                        );
                      }
                    }),
                  ),
                  onSeekProgress: (value) =>
                      unawaited(_guard(() => _seek(value))),
                  seekPreview: (value) => engine.ReaderSeekPreview(
                    page: (value * publication.readingOrder.length).floor() + 1,
                    totalPages: publication.readingOrder.length,
                    title: '按章节跳转',
                  ),
                  onRequestClose: () => _menu.value = false,
                  onStartAutoTurn: _startAuto,
                  onStopAutoTurn: _stopAuto,
                  autoTurning: _autoReading,
                  onSettingsPanelChanged: (open) {
                    setState(() => _settingsPanelOpen = open);
                    _autoOverlayChanged();
                  },
                ),
              if (_autoReading &&
                  !_continuousMode &&
                  MediaQuery.orientationOf(context) == Orientation.portrait)
                Positioned.fill(
                  child: engine.AutoTurnProgressBar(
                    progress: _autoProgress,
                    theme: _config.theme,
                  ),
                ),
              if (_autoReading && !_menu.value && _activeSelection == null)
                Positioned(
                  bottom: 27 + MediaQuery.paddingOf(context).bottom,
                  left: 0,
                  right: 0,
                  child: engine.ReaderAutoReadBar(
                    theme: _config.theme,
                    labels: engine.ReaderLabels.chinese,
                    collapsed: _autoBarCollapsed,
                    onExpand: () => setState(() => _autoBarCollapsed = false),
                    onSettings: _openAutoReadSettings,
                  ),
                ),
              if (_error != null)
                SafeArea(
                  child: Material(
                    child: ListTile(
                      title: Text(_error!),
                      trailing: TextButton(
                        onPressed: () => unawaited(
                          _guard(() async {
                            if (_publication == null) {
                              await _open();
                              return;
                            }
                            await _notes.retry();
                            if (_continuousMode) {
                              setState(
                                () => _continuousContent = _repository.openBook(
                                  widget.book,
                                ),
                              );
                              await _continuous.currentState?.retry();
                            }
                            await _flush();
                            await _decorate();
                            if (mounted) setState(() => _error = null);
                          }),
                        ),
                        child: const Text('重试'),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

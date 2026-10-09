import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'parser.dart';
import 'providers.dart';
import 'repository.dart';
import 'theme/reader_palette.dart';

enum _ShelfSection { shelf, excerpts }

enum _ExcerptSort { newest, oldest, random }

class BookshelfView extends ConsumerStatefulWidget {
  const BookshelfView({super.key, required this.onBookTap, this.onReaderOpen});

  final ValueChanged<Book> onBookTap;
  final ValueChanged<ReaderOpenRequest>? onReaderOpen;

  @override
  ConsumerState<BookshelfView> createState() => _BookshelfViewState();
}

class _BookshelfViewState extends ConsumerState<BookshelfView> {
  bool _busy = false;
  bool _searching = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  String _shelfQuery = '';
  String _excerptQuery = '';
  String? _selectedTag;
  String? _selectedBookId;
  _ShelfSection _section = _ShelfSection.shelf;
  _ExcerptSort _excerptSort = _ExcerptSort.newest;
  Future<List<ExcerptItem>>? _excerpts;
  StreamSubscription<List<ExcerptItem>>? _excerptSubscription;
  int _randomSeed = DateTime.now().millisecondsSinceEpoch;
  int _excerptVisibleCount = 50;

  @override
  void initState() {
    super.initState();
    _startExcerptWatch();
    _importBundledBooks();
  }

  @override
  void dispose() {
    _excerptSubscription?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _importBundledBooks() async {
    try {
      final catalog = await _loadCatalog();
      if (catalog != null) {
        for (final entry in catalog) {
          final data = await rootBundle.load(entry.assetPath);
          final result = await ref
              .read(bookshelfRepositoryProvider)
              .importBytesWithResult(
                data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
                entry.fileName,
                source: BookSource.builtIn,
              );
          await ref
              .read(bookshelfRepositoryProvider)
              .syncCatalogTags(result.book.id, entry.tags);
        }
        return;
      }
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final path in manifest.listAssets().where((path) {
        final lower = path.toLowerCase();
        return (lower.startsWith('assets/books/') ||
                lower.startsWith('packages/reader/assets/books/')) &&
            (lower.endsWith('.epub') || lower.endsWith('.txt'));
      })) {
        final data = await rootBundle.load(path);
        await ref
            .read(bookshelfRepositoryProvider)
            .importBytes(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
              path.split('/').last,
              source: BookSource.builtIn,
            );
      }
    } catch (_) {
      // Bundled books are optional.
    }
  }

  Future<List<_CatalogBook>?> _loadCatalog() async {
    try {
      final root =
          jsonDecode(await rootBundle.loadString('assets/catalog.json'))
              as Map<String, dynamic>;
      final colors = (root['tags'] as Map<String, dynamic>? ?? {}).map(
        (name, value) =>
            MapEntry(name, (value as Map<String, dynamic>)['color'] as String?),
      );
      return (root['books'] as List<dynamic>).map((value) {
        final item = value as Map<String, dynamic>;
        final file = item['file'] as String;
        final names = (item['tags'] as List<dynamic>? ?? const [])
            .cast<String>();
        return _CatalogBook(
          assetPath: 'assets/books/$file',
          fileName: file,
          tags: {for (final name in names) name: colors[name]},
        );
      }).toList();
    } catch (_) {
      return null;
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: ReaderPalette.ink,
        content: Text(message, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final files = await openFiles(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'UTF-8 TXT',
            extensions: ['txt'],
            uniformTypeIdentifiers: ['public.plain-text'],
          ),
        ],
      );
      final messages = <String>[];
      for (final file in files) {
        try {
          if (!file.name.toLowerCase().endsWith('.txt')) {
            throw const FormatException('本地导入仅支持 UTF-8 TXT 文件');
          }
          if (await file.length() > LocalBookParser.maxFileBytes) {
            throw const FormatException('超过 50 MB');
          }
          final result = await ref
              .read(bookshelfRepositoryProvider)
              .importBytesWithResult(await file.readAsBytes(), file.name);
          messages.add(
            result.isDuplicate
                ? '《${result.book.title}》已在书架中，已保留原有阅读进度'
                : '已添加《${result.book.title}》',
          );
        } catch (error) {
          messages.add('${file.name}：${readerError(error)}');
        }
      }
      if (files.isNotEmpty) _message(messages.join('\n'));
    } catch (error) {
      _message('无法导入：${readerError(error)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmRemove(Book book) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => Theme(
          data: _readerTheme(dialogContext),
          child: AlertDialog(
            title: const Text('从书架移除？'),
            content: Text('将移除《${book.title}》的书籍副本、阅读进度、书签、划线和评论。原始文件不受影响。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('移除'),
              ),
            ],
          ),
        ),
      ) ==
      true;

  Future<void> _remove(Book book) async {
    try {
      await ref.read(bookshelfRepositoryProvider).removeBook(book.id);
    } catch (error) {
      _message('移除失败：${readerError(error)}');
      return;
    }
    // Refreshing the secondary excerpt view is not part of the persistence
    // result and must never turn a completed removal into a failure message.
    _reloadExcerpts();
  }

  Future<List<ExcerptItem>> _loadExcerpts() async {
    final repository = ref.read(bookshelfRepositoryProvider);
    if (repository is BookshelfInsightsRepository) {
      return (repository as BookshelfInsightsRepository).loadExcerpts();
    }
    final books = await repository.watchBooks().first;
    final result = <ExcerptItem>[];
    for (final book in books) {
      for (final kind in [ReaderNoteKind.underline, ReaderNoteKind.comment]) {
        for (final note in await repository.loadNotes(book.id, kind)) {
          final text = note['text'] as String? ?? '';
          final quote = kind == ReaderNoteKind.comment
              ? note['quote'] as String? ?? ''
              : text;
          if (text.isEmpty && quote.isEmpty) continue;
          final key =
              '${note['chapterIndex']}:${note['start']}:${note['end']}'
              '${kind == ReaderNoteKind.comment ? ':${note['createdAt']}' : ''}';
          result.add(
            ExcerptItem(
              ref: ReaderNoteRef(bookId: book.id, kind: kind, noteKey: key),
              book: book,
              chapterIndex: note['chapterIndex'] as int? ?? 0,
              startOffset: note['start'] as int? ?? 0,
              chapterTitle: note['chapterTitle'] as String? ?? '',
              createdAt: note['createdAt'] as int? ?? 0,
              quote: quote,
              comment: kind == ReaderNoteKind.comment ? text : '',
            ),
          );
        }
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  void _reloadExcerpts() {
    if (!mounted) return;
    final future = _loadExcerpts();
    setState(() {
      _excerpts = future;
    });
    future.then(_acceptExcerpts, onError: _rejectExcerpts);
  }

  void _openSearch() {
    setState(() => _searching = true);
    // Attach the input before requesting focus so mobile text input opens
    // reliably when the navigation changes into the search field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searching) _searchFocus.requestFocus();
    });
  }

  void _cancelSearch() {
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() {
      _searching = false;
      _shelfQuery = '';
      _excerptQuery = '';
      _excerptVisibleCount = 50;
    });
  }

  void _search(String value) {
    setState(() {
      final query = value.trim().toLowerCase();
      if (_section == _ShelfSection.shelf) {
        _shelfQuery = query;
      } else {
        _excerptQuery = query;
        _excerptVisibleCount = 50;
      }
    });
  }

  void _selectSection(_ShelfSection value) {
    if (_section == value) return;
    setState(() => _section = value);
  }

  void _acceptExcerpts(List<ExcerptItem> items) {
    if (!mounted) return;
    setState(() {
      _excerpts = Future.value(items);
    });
  }

  void _rejectExcerpts(Object error, StackTrace stack) {
    if (!mounted) return;
    setState(() {
      _excerpts = Future.value(const <ExcerptItem>[]);
    });
  }

  void _startExcerptWatch() {
    _excerptSubscription?.cancel();
    final repository = ref.read(bookshelfRepositoryProvider);
    final initial = _loadExcerpts();
    _excerpts = initial;
    initial.then(_acceptExcerpts, onError: _rejectExcerpts);
    if (repository is BookshelfInsightsRepository) {
      _excerptSubscription = (repository as BookshelfInsightsRepository)
          .watchExcerpts()
          .listen(_acceptExcerpts, onError: _rejectExcerpts);
    }
  }

  void _openExcerpt(ExcerptItem item) {
    final request = ReaderOpenRequest(
      book: item.book,
      chapterIndex: item.chapterIndex,
      charOffset: item.startOffset,
    );
    if (widget.onReaderOpen != null) {
      widget.onReaderOpen!(request);
    } else {
      widget.onBookTap(item.book);
    }
  }

  Future<void> _deleteExcerpt(ExcerptItem item) async {
    final label = item.isComment ? '评论' : '划线';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final dark = theme.brightness == Brightness.dark;
        final surface = dark ? const Color(0xFF25262A) : Colors.white;
        return AlertDialog(
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
          elevation: 14,
          shadowColor: Colors.black.withValues(alpha: dark ? .5 : .2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text('删除$label？', textAlign: TextAlign.center),
          content: Text(
            '删除后将无法恢复这条$label。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: .68),
              height: 1.45,
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: ReaderPalette.accent,
                foregroundColor: Colors.white,
                elevation: 0,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    try {
      final repository = ref.read(bookshelfRepositoryProvider);
      if (repository is BookshelfInsightsRepository) {
        await (repository as BookshelfInsightsRepository).deleteReaderNote(
          item.ref,
        );
      } else {
        final rows = await repository.loadNotes(item.ref.bookId, item.ref.kind);
        rows.removeWhere((note) {
          final key =
              '${note['chapterIndex']}:${note['start']}:${note['end']}'
              '${item.ref.kind == ReaderNoteKind.comment ? ':${note['createdAt']}' : ''}';
          return key == item.ref.noteKey;
        });
        await repository.saveNotes(item.ref.bookId, item.ref.kind, rows);
      }
      _reloadExcerpts();
    } catch (error) {
      _message('删除失败：${readerError(error)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final readerTheme = _readerTheme(context);
    return Theme(
      data: readerTheme,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: readerTheme.brightness == Brightness.dark
            ? ReaderPalette.nightBackground
            : ReaderPalette.libraryBackground,
        body: SafeArea(
          child: _section == _ShelfSection.shelf
              ? _buildShelf()
              : _buildExcerptFeed(),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: _ShelfExcerptSwitcher(
          section: _section,
          onChanged: _selectSection,
          searching: _searching,
          controller: _searchController,
          focusNode: _searchFocus,
          onSearch: _openSearch,
          onCancel: _cancelSearch,
          onQueryChanged: _search,
        ),
      ),
    );
  }

  Widget _buildShelf() {
    final entries = ref.watch(shelfEntriesProvider);
    return Column(
      children: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Text('正在导入图书…'),
              ],
            ),
          ),
        if (entries.hasValue)
          _TagFilterBar(
            tags: {
              for (final entry in entries.value!)
                for (final tag in entry.book.tags) tag.name: tag,
            }.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
            selected: _selectedTag,
            onSelected: (tag) => setState(() => _selectedTag = tag),
          ),
        Expanded(
          child: entries.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _ErrorState(
              message: '书架加载失败：${readerError(error)}',
              onRetry: () => ref.invalidate(shelfEntriesProvider),
            ),
            data: (all) {
              final visible = all.where((entry) {
                final book = entry.book;
                return '${book.title} ${book.author}'.toLowerCase().contains(
                      _shelfQuery,
                    ) &&
                    (_selectedTag == null ||
                        book.tags.any((tag) => tag.name == _selectedTag));
              }).toList();
              if (visible.isEmpty) {
                return _ShelfEmpty(
                  allEmpty: all.isEmpty,
                  busy: _busy,
                  onImport: _import,
                );
              }
              return _buildGrid(visible);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGrid(List<ShelfEntry> entries) => ScrollConfiguration(
    behavior: const _NoOverscrollBehavior(),
    child: ListView.builder(
      key: const PageStorageKey('shelf-grid'),
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 104),
      physics: const ClampingScrollPhysics(),
      itemCount: (entries.length / 3).ceil(),
      itemBuilder: (context, rowIndex) {
        final start = rowIndex * 3;
        return _ShelfRow(
          children: [
            for (var column = 0; column < 3; column++)
              if (start + column < entries.length)
                _GridBookCard(
                  key: ValueKey(entries[start + column].book.id),
                  entry: entries[start + column],
                  onTap: () => widget.onBookTap(entries[start + column].book),
                  onLongPress: () async {
                    final book = entries[start + column].book;
                    if (await _confirmRemove(book)) await _remove(book);
                  },
                )
              else
                const SizedBox.shrink(),
          ],
        );
      },
    ),
  );

  Widget _buildExcerptFeed() {
    return Column(
      children: [
        FutureBuilder<List<ExcerptItem>>(
          future: _excerpts,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox.shrink();
            final books = {
              for (final item in snapshot.data!) item.book.id: item.book,
            }.values.toList();
            return _ExcerptFilters(
              books: books,
              selectedBookId: _selectedBookId,
              sort: _excerptSort,
              onBookChanged: (value) => setState(() {
                _selectedBookId = value;
                _excerptVisibleCount = 50;
              }),
              onSortChanged: (value) {
                setState(() {
                  _excerptSort = value;
                  _excerptVisibleCount = 50;
                  if (value == _ExcerptSort.random) {
                    _randomSeed = DateTime.now().millisecondsSinceEpoch;
                  }
                });
              },
            );
          },
        ),
        Expanded(
          child: FutureBuilder<List<ExcerptItem>>(
            future: _excerpts,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _ErrorState(
                  message: '摘录加载失败：${readerError(snapshot.error!)}',
                  onRetry: _reloadExcerpts,
                );
              }
              var items = snapshot.data!.where((item) {
                if (_selectedBookId != null &&
                    item.book.id != _selectedBookId) {
                  return false;
                }
                final searchable =
                    '${item.quote} ${item.comment} '
                            '${item.book.title} ${item.book.author} ${item.chapterTitle}'
                        .toLowerCase();
                return searchable.contains(_excerptQuery);
              }).toList();
              if (_excerptSort == _ExcerptSort.oldest) {
                items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
              } else if (_excerptSort == _ExcerptSort.random) {
                items = List.of(items)..shuffle(Random(_randomSeed));
              } else {
                items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
              }
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      snapshot.data!.isEmpty
                          ? '读到喜欢的句子时，可以添加划线或写下想法，它们会出现在这里。'
                          : '没有找到相关摘录。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              final visibleCount = min(_excerptVisibleCount, items.length);
              return NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.metrics.extentAfter < 400 &&
                      visibleCount < items.length) {
                    setState(() {
                      _excerptVisibleCount = min(
                        items.length,
                        _excerptVisibleCount + 50,
                      );
                    });
                  }
                  return false;
                },
                child: ScrollConfiguration(
                  behavior: const _NoOverscrollBehavior(),
                  child: ListView.separated(
                    key: const PageStorageKey('excerpt-feed'),
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 108),
                    physics: const ClampingScrollPhysics(),
                    itemCount: visibleCount,
                    separatorBuilder: (_, _) => const SizedBox(height: 16),
                    itemBuilder: (context, index) => _ExcerptCard(
                      item: items[index],
                      onTap: () => _openExcerpt(items[index]),
                      onDelete: () => _deleteExcerpt(items[index]),
                      onCopy: () async {
                        final item = items[index];
                        final text = item.isComment
                            ? [
                                item.quote,
                                item.comment,
                              ].where((value) => value.isNotEmpty).join('\n\n')
                            : item.quote;
                        await Clipboard.setData(ClipboardData(text: text));
                        _message('已复制');
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  ThemeData _readerTheme(BuildContext context) {
    final hostTheme = Theme.of(context);
    final palette = hostTheme.brightness == Brightness.dark
        ? ReaderPalette.darkTheme()
        : ReaderPalette.lightTheme();
    final fontFamily = hostTheme.textTheme.bodyMedium?.fontFamily;
    return palette.copyWith(
      textTheme: palette.textTheme.apply(fontFamily: fontFamily),
      primaryTextTheme: palette.primaryTextTheme.apply(fontFamily: fontFamily),
    );
  }
}

class _NoOverscrollBehavior extends MaterialScrollBehavior {
  const _NoOverscrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

class _GridBookCard extends StatelessWidget {
  const _GridBookCard({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  final ShelfEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final book = entry.book;
    return Semantics(
      button: true,
      label:
          '《${book.title}》，已读 ${(book.location.progress * 100).round()}%'
          '${entry.markers.isEmpty ? '' : '，有阅读便签'}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: onLongPress,
          child: _GridCover(book: book, markers: entry.markers),
        ),
      ),
    );
  }
}

class _ShelfRow extends StatelessWidget {
  const _ShelfRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
    child: SizedBox(
      height: 162,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            Expanded(child: children[i]),
            if (i != children.length - 1) const SizedBox(width: 12),
          ],
        ],
      ),
    ),
  );
}

class _GridCover extends StatelessWidget {
  const _GridCover({required this.book, required this.markers});

  final Book book;
  final List<ShelfNoteMarker> markers;

  static const _colors = [
    Color(0xFFF4D35E),
    Color(0xFFF29CA3),
    Color(0xFF83C5E5),
    Color(0xFF8ED1A5),
    Color(0xFFF2A65A),
    Color(0xFFB8A1E3),
  ];

  int _stableIndex(ShelfNoteMarker marker) {
    var value = 2166136261;
    for (final unit
        in '${book.id}:${marker.kind.name}:${marker.noteKey}'.codeUnits) {
      value = (value ^ unit) * 16777619 & 0x7fffffff;
    }
    return value % _colors.length;
  }

  int _bookHash() {
    var value = 2166136261;
    for (final unit in book.id.codeUnits) {
      value = (value ^ unit) * 16777619 & 0x7fffffff;
    }
    return value;
  }

  Color _fallbackColor() {
    const colors = [
      Color(0xFF506B72),
      Color(0xFF8B5E58),
      Color(0xFF6B668E),
      Color(0xFF57715D),
      Color(0xFF94714F),
      Color(0xFF526783),
    ];
    return colors[_bookHash() % colors.length];
  }

  Widget _frontCover(File? file, bool hasCover) {
    final base = _fallbackColor();
    final hsl = HSLColor.fromColor(base);
    final light = hsl
        .withLightness((hsl.lightness + .08).clamp(0.0, 1.0))
        .toColor();
    final dark = hsl
        .withLightness((hsl.lightness - .12).clamp(0.0, 1.0))
        .toColor();
    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasCover)
          Image.file(
            file!,
            fit: BoxFit.cover,
            cacheWidth: 360,
            filterQuality: FilterQuality.high,
            isAntiAlias: true,
            errorBuilder: (_, _, _) =>
                _FallbackCover(book: book, light: light, dark: dark),
          )
        else
          _FallbackCover(book: book, light: light, dark: dark),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 9,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.black.withValues(alpha: .34),
                  Colors.black.withValues(alpha: .06),
                  Colors.white.withValues(alpha: .10),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 1.2,
          child: ColoredBox(color: Colors.black.withValues(alpha: .18)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final file = book.coverPath == null ? null : File(book.coverPath!);
    final hasCover = file != null && file.existsSync();
    return ExcludeSemantics(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final pageDepth = (width * .16).clamp(15.0, 20.0);
            final coverRight = pageDepth - 1;
            const tabPositions = [.12, .38, .57, .81];
            const tabOffsets = [1.0, 4.0, 2.0, 3.0];
            const tabSize = 11.0;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 5,
                  right: 1,
                  bottom: 1,
                  height: 9,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(50),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x2A000000),
                          blurRadius: 11,
                          spreadRadius: -.5,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 2,
                  width: pageDepth + 20,
                  child: Image.asset(
                    'asset/book_cover.png',
                    package: 'reader',
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    cacheHeight: 480,
                    filterQuality: FilterQuality.high,
                    isAntiAlias: true,
                  ),
                ),

                for (var i = 0; i < markers.length && i < 4; i++)
                  Positioned(
                    top: height * tabPositions[i],
                    right: tabOffsets[i],
                    child: Container(
                      width: tabSize,
                      height: tabSize,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Color.lerp(
                              _colors[_stableIndex(markers[i])],
                              Colors.black,
                              .13,
                            )!,
                            _colors[_stableIndex(markers[i])],
                            Color.lerp(
                              _colors[_stableIndex(markers[i])],
                              Colors.white,
                              .16,
                            )!,
                          ],
                          stops: const [0, .32, 1],
                        ),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(.8),
                          bottomLeft: Radius.circular(.8),
                          topRight: Radius.circular(2.5),
                          bottomRight: Radius.circular(2.5),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x30000000),
                            blurRadius: 2,
                            offset: Offset(0, 1.5),
                          ),
                        ],
                      ),
                    ),
                  ),
                Positioned(
                  left: 1,
                  top: 3,
                  right: coverRight,
                  bottom: 5,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    clipBehavior: Clip.antiAliasWithSaveLayer,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _frontCover(file, hasCover),
                        if (book.location.progress > 0)
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .52),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                child: Text(
                                  '${(book.location.progress.clamp(0.0, 1.0) * 100).toStringAsFixed(1)}%',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 8.5,
                                    height: 1,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FallbackCover extends StatelessWidget {
  const _FallbackCover({
    required this.book,
    required this.light,
    required this.dark,
  });

  final Book book;
  final Color light;
  final Color dark;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: const Alignment(-.7, -1),
        end: const Alignment(.8, 1),
        colors: [light, dark],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white.withValues(alpha: .22)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                book.title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: book.title.length > 12 ? 11 : 13,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                  shadows: const [
                    Shadow(color: Color(0x66000000), blurRadius: 3),
                  ],
                ),
              ),
              if (book.author.trim().isNotEmpty) ...[
                const SizedBox(height: 9),
                Container(width: 18, height: 1, color: Colors.white54),
                const SizedBox(height: 7),
                Text(
                  book.author,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 8.5,
                    height: 1.25,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _ExcerptCard extends StatelessWidget {
  const _ExcerptCard({
    required this.item,
    required this.onTap,
    required this.onCopy,
    required this.onDelete,
  });

  final ExcerptItem item;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  String _date(int milliseconds) {
    if (milliseconds <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    final cover = item.book.coverPath == null
        ? null
        : File(item.book.coverPath!);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF25262A) : Colors.white;
    final accent = dark
        ? ReaderPalette.nightSubheading
        : ReaderPalette.inkSecondary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .3 : .12),
            blurRadius: 16,
            spreadRadius: -2,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .18 : .045),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.isComment && item.quote.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(11, 9, 8, 9),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: dark ? .07 : .04),
                      border: Border(
                        left: BorderSide(
                          color: accent.withValues(alpha: dark ? .34 : .24),
                          width: 2.5,
                        ),
                      ),
                    ),
                    child: _ExpandableExcerptText(
                      item.quote,
                      collapsedLines: 4,
                      style: TextStyle(
                        height: 1.5,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: .72),
                      ),
                    ),
                  ),
                  if (item.comment.isNotEmpty) const SizedBox(height: 14),
                ],
                if (!item.isComment || item.comment.isNotEmpty)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 9),
                        child: Icon(
                          item.isComment
                              ? Icons.chat_bubble_outline_rounded
                              : Icons.format_quote_rounded,
                          size: 20,
                          color: accent,
                        ),
                      ),
                      Expanded(
                        child: _ExpandableExcerptText(
                          item.isComment ? item.comment : item.quote,
                          collapsedLines: 8,
                          style: const TextStyle(fontSize: 16, height: 1.55),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 16),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: scheme.onSurface.withValues(alpha: dark ? .12 : .07),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Row(
                    children: [
                      if (cover != null && cover.existsSync()) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.file(
                            cover,
                            width: 28,
                            height: 38,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                        const SizedBox(width: 9),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.book.author.isEmpty
                                  ? item.book.title
                                  : '${item.book.title} · ${item.book.author}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                item.chapterTitle,
                                _date(item.createdAt),
                              ].where((value) => value.isNotEmpty).join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.onSurface.withValues(alpha: .56),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多操作',
                        padding: EdgeInsets.zero,
                        position: PopupMenuPosition.under,
                        offset: const Offset(0, 6),
                        color: surface,
                        surfaceTintColor: Colors.transparent,
                        shadowColor: Colors.black.withValues(
                          alpha: dark ? .5 : .2,
                        ),
                        elevation: 10,
                        constraints: const BoxConstraints(
                          minWidth: 148,
                          maxWidth: 180,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        icon: Icon(
                          Icons.more_horiz,
                          size: 21,
                          color: scheme.onSurface.withValues(alpha: .62),
                        ),
                        onSelected: (value) =>
                            value == 'copy' ? onCopy() : onDelete(),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'copy',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.content_copy_rounded, size: 19),
                                SizedBox(width: 12),
                                Text('复制'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.delete_outline_rounded,
                                  size: 20,
                                  color: ReaderPalette.inkSecondary,
                                ),
                                SizedBox(width: 12),
                                Text(
                                  '删除',
                                  style: TextStyle(
                                    color: ReaderPalette.inkSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpandableExcerptText extends StatefulWidget {
  const _ExpandableExcerptText(
    this.text, {
    required this.collapsedLines,
    required this.style,
  });

  final String text;
  final int collapsedLines;
  final TextStyle style;

  @override
  State<_ExpandableExcerptText> createState() => _ExpandableExcerptTextState();
}

class _ExpandableExcerptTextState extends State<_ExpandableExcerptText> {
  bool _expanded = false;

  static const _iconExtent = 22.0;

  TextSpan _span(String text, {required bool expanded}) => TextSpan(
    style: widget.style,
    children: [
      TextSpan(text: text),
      const TextSpan(text: ' '),
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Tooltip(
          message: expanded ? '收起' : '展开',
          child: InkResponse(
            radius: 14,
            onTap: () => setState(() => _expanded = !_expanded),
            child: SizedBox.square(
              dimension: _iconExtent,
              child: Icon(
                expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 19,
              ),
            ),
          ),
        ),
      ),
    ],
  );

  bool _fits(String text, double maxWidth, TextDirection direction) {
    final painter =
        TextPainter(
          text: TextSpan(
            style: widget.style,
            children: [
              TextSpan(text: text),
              const TextSpan(text: ' '),
              const WidgetSpan(child: SizedBox.square(dimension: _iconExtent)),
            ],
          ),
          textDirection: direction,
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: widget.collapsedLines,
        )..setPlaceholderDimensions(const [
          PlaceholderDimensions(
            size: Size.square(_iconExtent),
            alignment: PlaceholderAlignment.middle,
          ),
        ]);
    painter.layout(maxWidth: maxWidth);
    return !painter.didExceedMaxLines;
  }

  String _collapsedText(double maxWidth, TextDirection direction) {
    final codePoints = widget.text.runes.toList();
    var low = 0;
    var high = codePoints.length;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      final candidate = '${String.fromCharCodes(codePoints.take(middle))}…';
      if (_fits(candidate, maxWidth, direction)) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return '${String.fromCharCodes(codePoints.take(low)).trimRight()}…';
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final direction = Directionality.of(context);
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textDirection: direction,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: widget.collapsedLines,
      )..layout(maxWidth: constraints.maxWidth);
      final expandable = painter.didExceedMaxLines;
      if (!expandable) {
        return Text(widget.text, style: widget.style);
      }
      final text = _expanded
          ? widget.text
          : _collapsedText(constraints.maxWidth, direction);
      return Text.rich(
        _span(text, expanded: _expanded),
        maxLines: _expanded ? null : widget.collapsedLines,
      );
    },
  );
}

class _ExcerptFilters extends StatelessWidget {
  const _ExcerptFilters({
    required this.books,
    required this.selectedBookId,
    required this.sort,
    required this.onBookChanged,
    required this.onSortChanged,
  });

  final List<Book> books;
  final String? selectedBookId;
  final _ExcerptSort sort;
  final ValueChanged<String?> onBookChanged;
  final ValueChanged<_ExcerptSort> onSortChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
    child: Row(
      children: [
        Expanded(
          flex: 7,
          child: _ExcerptSelect<String>(
            value: selectedBookId ?? '',
            hint: '全部书籍',
            items: [
              DropdownMenuEntry<String>(
                value: '',
                label: '全部书籍',
                trailingIcon: selectedBookId == null
                    ? const Icon(Icons.check_rounded, size: 18)
                    : null,
              ),
              for (final book in books)
                DropdownMenuEntry<String>(
                  value: book.id,
                  label: book.title,
                  trailingIcon: selectedBookId == book.id
                      ? const Icon(Icons.check_rounded, size: 18)
                      : null,
                  labelWidget: Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) =>
                onBookChanged(value == null || value.isEmpty ? null : value),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: _ExcerptSelect<_ExcerptSort>(
            value: sort,
            hint: '排序',
            items: [
              DropdownMenuEntry(
                value: _ExcerptSort.newest,
                label: '最新',
                trailingIcon: sort == _ExcerptSort.newest
                    ? const Icon(Icons.check_rounded, size: 18)
                    : null,
              ),
              DropdownMenuEntry(
                value: _ExcerptSort.oldest,
                label: '最早',
                trailingIcon: sort == _ExcerptSort.oldest
                    ? const Icon(Icons.check_rounded, size: 18)
                    : null,
              ),
              DropdownMenuEntry(
                value: _ExcerptSort.random,
                label: '随机',
                trailingIcon: sort == _ExcerptSort.random
                    ? const Icon(Icons.check_rounded, size: 18)
                    : null,
              ),
            ],
            onChanged: (value) {
              if (value != null) onSortChanged(value);
            },
          ),
        ),
      ],
    ),
  );
}

class _ExcerptSelect<T> extends StatelessWidget {
  const _ExcerptSelect({
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final String hint;
  final List<DropdownMenuEntry<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF25262A) : Colors.white;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .18 : .06),
            blurRadius: 8,
            spreadRadius: -3,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: DropdownMenu<T>(
        key: ValueKey(value),
        initialSelection: value,
        hintText: hint,
        selectOnly: true,
        requestFocusOnTap: false,
        enableSearch: false,
        expandedInsets: EdgeInsets.zero,
        trailingIcon: Icon(
          Icons.keyboard_arrow_down_rounded,
          color: scheme.onSurface.withValues(alpha: .58),
        ),
        selectedTrailingIcon: Icon(
          Icons.keyboard_arrow_up_rounded,
          color: scheme.onSurface.withValues(alpha: .7),
        ),
        textStyle: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: false,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12),
          constraints: BoxConstraints.tightFor(height: 48),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: WidgetStatePropertyAll(
            Colors.black.withValues(alpha: dark ? .45 : .18),
          ),
          elevation: const WidgetStatePropertyAll(10),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 8),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
        dropdownMenuEntries: items,
        onSelected: onChanged,
      ),
    );
  }
}

class _ShelfExcerptSwitcher extends StatelessWidget {
  const _ShelfExcerptSwitcher({
    required this.section,
    required this.onChanged,
    required this.searching,
    required this.controller,
    required this.focusNode,
    required this.onSearch,
    required this.onCancel,
    required this.onQueryChanged,
  });

  final _ShelfSection section;
  final ValueChanged<_ShelfSection> onChanged;

  final bool searching;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSearch;
  final VoidCallback onCancel;
  final ValueChanged<String> onQueryChanged;

  Widget _button(String tooltip, IconData icon, VoidCallback onPressed) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          fixedSize: const Size.square(44),
        ),
        icon: Icon(icon, size: 22),
      );

  @override
  Widget build(BuildContext context) => SizedBox(
    width: min(360, MediaQuery.sizeOf(context).width - 32),
    child: Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(28),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            _button(
              searching ? '取消搜索' : '返回',
              searching ? Icons.close_rounded : Icons.arrow_back,
              searching ? onCancel : () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 4),
            if (searching)
              Expanded(
                child: TextField(
                  key: const ValueKey('bookshelf-navigation-search'),
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: section == _ShelfSection.shelf
                        ? '搜索书名或作者'
                        : '搜索摘录、书名或作者',
                    filled: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: onQueryChanged,
                  onSubmitted: (_) => focusNode.unfocus(),
                ),
              )
            else ...[
              Expanded(
                child: _item(
                  context,
                  _ShelfSection.shelf,
                  Icons.grid_view_rounded,
                  '书架',
                ),
              ),
              Expanded(
                child: _item(
                  context,
                  _ShelfSection.excerpts,
                  Icons.format_quote_rounded,
                  '摘录',
                ),
              ),
            ],
            const SizedBox(width: 4),
            _button(
              '搜索',
              Icons.search_rounded,
              searching ? () => focusNode.unfocus() : onSearch,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _item(
    BuildContext context,
    _ShelfSection value,
    IconData icon,
    String label,
  ) {
    final selected = value == section;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: selected ? Colors.white : null),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : null,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShelfEmpty extends StatelessWidget {
  const _ShelfEmpty({
    required this.allEmpty,
    required this.busy,
    required this.onImport,
  });

  final bool allEmpty;
  final bool busy;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.menu_book_outlined, size: 64),
          const SizedBox(height: 20),
          Text(
            allEmpty ? '把想读的书，放在这里' : '没有匹配的图书',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          if (allEmpty) ...[
            const SizedBox(height: 12),
            const Text('支持导入 UTF-8 TXT，导入后可离线阅读'),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: busy ? null : onImport,
              icon: const Icon(Icons.add),
              label: const Text('导入本地图书'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

class _CatalogBook {
  const _CatalogBook({
    required this.assetPath,
    required this.fileName,
    required this.tags,
  });

  final String assetPath;
  final String fileName;
  final Map<String, String?> tags;
}

class _TagFilterBar extends StatelessWidget {
  const _TagFilterBar({
    required this.tags,
    required this.selected,
    required this.onSelected,
  });

  final List<BookTag> tags;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 45,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 7),
        scrollDirection: Axis.horizontal,
        children: [
          _chip(context, '全部', null),
          for (final tag in tags) _chip(context, tag.name, tag.name),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, String? value) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = selected == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: isSelected,
        showCheckmark: false,
        side: BorderSide.none,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        backgroundColor: dark
            ? ReaderPalette.nightSheet
            : ReaderPalette.background,
        selectedColor: dark ? ReaderPalette.nightInk : ReaderPalette.accent,
        labelStyle: TextStyle(
          color: isSelected
              ? (dark ? ReaderPalette.ink : Colors.white)
              : (dark ? ReaderPalette.nightInk : ReaderPalette.inkSecondary),
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
        ),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        pressElevation: 0,
        onSelected: (_) =>
            onSelected(selected == value && value != null ? null : value),
      ),
    );
  }
}

String readerError(Object error) => error is FormatException
    ? error.message.toString()
    : '操作未完成，请重试（${error.runtimeType}）';

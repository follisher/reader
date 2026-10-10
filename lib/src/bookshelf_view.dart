import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'parser.dart';
import 'providers.dart';
import 'repository.dart';
import 'theme/reader_palette.dart';
import 'widget/book_cover.dart';

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
      await ref.read(readerLibraryProvider).initialize();
    } catch (_) {
      // Bundled books are optional.
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
            label: 'TXT / EPUB',
            extensions: ['txt', 'epub'],
            uniformTypeIdentifiers: [
              'public.plain-text',
              'org.idpf.epub-container',
            ],
          ),
        ],
      );
      final messages = <String>[];
      for (final file in files) {
        try {
          final name = file.name.toLowerCase();
          if (!name.endsWith('.txt') && !name.endsWith('.epub')) {
            throw const FormatException('请选择 UTF-8 TXT 或 EPUB 文件');
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
              note['id'] as String? ??
              '${note['chapterIndex']}:${note['start']}:${note['end']}'
                  '${kind == ReaderNoteKind.comment ? ':${note['createdAt']}' : ''}';
          result.add(
            ExcerptItem(
              ref: ReaderNoteRef(bookId: book.id, kind: kind, noteKey: key),
              book: book,
              anchor: ReaderAnchor.fromJson(note['anchor']),
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
      anchor: item.anchor,
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
              note['id'] as String? ??
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
                BookCover(
                  key: ValueKey(entries[start + column].book.id),
                  book: entries[start + column].book,
                  showProgress: true,
                  markers: entries[start + column].markers,
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
                final empty = snapshot.data!.isEmpty;
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          empty ? '还没有摘录' : '没有匹配的摘录',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          empty
                              ? '阅读时长按选中文字，添加划线或评论。\n保存的内容会汇集在这里。'
                              : '试试其他关键词，或切换图书筛选。',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: .6),
                                height: 1.6,
                              ),
                        ),
                      ],
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
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          fixedSize: const Size.square(34),
          minimumSize: const Size.square(34),
          padding: const EdgeInsets.all(6),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: Icon(icon, size: 22),
      );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: min(286, MediaQuery.sizeOf(context).width - 32),
      height: 46,
      child: DecoratedBox(
        key: const ValueKey('bookshelf-navigation-decoration'),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: dark ? 0 : .18),
          border: Border.all(
            color: Colors.black,
            width: 4,
            strokeAlign: BorderSide.strokeAlignOutside,
          ),
          borderRadius: BorderRadius.circular(25),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(25),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: ColoredBox(
              color: Colors.white.withValues(alpha: dark ? .1 : .62),
              child: Material(
                color: Colors.transparent,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: searching ? 6 : 8,
                    vertical: 5,
                  ),
                  child: _content(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) => Row(
    children: [
      _button(
        searching ? '取消搜索' : '返回',
        searching ? Icons.close_rounded : Icons.arrow_back,
        searching ? onCancel : () => Navigator.of(context).maybePop(),
      ),
      SizedBox(width: searching ? 8 : 10),
      if (searching)
        Expanded(
          child: Center(
            child: SizedBox(
              height: 34,
              child: TextField(
                textAlignVertical: TextAlignVertical.center,
                key: const ValueKey('bookshelf-navigation-search'),
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: section == _ShelfSection.shelf
                      ? '搜索书名或作者'
                      : '搜索摘录、书名或作者',
                  hintStyle: const TextStyle(fontSize: 12),
                  filled: true,
                  isDense: true,
                  constraints: const BoxConstraints.tightFor(height: 34),
                  contentPadding: const EdgeInsets.only(top:8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: onQueryChanged,
                onSubmitted: (_) => focusNode.unfocus(),
              ),
            ),
          ),
        )
      else
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = (constraints.maxWidth - 10) / 2;
              return Stack(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _item(
                          context,
                          _ShelfSection.shelf,
                          Icons.grid_view_rounded,
                          '书架',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _item(
                          context,
                          _ShelfSection.excerpts,
                          Icons.format_quote_rounded,
                          '摘录',
                        ),
                      ),
                    ],
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                    left: section == _ShelfSection.shelf ? 0 : itemWidth + 10,
                    top: 1,
                    width: itemWidth,
                    height: 34,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1.5),
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      SizedBox(width: searching ? 8 : 10),
      _button(
        '搜索',
        Icons.search_rounded,
        searching ? () => focusNode.unfocus() : onSearch,
      ),
    ],
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
        borderRadius: BorderRadius.circular(16),
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          height: 34,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? Colors.black : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? Colors.white : const Color(0xFF111111),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style:
                    const TextStyle(
                      fontSize: 13,
                      height: 1,
                      fontWeight: FontWeight.w500,
                    ).copyWith(
                      color: selected ? Colors.white : const Color(0xFF111111),
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
            const Text('支持导入 UTF-8 TXT / EPUB，导入后可离线阅读'),
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

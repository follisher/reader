import 'dart:io';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'parser.dart';
import 'providers.dart';
import 'theme/reader_palette.dart';

class BookshelfView extends ConsumerStatefulWidget {
  const BookshelfView({super.key, required this.onBookTap});

  final ValueChanged<Book> onBookTap;

  @override
  ConsumerState<BookshelfView> createState() => _BookshelfViewState();
}

class _BookshelfViewState extends ConsumerState<BookshelfView>
    with WidgetsBindingObserver {
  bool _busy = false;
  String _query = '';
  String? _selectedTag;
  String? _openRemovalBookId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _importBundledBooks();
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
      final assets = manifest.listAssets().where((path) {
        final lower = path.toLowerCase();
        return (lower.startsWith('assets/books/') ||
                lower.startsWith('packages/reader/assets/books/')) &&
            (lower.endsWith('.epub') || lower.endsWith('.txt'));
      });
      for (final path in assets) {
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
      // Bundled books are optional; keep the normal bookshelf usable.
    }
  }

  Future<List<_CatalogBook>?> _loadCatalog() async {
    try {
      final json = jsonDecode(
        await rootBundle.loadString('assets/catalog.json'),
      );
      final root = json as Map<String, dynamic>;
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _resetRemoveAction();
  }

  void _resetRemoveAction() {
    if (_openRemovalBookId != null && mounted) {
      setState(() => _openRemovalBookId = null);
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: ReaderPalette.ink,
          content: Text(message, style: const TextStyle(color: Colors.white)),
        ),
      );
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final files = await openFiles(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'EPUB / TXT',
            extensions: ['epub', 'txt'],
            uniformTypeIdentifiers: [
              'org.idpf.epub-container',
              'public.plain-text',
            ],
          ),
        ],
      );
      final messages = <String>[];
      for (final file in files) {
        try {
          if (await file.length() > LocalBookParser.maxFileBytes) {
            throw const FormatException('超过 50 MB');
          }
          final result = await ref
              .read(bookshelfRepositoryProvider)
              .importBytesWithResult(await file.readAsBytes(), file.name);
          if (result.isDuplicate) {
            messages.add('《${result.book.title}》已在书架中，已保留原有阅读进度');
          } else {
            messages.add('已添加《${result.book.title}》');
          }
        } catch (e) {
          messages.add('${file.name}：${readerError(e)}');
        }
      }
      if (files.isNotEmpty) {
        _message(messages.join('\n'));
      }
    } catch (e) {
      _message('无法导入：${readerError(e)}');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _resetRemoveAction();
      }
    }
  }

  Future<bool> _confirmRemove(Book book) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Theme(
        data: _readerTheme(dialogContext),
        child: AlertDialog(
          title: const Text('从书架移除？'),
          content: Text('将移除《${book.title}》的应用内副本和阅读进度。原始文件不受影响。'),
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
    );
    return remove == true;
  }

  Future<void> _remove(Book book) async {
    try {
      await ref.read(bookshelfRepositoryProvider).removeBook(book.id);
    } catch (e) {
      _message('移除失败：${readerError(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(bookshelfProvider);
    return Theme(
      data: _readerTheme(context),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('我的书架'),
          actions: [
            // 第一版，暂时不加入外部导入
            // IconButton(
            //   tooltip: '导入图书',
            //   onPressed: _busy ? null : _import,
            //   icon: const Icon(Icons.add),
            // ),
          ],
        ),
        body: Column(
          children: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索书名或作者',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
            ),
            if (books.hasValue)
              _TagFilterBar(
                tags: {
                  for (final book in books.value!)
                    for (final tag in book.tags) tag.name: tag,
                }.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
                selected: _selectedTag,
                onSelected: (tag) => setState(() => _selectedTag = tag),
              ),
            Expanded(
              child: books.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('书架加载失败：${readerError(error)}'),
                      TextButton(
                        onPressed: () => ref.invalidate(bookshelfProvider),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
                data: (all) {
                  final visible =
                      all
                          .where(
                            (b) =>
                                '${b.title} ${b.author} ${b.tags.map((t) => t.name).join(' ')}'
                                    .toLowerCase()
                                    .contains(_query) &&
                                (_selectedTag == null ||
                                    b.tags.any(
                                      (tag) => tag.name == _selectedTag,
                                    )),
                          )
                          .toList()
                        ..sort((a, b) {
                          final aRead = a.lastReadAt;
                          final bRead = b.lastReadAt;
                          if (aRead == null && bRead != null) return 1;
                          if (aRead != null && bRead == null) return -1;
                          if (aRead != null && bRead != null) {
                            final recent = bRead.compareTo(aRead);
                            if (recent != 0) return recent;
                          }
                          final added = b.addedAt.compareTo(a.addedAt);
                          return added != 0
                              ? added
                              : a.title.compareTo(b.title);
                        });
                  if (visible.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.menu_book_outlined, size: 64),
                            const SizedBox(height: 20),
                            Text(
                              all.isEmpty ? '把想读的书，放在这里' : '没有匹配的图书',
                              style: const TextStyle(
                                color: ReaderPalette.ink,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text('支持 EPUB 和 UTF-8 TXT，导入后可离线阅读'),
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: _busy ? null : _import,
                              icon: const Icon(Icons.add),
                              label: const Text('导入本地图书'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    physics: const ClampingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final book = visible[index];
                      return _SwipeToRemove(
                        key: ValueKey(book.id),
                        isOpen: _openRemovalBookId == book.id,
                        onDragStart: () {
                          if (_openRemovalBookId != book.id) {
                            setState(() => _openRemovalBookId = book.id);
                          }
                        },
                        onOpenChanged: (isOpen) {
                          setState(() {
                            _openRemovalBookId = isOpen ? book.id : null;
                          });
                        },
                        onRemove: () async {
                          if (await _confirmRemove(book)) {
                            await _remove(book);
                          }
                        },
                        child: Card(
                          margin: EdgeInsets.zero,
                          elevation: 0,
                          shape: const RoundedRectangleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () {
                              setState(() => _openRemovalBookId = null);
                              widget.onBookTap(book);
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _BookCover(book: book),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: SizedBox(
                                      height: _BookCover.height,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            book.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: ReaderPalette.ink,
                                              fontSize: 17,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            book.author.isEmpty
                                                ? book.format.name.toUpperCase()
                                                : book.author,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const Spacer(),
                                          LinearProgressIndicator(
                                            value: book.location.progress,
                                            minHeight: 5,
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            book.location.progress == 0
                                                ? '尚未阅读'
                                                : '已读 ${(book.location.progress * 100).round()}%',
                                            style: const TextStyle(
                                              color:
                                                  ReaderPalette.mutedSecondary,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
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

class _BookCover extends StatelessWidget {
  const _BookCover({required this.book});

  static const width = 84.0;
  static const aspectRatio = 0.72;
  static const height = width / aspectRatio;

  final Book book;

  @override
  Widget build(BuildContext context) {
    final path = book.coverPath;
    final file = path == null ? null : File(path);
    final hasCover = file != null && file.existsSync();

    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: ReaderPalette.coverPlaceholder,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              hasCover
                  ? Image.file(
                      file,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.auto_stories_outlined),
                    )
                  : const Icon(Icons.auto_stories_outlined),
              if (book.cacheReady)
                Positioned(
                  right: 0,
                  bottom: 0,
                  left: 0,
                  height: 30,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.42),
                        ],
                      ),
                    ),
                    child: Align(
                      alignment: Alignment.bottomRight,
                      child: Padding(
                        padding: EdgeInsets.only(right: 6, bottom: 5),
                        child: Semantics(
                          label: '已缓存到本地',
                          child: Icon(
                            Icons.cloud_download_outlined,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
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
      height: 48,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: ChoiceChip(
              label: const Text('全部'),
              selected: selected == null,
              onSelected: (_) => onSelected(null),
              showCheckmark: false,
              side: BorderSide.none,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
              backgroundColor: ReaderPalette.card,
              selectedColor: ReaderPalette.accent,
              labelStyle: TextStyle(
                color: selected == null ? Colors.white : ReaderPalette.ink,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final tag in tags)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: ChoiceChip(
                labelPadding: EdgeInsets.all(0),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tag.color != null) ...[
                      SizedBox(
                        width: 7,
                        height: 7,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _parseColor(tag.color!),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Text(tag.name),
                  ],
                ),
                selected: selected == tag.name,
                onSelected: (_) =>
                    onSelected(selected == tag.name ? null : tag.name),
                showCheckmark: false,
                side: BorderSide.none,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 0,
                ),
                backgroundColor: ReaderPalette.card,
                selectedColor: ReaderPalette.accent,
                labelStyle: TextStyle(
                  color: selected == tag.name
                      ? Colors.white
                      : ReaderPalette.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Color _parseColor(String value) {
    final normalized = value.replaceFirst('#', '');
    final hex = normalized.length == 6 ? 'FF$normalized' : normalized;
    final parsed = int.tryParse(hex, radix: 16);
    return parsed == null ? Colors.grey : Color(parsed);
  }
}

class _SwipeToRemove extends StatefulWidget {
  const _SwipeToRemove({
    super.key,
    required this.child,
    required this.isOpen,
    required this.onDragStart,
    required this.onOpenChanged,
    required this.onRemove,
  });

  static const actionWidth = 88.0;
  static const borderRadius = BorderRadius.all(Radius.circular(12));

  final Widget child;
  final bool isOpen;
  final VoidCallback onDragStart;
  final ValueChanged<bool> onOpenChanged;
  final Future<void> Function() onRemove;

  @override
  State<_SwipeToRemove> createState() => _SwipeToRemoveState();
}

class _SwipeToRemoveState extends State<_SwipeToRemove> {
  double _offset = 0;

  @override
  void didUpdateWidget(covariant _SwipeToRemove oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isOpen && _offset != 0) _offset = 0;
  }

  void _updateOffset(double delta) {
    setState(() {
      _offset = (_offset + delta).clamp(-_SwipeToRemove.actionWidth, 0.0);
    });
  }

  void _settle(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldOpen = velocity.abs() > 200
        ? velocity < 0
        : _offset <= -_SwipeToRemove.actionWidth / 2;
    setState(() {
      _offset = shouldOpen ? -_SwipeToRemove.actionWidth : 0;
    });
    widget.onOpenChanged(shouldOpen);
  }

  Future<void> _remove() async {
    await widget.onRemove();
    widget.onOpenChanged(false);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: _SwipeToRemove.borderRadius,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: _SwipeToRemove.actionWidth,
            child: Material(
              color: ReaderPalette.removeBackground,
              child: InkWell(
                onTap: _remove,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.delete_outline,
                      color: ReaderPalette.removeForeground,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '移除',
                      style: const TextStyle(
                        color: ReaderPalette.removeForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          GestureDetector(
            onHorizontalDragStart: (_) => widget.onDragStart(),
            onHorizontalDragUpdate: (details) =>
                _updateOffset(details.primaryDelta ?? 0),
            onHorizontalDragEnd: _settle,
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              tween: Tween(end: _offset),
              builder: (context, value, child) =>
                  Transform.translate(offset: Offset(value, 0), child: child),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}

String readerError(Object error) => error is FormatException
    ? error.message.toString()
    : '操作未完成，请重试（${error.runtimeType}）';

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as pdf;

import 'bookshelf_view.dart' show readerError;
import 'models.dart';
import 'providers.dart';
import 'repository.dart';

/// Preserves PDF page layout, including scanned books, with zoom and resume.
class PdfReaderView extends ConsumerStatefulWidget {
  const PdfReaderView({
    super.key,
    required this.book,
    this.initialChapter,
    this.initialAnchor,
  });
  final Book book;
  final int? initialChapter;
  final ReaderAnchor? initialAnchor;

  @override
  ConsumerState<PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends ConsumerState<PdfReaderView> {
  final _controller = pdf.PdfViewerController();
  late final BookshelfRepository _repository;
  late final Future<String> _path;
  int _page = 1;
  int _pageCount = 0;
  Timer? _saveTimer;
  Future<void> _saving = Future.value();
  ReadingLocation? _pendingLocation;

  int get _initialPage {
    if (widget.initialChapter != null) return widget.initialChapter! + 1;
    final anchor = widget.initialAnchor ?? widget.book.location.anchor;
    final page = anchor?.type == 'pdf' ? anchor?.value['page'] : null;
    return page is int ? page : widget.book.location.chapter + 1;
  }

  @override
  void initState() {
    super.initState();
    _repository = ref.read(bookshelfRepositoryProvider);
    _page = _initialPage;
    _path = _loadPath();
  }

  Future<String> _loadPath() async {
    if (_repository is! PublicationFileRepository) {
      throw const FormatException('当前书库不支持打开 PDF 原文件');
    }
    final path = await (_repository as PublicationFileRepository)
        .publicationPath(widget.book);
    if (!await File(path).exists()) {
      throw const FormatException('本地 PDF 文件不存在，请重新导入');
    }
    return path;
  }

  void _onPageChanged(int? page) {
    if (!mounted || page == null || _pageCount == 0) return;
    setState(() => _page = page);
    _pendingLocation = ReadingLocation(
      chapter: page - 1,
      progress: page / _pageCount,
      anchor: ReaderAnchor(type: 'pdf', value: {'page': page}),
    );
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _savePosition);
  }

  void _savePosition() {
    final location = _pendingLocation;
    if (location == null) return;
    _pendingLocation = null;
    _saving = _saving
        .then((_) => _repository.saveLocation(widget.book.id, location))
        .catchError((Object error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('阅读位置保存失败：${readerError(error)}')),
          );
        });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _savePosition();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.book.title)),
    body: FutureBuilder<String>(
      future: _path,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _error(snapshot.error!);
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return pdf.PdfViewer.file(
          snapshot.data!,
          controller: _controller,
          initialPageNumber: _initialPage,
          params: pdf.PdfViewerParams(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            onViewerReady: (document, controller) {
              if (!mounted) return;
              setState(() => _pageCount = document.pages.length);
              _onPageChanged(controller.pageNumber);
            },
            onPageChanged: _onPageChanged,
            errorBannerBuilder: (context, error, stackTrace, documentRef) =>
                _error(error),
          ),
        );
      },
    ),
    bottomNavigationBar: _pageCount == 0
        ? null
        : SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _page <= 1
                        ? null
                        : () => _controller.goToPage(pageNumber: _page - 1),
                    child: const Text('上一页'),
                  ),
                  Text('$_page / $_pageCount'),
                  TextButton(
                    onPressed: _page >= _pageCount
                        ? null
                        : () => _controller.goToPage(pageNumber: _page + 1),
                    child: const Text('下一页'),
                  ),
                ],
              ),
            ),
          ),
  );

  Widget _error(Object error) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('PDF 打开失败：${readerError(error)}', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.maybePop(context),
            child: const Text('返回书架'),
          ),
        ],
      ),
    ),
  );
}

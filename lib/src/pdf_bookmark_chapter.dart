import 'package:flutter_readium/flutter_readium.dart' as rd;

/// Display grouping is separate from the bookmark's exact page locator.
class PdfBookmarkChapter {
  const PdfBookmarkChapter({required this.title, required this.key});
  final String title;
  final String key;
}

/// Returns the flattened catalogue index for [locator]'s current PDF page.
///
/// A PDF locator points at the document (`book.pdf`), whereas TOC links point
/// at a destination inside it (`book.pdf#page=12`). Comparing their hrefs
/// directly therefore highlights the first TOC row instead of the active one.
int? resolvePdfTocIndex({
  required List<rd.Link> toc,
  required rd.Locator? locator,
  required int page,
}) {
  final entries = <rd.Link>[];
  void flatten(List<rd.Link> links) {
    for (final link in links) {
      entries.add(link);
      flatten(link.children);
    }
  }

  flatten(toc);
  final tocHref = locator?.locations?.additionalProperties['tocHref'];
  if (tocHref is String) {
    final exact = entries.indexWhere((link) => link.href == tocHref);
    if (exact >= 0) return exact;
  }

  final resource = Uri.tryParse(locator?.href ?? '')?.path;
  var selectedIndex = -1;
  var selectedPage = 0;
  for (var index = 0; index < entries.length; index++) {
    final uri = Uri.tryParse(entries[index].href);
    if (uri == null ||
        (resource != null &&
            resource.isNotEmpty &&
            uri.path.isNotEmpty &&
            uri.path != resource)) {
      continue;
    }
    final match = RegExp(r'(?:^|&)page=(\d+)(?:&|$)').firstMatch(uri.fragment);
    final start = int.tryParse(match?.group(1) ?? '');
    if (start != null && start > 0 && start <= page && start >= selectedPage) {
      selectedIndex = index;
      selectedPage = start;
    }
  }
  return selectedIndex < 0 ? null : selectedIndex;
}

PdfBookmarkChapter resolvePdfBookmarkChapter({
  required List<rd.Link> toc,
  required rd.Locator? locator,
  required int page,
  String? savedTitle,
  String? savedKey,
}) {
  final entries = <rd.Link>[];
  void flatten(List<rd.Link> links) {
    for (final link in links) {
      entries.add(link);
      flatten(link.children);
    }
  }

  flatten(toc);
  final resource = Uri.tryParse(locator?.href ?? '')?.path;
  rd.Link? selected;
  var selectedPage = 0;
  for (final link in entries) {
    final uri = Uri.tryParse(link.href);
    if (uri == null || link.title?.trim().isNotEmpty != true) continue;
    if (resource != null &&
        resource.isNotEmpty &&
        uri.path.isNotEmpty &&
        uri.path != resource) {
      continue;
    }
    final match = RegExp(r'(?:^|&)page=(\d+)(?:&|$)').firstMatch(uri.fragment);
    final start = int.tryParse(match?.group(1) ?? '');
    if (start != null && start > 0 && start <= page && start >= selectedPage) {
      selected = link;
      selectedPage = start;
    }
  }
  // Some PDFs expose named destinations rather than page fragments.
  final tocHref = locator?.locations?.additionalProperties['tocHref'];
  if (selected == null) {
    for (final link in entries) {
      if (link.title?.trim().isNotEmpty == true &&
          (link.href == tocHref ||
              (link.href.contains('#') && link.href == locator?.href))) {
        selected = link;
        break;
      }
    }
  }
  if (selected != null) {
    return PdfBookmarkChapter(
      title: selected.title!.trim(),
      key: 'toc:${selected.href}',
    );
  }
  final title = savedTitle?.trim().isNotEmpty == true
      ? savedTitle!.trim()
      : locator?.title?.trim();
  if (title != null && title.isNotEmpty) {
    return PdfBookmarkChapter(
      title: title,
      key: savedKey?.isNotEmpty == true ? savedKey! : 'title:$title',
    );
  }
  return PdfBookmarkChapter(title: '第 $page 页', key: 'page:$page');
}

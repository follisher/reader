import 'package:flutter_readium/flutter_readium.dart' as rd;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'models.dart';

/// Stable paragraph addresses shared by the continuous and native readers.
class EpubContinuousDocument {
  EpubContinuousDocument(this.content, this.publication) {
    for (var i = 0; i < content.chapters.length; i++) {
      final parts = path(content.chapters[i].id).split('/');
      _sourcePaths[parts.join('/')] = i;
      for (var start = 0; start < parts.length; start++) {
        final suffix = parts.skip(start).join('/');
        _sources.update(suffix, (old) => old == i ? i : -1, ifAbsent: () => i);
      }
    }
    for (var i = 0; i < publication.readingOrder.length; i++) {
      _links[path(publication.readingOrder[i].href)] = i;
    }
  }
  final BookContent content;
  final rd.Publication publication;
  final Map<int, BookChapter> chapters = {};
  final Map<int, Future<BookChapter>> _pending = {};
  final _sources = <String, int>{};
  final _sourcePaths = <String, int>{};
  final _links = <String, int>{};
  final _selectionText = <int, (String, List<(int, int)>)>{};
  final _selectionRanges = <rd.Locator, List<(int, int, int)>>{};

  static String path(String href) => Uri.decodeFull(
    href.split('#').first.split('?').first,
  ).replaceFirst(RegExp(r'^/+'), '');

  static bool samePath(String a, String b) {
    a = path(a);
    b = path(b);
    return a == b || a.endsWith('/$b') || b.endsWith('/$a');
  }

  int chapterFor(rd.Locator? locator) {
    if (locator == null) return 0;
    final exact = _links[path(locator.href)];
    if (exact != null) return exact;
    final index = publication.readingOrder.indexWhere(
      (link) => samePath(link.href, locator.href),
    );
    return index < 0 ? 0 : index;
  }

  Future<BookChapter> load(int index) {
    final cached = chapters[index];
    if (cached != null) return Future.value(cached);
    return _pending.putIfAbsent(index, () async {
      try {
        final link = publication.readingOrder[index];
        final source =
            _sourcePaths[path(link.href)] ??
            _sources[path(link.href)] ??
            content.chapters.indexWhere(
              (chapter) => samePath(chapter.id, link.href),
            );
        final chapter = source < 0
            ? BookChapter(
                id: link.href,
                title: link.title ?? '',
                blocks: const [],
              )
            : await content.readChapter(source);
        chapters[index] = chapter;
        return chapter;
      } finally {
        _pending.remove(index);
      }
    });
  }

  int blockFor(int chapter, rd.Locator? locator) {
    final blocks = chapters[chapter]!.blocks;
    if (blocks.isEmpty || locator == null) return 0;
    final saved = locator.locations?.additionalProperties['readerBlock'];
    final selector =
        locator.locations?.domRange?.start.cssSelector ??
        locator.locations?.cssSelector;
    final fragment = locator.locations?.fragments.firstOrNull;
    final quote = locator.text?.highlight;
    for (var i = 0; i < blocks.length; i++) {
      final document = html.parseFragment(blocks[i]);
      if (selector != null &&
          document
              .querySelectorAll('*')
              .any(
                (element) =>
                    element.attributes['data-reader-selector'] == selector,
              )) {
        return i;
      }
      if (fragment != null &&
          document
              .querySelectorAll('[id]')
              .any((element) => element.id == fragment)) {
        return i;
      }
    }
    if (quote != null && quote.isNotEmpty) {
      for (var i = 0; i < blocks.length; i++) {
        final text = html.parseFragment(blocks[i]).text ?? '';
        if (text.contains(quote)) return i;
      }
    }
    // Exact source anchors take precedence when parser revisions add headings.
    if (saved is int) return saved.clamp(0, blocks.length - 1);
    // Native progression is a layout-dependent fraction. Use paragraph weights
    // only as a fallback when no exact DOM/text anchor is available.
    final weights = blocks
        .map(
          (block) => html.parseFragment(block).text!.length.clamp(1, 1 << 30),
        )
        .toList();
    final target =
        weights.fold<int>(0, (a, b) => a + b) *
        (locator.locations?.progression ?? 0);
    var offset = 0;
    for (var i = 0; i < weights.length; i++) {
      offset += weights[i];
      if (offset > target) return i;
    }
    return blocks.length - 1;
  }

  /// Resolve selections across paragraph boundaries. SelectionArea includes
  /// display indentation and may include a reader-generated chapter heading.
  /// Keep source offsets so decorations still address the original DOM.
  List<(int, int, int)> selectionParts(int chapter, rd.Locator locator) {
    final cached = _selectionRanges[locator];
    if (cached != null) return cached;
    final body = chapters[chapter]!;
    final quote = locator.text?.highlight;
    if (quote == null || quote.isEmpty) return const [];
    String compact(String text) => text.replaceAll(RegExp(r'\s|\u3000'), '');
    final source = _selectionText.putIfAbsent(chapter, () {
      final positions = <(int, int)>[];
      final buffer = StringBuffer();
      for (var block = 0; block < body.blocks.length; block++) {
        final text = html.parseFragment(body.blocks[block]).text ?? '';
        for (var i = 0; i < text.length; i++) {
          final character = text.substring(i, i + 1);
          if (compact(character).isEmpty) continue;
          buffer.write(character);
          positions.add((block, i));
        }
      }
      return (buffer.toString(), positions);
    });
    final text = source.$1;
    final positions = source.$2;
    var needle = compact(quote);
    if (needle.isEmpty) return const [];
    var start = text.indexOf(needle);
    if (start < 0) {
      final title = compact(body.title);
      if (title.isNotEmpty && needle.startsWith(title)) {
        needle = needle.substring(title.length);
        if (needle.isEmpty) return const [];
        start = text.indexOf(needle);
      }
    }
    if (start < 0) return const [];
    // Text context disambiguates repeated quotations before block hints.
    final before = compact(locator.text?.before ?? '');
    final after = compact(locator.text?.after ?? '');
    final hint = locator.locations?.additionalProperties['readerBlock'];
    final candidates = <int>[];
    for (
      var candidate = start;
      candidate >= 0;
      candidate = text.indexOf(needle, candidate + 1)
    ) {
      if (text.substring(0, candidate).endsWith(before) &&
          text.substring(candidate + needle.length).startsWith(after)) {
        candidates.add(candidate);
      }
    }
    if (candidates.isEmpty) return const [];
    start = candidates.first;
    if (hint is int) {
      start = candidates.firstWhere(
        (i) => positions[i].$1 == hint,
        orElse: () => start,
      );
    }
    final result = <(int, int, int)>[];
    for (var i = start; i < start + needle.length; i++) {
      final position = positions[i];
      if (result.isEmpty || result.last.$1 != position.$1) {
        result.add((position.$1, position.$2, position.$2 + 1));
      } else {
        final previous = result.removeLast();
        result.add((previous.$1, previous.$2, position.$2 + 1));
      }
    }
    if (_selectionRanges.length >= 256) _selectionRanges.clear();
    _selectionRanges[locator] = result;
    return result;
  }

  /// Repairs historical cross-paragraph selections which lacked a DOM range.
  rd.Locator repairSelection(int chapter, rd.Locator original) {
    if (original.locations?.domRange != null) return original;
    final parts = selectionParts(chapter, original);
    if (parts.isEmpty) return original;
    final repaired = locatorForParts(chapter, parts);
    return repaired.locations?.domRange == null ? original : repaired;
  }

  rd.Locator locatorForParts(int chapter, List<(int, int, int)> parts) {
    final first = locatorForPart(chapter, parts.first);
    final last = locatorForPart(chapter, parts.last);
    final start = first.locations?.domRange?.start;
    final end = last.locations?.domRange?.end;
    final json = first.toJson();
    if (start != null && end != null) {
      (json['locations'] as Map)['domRange'] = {
        'start': start.toJson(),
        'end': end.toJson(),
      };
    } else {
      (json['locations'] as Map).remove('domRange');
    }
    json['text'] = {
      'highlight': parts.map((part) => _partText(chapter, part)).join(),
      'before': first.text?.before ?? '',
      'after': last.text?.after ?? '',
    };
    return rd.Locator.fromJson(json)!;
  }

  /// Toolbar hit testing and actions must resolve exactly the same ranges.
  Map<String, dynamic> selectionResult(
    rd.Locator selection,
    List<rd.ReaderDecoration> underlines, {
    required bool merge,
  }) {
    final chapter = chapterFor(selection);
    final selected = selectionParts(chapter, selection);
    var ranges = List<(int, int, int)>.of(selected);
    final ids = <String>{};
    bool overlaps(List<(int, int, int)> other) => ranges.any(
      (a) => other.any((b) => a.$1 == b.$1 && a.$2 < b.$3 && a.$3 > b.$2),
    );
    bool changed;
    do {
      changed = false;
      for (final mark in underlines) {
        if (ids.contains(mark.id) ||
            !samePath(selection.href, mark.locator.href)) {
          continue;
        }
        final parts = selectionParts(chapter, mark.locator);
        if (!overlaps(parts)) continue;
        ids.add(mark.id);
        if (merge) {
          ranges.addAll(parts);
          changed = true;
        }
      }
    } while (changed);
    rd.Locator merged = selection;
    if (merge && ranges.isNotEmpty) {
      ranges.sort(
        (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
      );
      final first = ranges.first;
      final lastBlock = ranges.last.$1;
      final end = ranges
          .where((part) => part.$1 == lastBlock)
          .map((part) => part.$3)
          .reduce((a, b) => a > b ? a : b);
      ranges = [
        for (var block = first.$1; block <= lastBlock; block++)
          (
            block,
            block == first.$1 ? first.$2 : 0,
            block == lastBlock
                ? end
                : (html.parseFragment(chapters[chapter]!.blocks[block]).text ??
                          '')
                      .length,
          ),
      ];
      merged = locatorForParts(chapter, ranges);
    }
    return {
      'selection': selection.toJson(),
      'locator': merged.toJson(),
      'ids': ids.toList(),
    };
  }

  String _partText(int chapter, (int, int, int) part) =>
      (html.parseFragment(chapters[chapter]!.blocks[part.$1]).text ?? '')
          .substring(part.$2, part.$3);

  rd.Locator locatorForPart(int chapter, (int, int, int) part) => locator(
    chapter,
    part.$1,
    selection: _partText(chapter, part),
    selectionOffset: part.$2,
  );

  rd.Locator locator(
    int chapter,
    int block, {
    double alignment = 0,
    String? selection,
    int? selectionOffset,
  }) {
    final body = chapters[chapter]!;
    final markup = block >= 0 && block < body.blocks.length
        ? body.blocks[block]
        : '';
    final fragment = html.parseFragment(markup);
    final text = fragment.text ?? '';
    final element = fragment.querySelector('[data-reader-selector]');
    final selector = element?.attributes['data-reader-selector'];
    final link = publication.readingOrder[chapter];
    final locations = <String, dynamic>{
      'progression':
          block.clamp(0, body.blocks.length) /
          body.blocks.length.clamp(1, 1 << 30),
      'totalProgression':
          (chapter +
              block.clamp(0, body.blocks.length) /
                  body.blocks.length.clamp(1, 1 << 30)) /
          publication.readingOrder.length,
      'readerBlock': block,
      'readerAlignment': alignment,
      'cssSelector': ?selector,
      if (element?.id.isNotEmpty == true) 'fragments': [element!.id],
    };
    final quote =
        selection ?? text.trim().substring(0, text.trim().length.clamp(0, 80));
    var start = text.indexOf(quote);
    if (selectionOffset != null && start >= 0) {
      for (
        var candidate = text.indexOf(quote, start + 1);
        candidate >= 0;
        candidate = text.indexOf(quote, candidate + 1)
      ) {
        if ((candidate - selectionOffset).abs() <
            (start - selectionOffset).abs()) {
          start = candidate;
        }
      }
    }
    if (selection != null && start >= 0) {
      final range = _range(fragment, start, start + quote.length);
      if (range != null) locations['domRange'] = range;
    }
    return rd.Locator.fromJson({
      'href': link.href,
      'type': link.type ?? 'application/xhtml+xml',
      'title': link.title ?? body.title,
      'locations': locations,
      'text': {
        'highlight': quote,
        if (start >= 0)
          'before': text.substring((start - 40).clamp(0, start), start),
        if (start >= 0)
          'after': text.substring(
            start + quote.length,
            (start + quote.length + 40).clamp(0, text.length),
          ),
      },
    })!;
  }

  Map<String, dynamic>? _range(dom.Node root, int start, int end) {
    var offset = 0;
    Map<String, dynamic>? first, last;
    void visit(dom.Node node) {
      if (node is dom.Text) {
        final length = node.data.length;
        final parent = node.parent;
        final selector = parent is dom.Element
            ? parent.attributes['data-reader-selector']
            : null;
        Map<String, dynamic> point(int position) => {
          'cssSelector': selector,
          'textNodeIndex': parent!.nodes.whereType<dom.Text>().toList().indexOf(
            node,
          ),
          'charOffset': position - offset,
        };
        if (selector != null && start >= offset && start < offset + length) {
          first = point(start);
        }
        if (selector != null && end > offset && end <= offset + length) {
          last = point(end);
        }
        offset += length;
      } else {
        for (final child in node.nodes) {
          visit(child);
        }
      }
    }

    visit(root);
    return first != null && last != null ? {'start': first, 'end': last} : null;
  }
}

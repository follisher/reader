import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'models.dart';

String normalizeEpubHeading(String text) =>
    text.replaceAll(RegExp(r'[\s\u200b\ufeff]+'), '');

/// Only inspect the opening title sequence. A similarly named section later
/// in the chapter must not suppress a missing chapter heading at the start.
bool needsEpubChapterHeading(BookChapter chapter) {
  final title = normalizeEpubHeading(chapter.title);
  if (title.isEmpty) return false;
  bool? inspect(dom.Node node) {
    if (node is dom.Text) return node.data.trim().isEmpty ? null : true;
    if (node is! dom.Element) return null;
    if (const {
      'div',
      'section',
      'article',
      'main',
      'header',
    }.contains(node.localName)) {
      for (final child in node.nodes) {
        final result = inspect(child);
        if (result != null) return result;
      }
      return null;
    }
    final text = normalizeEpubHeading(node.text);
    if (text.isEmpty) return null;
    if (text == title) return false;
    final titleClass = node.classes.any(
      (name) => RegExp(
        r'title|heading|chapter|volume',
        caseSensitive: false,
      ).hasMatch(name),
    );
    final numberedTitle =
        text.length < 80 &&
        RegExp(r'^(第.{1,16}[卷部篇章回节]|卷[一二三四五六七八九十百千\d])').hasMatch(text) &&
        !RegExp(r'[。，！？；]').hasMatch(text);
    if (node.localName == 'p' && (titleClass || numberedTitle)) return null;
    if (const {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(node.localName)) {
      return null;
    }
    return true;
  }

  for (final block in chapter.blocks) {
    for (final node in html.parseFragment(block).nodes) {
      final result = inspect(node);
      if (result != null) return result;
    }
  }
  return true;
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'models.dart';

abstract interface class BookParser {
  bool supports(BookFormat format);

  Future<BookContent> parse(Uint8List bytes, String fileName);
}

class LocalBookParser implements BookParser {
  static const maxFileBytes = 50 * 1024 * 1024;
  static const maxExpandedBytes = 150 * 1024 * 1024;

  @override
  bool supports(BookFormat format) => true;

  @override
  Future<BookContent> parse(Uint8List bytes, String fileName) async {
    if (bytes.length > maxFileBytes) {
      throw const FormatException('图书超过 50 MB 导入上限');
    }
    final ext = p.extension(fileName).toLowerCase();
    if (ext == '.txt') return _text(bytes, fileName);
    if (ext == '.epub') return _epub(bytes, fileName);
    throw const FormatException('目前支持 EPUB 和 TXT 文件');
  }

  BookContent _text(Uint8List bytes, String fileName) {
    String text;
    try {
      text = utf8.decode(bytes).replaceFirst('\uFEFF', '');
    } on FormatException {
      throw const FormatException('TXT 请使用 UTF-8 编码保存后再导入');
    }
    final chapters = <BookChapter>[];
    final title = _decodeFileTitle(p.basenameWithoutExtension(fileName));
    var heading = title;
    var blocks = <String>[];
    void flush() {
      if (blocks.isEmpty) return;
      chapters.add(
        BookChapter(
          id: '${chapters.length}',
          title: heading,
          blocks: List.of(blocks),
        ),
      );
      blocks = [];
    }

    final chapterPattern = RegExp(
      r'^(第[零〇一二三四五六七八九十百千万两\d]+[章回卷节部篇].{0,70}|chapter\s+\d+.{0,70})$',
      caseSensitive: false,
    );
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (chapterPattern.hasMatch(trimmed)) {
        flush();
        heading = trimmed;
        continue;
      }
      // Bound very long unbroken paragraphs and chapters for predictable layout.
      for (var start = 0; start < trimmed.length;) {
        var end = (start + 1200).clamp(0, trimmed.length);
        if (end < trimmed.length &&
            trimmed.codeUnitAt(end - 1) >= 0xD800 &&
            trimmed.codeUnitAt(end - 1) <= 0xDBFF) {
          end--;
        }
        blocks.add(
          '<p>${const HtmlEscape().convert(trimmed.substring(start, end))}</p>',
        );
        start = end;
        if (blocks.length >= 100) {
          flush();
          heading = '$title · ${chapters.length + 1}';
        }
      }
    }
    flush();
    if (chapters.isEmpty) {
      if (blocks.isNotEmpty) flush();
    }
    if (chapters.isEmpty) throw const FormatException('这本书没有可阅读的正文');
    return MemoryBookContent(title: title, author: '', chapters: chapters);
  }

  BookContent _epub(Uint8List bytes, String fileName) {
    final directory = ZipDirectory.read(InputStream(bytes));
    if (directory.fileHeaders.length > 10000 ||
        directory.fileHeaders.fold<int>(
              0,
              (sum, entry) => sum + (entry.uncompressedSize ?? 0),
            ) >
            maxExpandedBytes) {
      throw const FormatException('EPUB 资源数量或解压体积超过限制');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.length > 10000) throw const FormatException('EPUB 资源数量过多');
    final files = <String, Uint8List>{};
    var expanded = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      expanded += entry.size;
      if (expanded > maxExpandedBytes) {
        throw const FormatException('EPUB 解压内容超过 150 MB');
      }
      final name = p.posix.normalize(entry.name);
      if (name.startsWith('../') ||
          p.posix.isAbsolute(name) ||
          name.contains('\\')) {
        throw const FormatException('EPUB 包含无效资源路径');
      }
      files[name] = Uint8List.fromList(entry.content as List<int>);
    }
    String read(String name) {
      final data = files[name];
      if (data == null) throw FormatException('EPUB 缺少资源：$name');
      return utf8.decode(data);
    }

    final container = XmlDocument.parse(read('META-INF/container.xml'));
    final roots = container.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'rootfile',
    );
    if (roots.isEmpty) throw const FormatException('EPUB 缺少内容清单');
    final opfPath = roots.first.getAttribute('full-path');
    if (opfPath == null) throw const FormatException('EPUB 内容清单路径为空');
    final opf = XmlDocument.parse(read(opfPath));
    final elements = opf.descendants.whereType<XmlElement>().toList();
    String metadata(String name) {
      final values = elements
          .where((e) => e.name.local == name)
          .map((e) => e.innerText.trim())
          .where((value) => value.isNotEmpty)
          .toList();
      if (values.isEmpty) return '';
      // EPUB files may provide localized title metadata in multiple entries.
      // Prefer a Chinese title when one is available instead of blindly using
      // the first (often English) entry.
      if (name == 'title') {
        final chinese = values.where(
          (value) => RegExp(r'[\u3400-\u9FFF]').hasMatch(value),
        );
        if (chinese.isNotEmpty) return chinese.first;
      }
      return values.first;
    }

    final items = <String, String>{};
    for (final item in elements.where((e) => e.name.local == 'item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        items[id] = resolveResource(opfPath, href);
      }
    }
    final coverResourcePath = _coverResourcePath(
      elements: elements,
      items: items,
      opfPath: opfPath,
      files: files,
    );
    final conceptualPages = <String, BookChapterKind>{};
    for (final reference in elements.where(
      (e) => e.name.local == 'reference',
    )) {
      final href = reference.getAttribute('href');
      final type = reference.getAttribute('type')?.toLowerCase();
      if (href == null || type == null) continue;
      final kind = _conceptualPageKind(type);
      if (kind != null) conceptualPages[resolveResource(opfPath, href)] = kind;
    }
    final chapters = <BookChapter>[];
    final conceptualPaths = <BookChapterKind, List<String>>{};
    String? correctedHref(String base, String? href, String label) {
      if (href == null || href.contains('#')) {
        return href;
      }
      final kind = _conceptualPageKind(label);
      if (kind == null) return href;
      final matches = conceptualPaths[kind];
      if (matches == null || matches.length != 1) return href;
      return p.posix.relative(matches.single, from: p.posix.dirname(base));
    }

    final anchors = <String, int>{};
    int? targetBlock(String base, String? href) {
      if (href == null || !href.contains('#')) return null;
      final parts = href.split('#');
      return anchors['${resolveResource(base, parts.first)}#${Uri.decodeComponent(parts.sublist(1).join('#'))}'];
    }

    for (final ref in elements.where((e) => e.name.local == 'itemref')) {
      final path = items[ref.getAttribute('idref')];
      if (path == null) throw const FormatException('EPUB 阅读顺序引用了不存在的章节');
      final document = html.parse(read(path));
      final pageTitle = document.querySelector('title')?.text.trim() ?? '';
      final semanticTypes = document
          .querySelectorAll('*')
          .map((e) => e.attributes['epub:type'] ?? '')
          .join(' ')
          .split(RegExp(r'\s+'));
      final fileStem = p.basenameWithoutExtension(path).toLowerCase();
      final kind =
          conceptualPages[path] ??
          _conceptualPageKind(pageTitle) ??
          semanticTypes
              .map(_conceptualPageKind)
              .whereType<BookChapterKind>()
              .firstOrNull ??
          _conceptualPageKind(fileStem) ??
          BookChapterKind.content;
      if (kind != BookChapterKind.content) {
        conceptualPaths.putIfAbsent(kind, () => []).add(path);
      }
      if (ref.getAttribute('linear') == 'no' &&
          kind == BookChapterKind.content) {
        continue;
      }
      // Many covers wrap a bitmap in SVG. Convert local bitmap references to
      // the same offline image path used by ordinary HTML images.
      for (final svg in document.querySelectorAll('svg')) {
        final replacements = <dom.Element>[];
        for (final image in svg.querySelectorAll('image')) {
          final href = image.attributes.entries
              .where(
                (entry) =>
                    const {'href', 'xlink:href'}.contains(entry.key.toString()),
              )
              .map((entry) => entry.value)
              .firstOrNull;
          if (href != null &&
              isLocalResource(href) &&
              files.containsKey(resolveResource(path, href))) {
            replacements.add(dom.Element.tag('img')..attributes['src'] = href);
          }
        }
        if (replacements.isNotEmpty) {
          final wrapper = dom.Element.tag('div')..children.addAll(replacements);
          svg.replaceWith(wrapper);
        }
      }
      // Offline content only. Never execute scripts, embed frames, or fetch URLs.
      for (final node in document.querySelectorAll(
        'script,style,iframe,object,embed,link,video,audio,form',
      )) {
        node.remove();
      }
      for (final node in document.querySelectorAll('*')) {
        node.attributes.removeWhere(
          (key, value) =>
              key.toString().startsWith('on') ||
              key == 'style' ||
              key == 'srcset',
        );
        if (node.localName == 'img') {
          final src = node.attributes['src'];
          node.attributes.remove('src');
          if (src != null && isLocalResource(src)) {
            final resource = resolveResource(path, src);
            if (files.containsKey(resource)) {
              node.attributes['data-reader-resource'] = resource;
            }
          }
        }
        if (node.localName == 'a') node.attributes.remove('href');
      }
      final heading = document.querySelector('h1,h2,h3')?.text.trim();
      final body = document.body;
      final blocks = <String>[];
      void addBlock(dom.Node node) {
        if (node is dom.Element) {
          for (final name in [node.id, node.attributes['name']]) {
            if (name != null && name.isNotEmpty) {
              anchors['$path#$name'] = blocks.length;
            }
          }
        }
        // The primary chapter heading is represented by the directory. Keep
        // h2/h3 in the body so readers can see the source's sub-sections.
        if (node is dom.Element &&
            node.localName == 'h1' &&
            kind == BookChapterKind.content) {
          return;
        }
        // EPUB chapters often wrap all paragraphs in a single div/section.
        // Flatten structural wrappers so position remains paragraph-level.
        if (node is dom.Element &&
            const {
              'div',
              'section',
              'article',
              'main',
            }.contains(node.localName) &&
            node.children.isNotEmpty) {
          for (final child in node.nodes) {
            addBlock(child);
          }
          return;
        }
        final serialized = node is dom.Element
            ? node.outerHtml
            : const HtmlEscape().convert(node.text ?? '');
        if (serialized.trim().isNotEmpty) {
          if (node is dom.Element) {
            for (final child in node.querySelectorAll('[id], a[name]')) {
              for (final name in [child.id, child.attributes['name']]) {
                if (name != null && name.isNotEmpty) {
                  anchors['$path#$name'] = blocks.length;
                }
              }
            }
          }
          blocks.add(serialized);
        }
      }

      if (body != null) {
        for (final node in body.nodes) {
          addBlock(node);
        }
      }
      if (blocks.isEmpty) continue;
      chapters.add(
        BookChapter(
          id: path,
          title: _displayTitle(
            heading: heading,
            pageTitle: pageTitle,
            fallback: '第 ${chapters.length + 1} 节',
          ),
          blocks: blocks,
          kind: kind,
        ),
      );
    }
    if (chapters.isEmpty) {
      throw const FormatException('EPUB 没有可阅读的章节（暂不支持 DRM 图书）');
    }
    final navPath = elements
        .where(
          (element) =>
              element.name.local == 'item' &&
              (element.getAttribute('properties') ?? '')
                  .split(RegExp(r'\s+'))
                  .contains('nav'),
        )
        .map((element) => items[element.getAttribute('id')])
        .whereType<String>()
        .firstOrNull;
    List<BookTocEntry>? toc;
    if (navPath != null && files.containsKey(navPath)) {
      final navDocument = html.parse(read(navPath));
      final nav =
          navDocument.querySelector('nav[epub\\:type="toc"], nav') ??
          navDocument.querySelector('body');
      final root = nav?.querySelector('ol');
      BookTocEntry entry(dom.Element item) {
        final link = item.children
            .where((child) => child.localName == 'a')
            .firstOrNull;
        final label = link?.text.trim() ?? item.text.trim();
        final target = correctedHref(navPath, link?.attributes['href'], label);
        final href = target?.split('#').first;
        final chapter = href == null
            ? null
            : chapters.indexWhere(
                (chapter) => chapter.id == resolveResource(navPath, href),
              );
        final childList = item.children
            .where((child) => child.localName == 'ol')
            .firstOrNull;
        return BookTocEntry(
          id: '${href ?? label}:${item.hashCode}',
          title: label.isEmpty ? '未命名章节' : label,
          chapter: chapter == -1 ? null : chapter,
          block: targetBlock(navPath, target),
          children: childList == null
              ? const []
              : [
                  for (final child in childList.children.where(
                    (child) => child.localName == 'li',
                  ))
                    entry(child),
                ],
        );
      }

      if (root != null) {
        toc = [
          for (final item in root.children.where(
            (child) => child.localName == 'li',
          ))
            entry(item),
        ];
      }
    }
    if (toc == null) {
      final ncxPath = elements
          .where(
            (element) =>
                element.name.local == 'item' &&
                (element.getAttribute('media-type') ?? '').contains('dtbncx'),
          )
          .map((element) => items[element.getAttribute('id')])
          .whereType<String>()
          .firstOrNull;
      if (ncxPath != null && files.containsKey(ncxPath)) {
        final ncx = XmlDocument.parse(read(ncxPath));
        BookTocEntry entry(XmlElement point) {
          final label =
              point.descendants
                  .whereType<XmlElement>()
                  .where((element) => element.name.local == 'text')
                  .map((element) => element.innerText.trim())
                  .firstOrNull ??
              '未命名章节';
          final source = point.children
              .whereType<XmlElement>()
              .where((element) => element.name.local == 'content')
              .map((element) => element.getAttribute('src'))
              .whereType<String>()
              .firstOrNull;
          final target = correctedHref(ncxPath, source, label);
          final src = target?.split('#').first;
          final chapter = src == null
              ? -1
              : chapters.indexWhere(
                  (chapter) => chapter.id == resolveResource(ncxPath, src),
                );
          return BookTocEntry(
            id: '${src ?? label}:${point.hashCode}',
            title: label,
            chapter: chapter == -1 ? null : chapter,
            block: targetBlock(
              ncxPath,
              point.children
                  .whereType<XmlElement>()
                  .where((e) => e.name.local == 'content')
                  .firstOrNull
                  ?.getAttribute('src'),
            ),
            children: [
              for (final child in point.children.whereType<XmlElement>().where(
                (element) => element.name.local == 'navPoint',
              ))
                entry(child),
            ],
          );
        }

        final navMap = ncx.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'navMap')
            .firstOrNull;
        if (navMap != null) {
          toc = [
            for (final point in navMap.children.whereType<XmlElement>().where(
              (element) => element.name.local == 'navPoint',
            ))
              entry(point),
          ];
        }
      }
    }
    // Some EPUBs omit a nav document (or list only chapter links) even though
    // their XHTML contains useful h2/h3 section headings.  Keep the explicit
    // navigation when present, and fill empty chapter entries from those
    // headings so the reader can still offer section-level navigation.
    final baseToc =
        toc ??
        [
          for (var index = 0; index < chapters.length; index++)
            BookTocEntry(
              id: chapters[index].id,
              title: chapters[index].title,
              chapter: index,
            ),
        ];
    final enrichedToc = _addHeadingEntries(baseToc, chapters);
    final tocTitles = <int, String>{};
    for (final entry in enrichedToc) {
      final chapter = entry.chapter;
      final title = entry.title.trim();
      if (chapter != null && title.isNotEmpty && !_numericTitle(title)) {
        tocTitles.putIfAbsent(chapter, () => title);
      }
    }
    final titledChapters = [
      for (var index = 0; index < chapters.length; index++)
        BookChapter(
          id: chapters[index].id,
          title: _isPlaceholderTitle(chapters[index].title.trim())
              ? (tocTitles[index] ?? '第 ${index + 1} 节')
              : chapters[index].title,
          blocks: chapters[index].blocks,
          kind: chapters[index].kind,
        ),
    ];

    // print(
    //   '排查问题11：${_isPlaceholderTitle(metadata('title'))}   ____  '
    //   '${p.basenameWithoutExtension(fileName)} '
    //   ' ````   ${metadata('title')}',
    // );

    final metadataTitle = _decodeFileTitle(metadata('title'));
    return MemoryBookContent(
      title: _isPlaceholderTitle(metadataTitle)
          ? _decodeFileTitle(p.basenameWithoutExtension(fileName))
          : metadataTitle,
      author: metadata('creator'),
      chapters: titledChapters,
      toc: enrichedToc,
      resources: files,
      coverResourcePath: coverResourcePath,
    );
  }
}

List<BookTocEntry> _addHeadingEntries(
  List<BookTocEntry> entries,
  List<BookChapter> chapters,
) {
  return [
    for (final entry in entries) _addHeadingEntriesToEntry(entry, chapters),
  ];
}

BookTocEntry _addHeadingEntriesToEntry(
  BookTocEntry entry,
  List<BookChapter> chapters, {
  bool inferHeadings = true,
}) {
  final children = [
    for (final child in entry.children)
      _addHeadingEntriesToEntry(child, chapters, inferHeadings: false),
  ];
  // Only chapter-level entries are expanded. Existing nested navigation is
  // authoritative; inferred headings fill the common incomplete-nav case.
  if (!inferHeadings || children.isNotEmpty || entry.chapter == null) {
    return BookTocEntry(
      id: entry.id,
      title: entry.title,
      chapter: entry.chapter,
      block: entry.block,
      children: children,
    );
  }
  final chapterIndex = entry.chapter!;
  if (chapterIndex < 0 || chapterIndex >= chapters.length) return entry;
  final chapter = chapters[chapterIndex];
  if (chapter.kind != BookChapterKind.content) return entry;
  final headings = <BookTocEntry>[];
  for (var block = 0; block < chapter.blocks.length; block++) {
    final heading = html
        .parseFragment(chapter.blocks[block])
        .querySelector('h2,h3');
    final title = heading?.text.trim() ?? '';
    if (title.isEmpty) continue;
    headings.add(
      BookTocEntry(
        id: '${entry.id}#heading-$block',
        title: title,
        chapter: chapterIndex,
        block: block,
      ),
    );
  }
  if (headings.isEmpty) return entry;
  return BookTocEntry(
    id: entry.id,
    title: entry.title,
    chapter: entry.chapter,
    block: entry.block,
    children: headings,
  );
}

String _decodeFileTitle(String value) {
  final candidate = value.replaceAll('+', ' ');
  if (RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(candidate)) return value;
  try {
    final decoded = Uri.decodeComponent(candidate).trim();

    return decoded.isEmpty ? value : decoded;
  } catch (_) {
    return value;
  }
}

String _normalizedPageLabel(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-–—:：.]'), '');

bool _numericTitle(String value) =>
    RegExp(r'^[0-9０-９\s._\-:：/]+$').hasMatch(value);

BookChapterKind? _conceptualPageKind(String value) {
  switch (_normalizedPageLabel(value)) {
    case 'cover':
    case '封面':
    case 'frontcover':
      return BookChapterKind.cover;
    case 'titlepage':
    case '扉页':
    case '书名页':
      return BookChapterKind.titlePage;
    case 'copyright':
    case 'copyrightpage':
    case '版权页':
    case 'colophon':
      return BookChapterKind.copyright;
    case 'backcover':
    case '封底':
      return BookChapterKind.backCover;
  }
  return null;
}

bool _isPlaceholderTitle(String value) {
  if (_numericTitle(value.trim())) return true;
  switch (_normalizedPageLabel(value)) {
    case '':
    case '无标题':
    case 'untitled':
    case 'notitle':
    case 'untitleddocument':
    case 'document':
      return true;
  }
  return false;
}

String _displayTitle({
  required String? heading,
  required String pageTitle,
  required String fallback,
}) {
  final headingCandidate = heading?.trim() ?? '';
  final candidate =
      headingCandidate.isNotEmpty && !_isPlaceholderTitle(headingCandidate)
      ? headingCandidate
      : pageTitle.trim();
  return _isPlaceholderTitle(candidate)
      ? fallback
      : candidate.isEmpty
      ? fallback
      : candidate;
}

String? _coverResourcePath({
  required List<XmlElement> elements,
  required Map<String, String> items,
  required String opfPath,
  required Map<String, Uint8List> files,
}) {
  final manifestItems = elements
      .where((element) => element.name.local == 'item')
      .toList();
  final epub3Cover = manifestItems
      .where(
        (item) => (item.getAttribute('properties') ?? '')
            .split(RegExp(r'\s+'))
            .contains('cover-image'),
      )
      .map((item) => items[item.getAttribute('id')])
      .whereType<String>()
      .firstOrNull;
  if (epub3Cover != null && files.containsKey(epub3Cover)) return epub3Cover;

  final epub2CoverId = elements
      .where(
        (element) =>
            element.name.local == 'meta' &&
            element.getAttribute('name')?.toLowerCase() == 'cover',
      )
      .map((element) => element.getAttribute('content'))
      .whereType<String>()
      .firstOrNull;
  final epub2Cover = epub2CoverId == null ? null : items[epub2CoverId];
  if (epub2Cover != null && files.containsKey(epub2Cover)) return epub2Cover;

  final guideCoverHref = elements
      .where(
        (element) =>
            element.name.local == 'reference' &&
            element.getAttribute('type')?.toLowerCase() == 'cover',
      )
      .map((element) => element.getAttribute('href'))
      .whereType<String>()
      .firstOrNull;
  if (guideCoverHref == null) return null;
  final guideCover = resolveResource(opfPath, guideCoverHref);
  return files.containsKey(guideCover) ? guideCover : null;
}

bool isLocalResource(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      !uri.hasScheme &&
      !uri.hasAuthority &&
      !value.startsWith('/') &&
      !value.contains('\\');
}

String resolveResource(String base, String href) {
  if (!isLocalResource(href)) throw const FormatException('EPUB 包含非本地资源引用');
  final result = p.posix.normalize(
    p.posix.join(
      p.posix.dirname(base),
      Uri.decodeComponent(Uri.parse(href).path),
    ),
  );
  if (result.startsWith('../') || p.posix.isAbsolute(result)) {
    throw const FormatException('EPUB 资源路径越界');
  }
  return result;
}

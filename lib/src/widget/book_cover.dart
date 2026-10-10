import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../cover_pagination.dart';

import '../models.dart';
import '../repository.dart';

const _coverFontFallback = [
  'Songti SC',
  'Noto Serif CJK TC',
  'Noto Serif CJK SC',
];

/// The bookshelf's cover artwork, reusable without a repository or ProviderScope.
///
/// The cover includes a vertical title slip and category seal. The shelf
/// opts into note [markers] and reading [showProgress]. Parent
/// constraints override the default 110 x 162 size.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.book,
    this.onTap,
    this.onLongPress,
    this.showProgress = false,
    this.markers = const [],
    this.pagination,
  });

  final BookCoverPagination? pagination;
  final Book book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showProgress;
  final List<ShelfNoteMarker> markers;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 110,
    height: 162,
    child: Semantics(
      button: onTap != null || onLongPress != null,
      label:
          '《${book.title}》'
          '${showProgress ? '，已读 ${(book.location.progress.clamp(0.0, 1.0) * 100).round()}%' : ''}'
          '${markers.isEmpty ? '' : '，有阅读便签'}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.zero,
          onTap: onTap,
          onLongPress: onLongPress,
          child: _BookCoverArtwork(
            pagination: pagination,
            book: book,
            markers: markers,
            showProgress: showProgress,
          ),
        ),
      ),
    ),
  );
}

class _BookCoverArtwork extends StatelessWidget {
  const _BookCoverArtwork({
    required this.book,
    required this.markers,
    required this.showProgress,
    required this.pagination,
  });

  final BookCoverPagination? pagination;
  final Book book;
  final List<ShelfNoteMarker> markers;
  final bool showProgress;

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

  Color _clothColor() {
    final color = book.tags.isEmpty ? null : book.tags.first.color;
    final hex = color?.replaceFirst('#', '');
    final parsed = hex != null && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)
        ? int.tryParse('FF$hex', radix: 16)
        : null;
    if (parsed == null) return _fallbackColor();
    return HSLColor.fromColor(
      Color(parsed),
    ).withSaturation(.24).withLightness(.30).toColor();
  }

  Widget _frontCover(File? file, bool hasCover) => LayoutBuilder(
    builder: (context, constraints) {
      final color = _clothColor();
      final titleWidth = _VerticalTitle.widthFor(
        context,
        book.title,
        maxWidth: math.max(1, constraints.maxWidth - 25),
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _ClothPainter(color, _bookHash())),
          if (hasCover)
            Opacity(
              opacity: .28,
              child: Image.file(
                file!,
                fit: BoxFit.cover,
                cacheWidth: 360,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          CustomPaint(painter: _BindingPainter(color)),
          Positioned(
            top: 12,
            right: 9,
            width: titleWidth,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.max(1, constraints.maxHeight - 24),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: titleWidth,
                  child: _TitleSlip(book: book, seed: _bookHash()),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

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
            final pages = math.max(1, pagination?.pageCount ?? 100);
            final pageDepth = math.min(
              (width * .16).clamp(15.0, 20.0),
              pages * .2,
            );
            final tabs = <int, ShelfNoteMarker>{};
            for (final marker in markers) {
              final parts = marker.noteKey.split(':');
              final chapter = int.tryParse(parts.first);
              final offset = parts.length > 1 ? int.tryParse(parts[1]) : null;
              final page = chapter == null || offset == null
                  ? null
                  : pagination?.pageFor(chapter, offset);
              if (page != null) tabs.putIfAbsent(page, () => marker);
            }
            final tabPages = tabs.keys.toList()..sort();
            const coverRight = 0.0;
            const tabSize = 4.0;
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
                  left: 1,
                  right: -pageDepth,
                  bottom: 5,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      isComplex: true,
                      painter: _PageEdgesPainter(pageDepth, _clothColor()),
                    ),
                  ),
                ),

                for (var i = 0; i < tabPages.length; i++)
                  Positioned(
                    key: ValueKey('book-cover-page-tab-${tabPages[i]}'),
                    top: height * (.15 + (tabPages[i] % 7) * .1),
                    right: -pageDepth * (tabPages[i] + .5) / pages - 4,
                    child: Container(
                      width: tabSize,
                      height: 11,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Color.lerp(
                              _colors[_stableIndex(tabs[tabPages[i]]!)],
                              Colors.black,
                              .13,
                            )!,
                            _colors[_stableIndex(tabs[tabPages[i]]!)],
                            Color.lerp(
                              _colors[_stableIndex(tabs[tabPages[i]]!)],
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
                    borderRadius: BorderRadius.zero,
                    clipBehavior: Clip.antiAliasWithSaveLayer,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _frontCover(file, hasCover),
                        if (showProgress && book.location.progress > 0)
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

class _TitleSlip extends StatelessWidget {
  const _TitleSlip({required this.book, required this.seed});
  final Book book;
  final int seed;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('book-cover-title-slip'),
    painter: _PaperSlipPainter(seed),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _VerticalTitle(title: book.title),
          if (book.author.trim().isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              book.author,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Songti TC',
                fontFamilyFallback: _coverFontFallback,
                color: Color(0xFF74604B),
                fontSize: 8.5,
                height: 1.1,
              ),
            ),
          ],
          const SizedBox(height: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 20, maxHeight: 21),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: _ClassificationSeal(
                name: book.tags.isEmpty ? '典籍' : book.tags.first.name,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _VerticalTitle extends StatelessWidget {
  const _VerticalTitle({required this.title});
  final String title;

  static const style = TextStyle(
    fontFamily: 'Songti TC',
    fontFamilyFallback: _coverFontFallback,
    color: Color(0xFF332F29),
    fontSize: 14,
    height: 1.16,
    fontWeight: FontWeight.w600,
  );

  static bool _isVertical(String title) =>
      RegExp(r'[\u3400-\u9fff]').hasMatch(title);

  static List<String> _columns(String title) {
    final runes = title.replaceAll(RegExp(r'\s+'), '').runes.toList();
    final visible = runes.length > 24 ? [...runes.take(23), 0x2026] : runes;
    final columns = math.max(1, (visible.length / 8).ceil());
    final rows = (visible.length / columns).ceil();
    return [
      for (var start = 0; start < visible.length; start += rows)
        String.fromCharCodes(
          visible.sublist(start, math.min(start + rows, visible.length)),
        ).runes.map((r) => String.fromCharCode(r)).join('\n'),
    ];
  }

  static double widthFor(
    BuildContext context,
    String title, {
    required double maxWidth,
  }) {
    final vertical = _isVertical(title);
    final texts = vertical ? _columns(title) : [title];
    var contentWidth = 0.0;
    for (final text in texts) {
      final painter =
          TextPainter(
            text: TextSpan(
              text: text,
              style: vertical ? style : style.copyWith(fontSize: 11),
            ),
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
            locale: Localizations.maybeLocaleOf(context),
          )..layout(
            maxWidth: vertical ? double.infinity : math.max(1, maxWidth - 10),
          );
      contentWidth += painter.width + (vertical ? 3 : 0);
      painter.dispose();
    }
    return math.min(maxWidth, contentWidth + 10);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVertical(title)) {
      return Text(
        title,
        maxLines: 6,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: style.copyWith(fontSize: 11),
      );
    }
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        textDirection: TextDirection.ltr,
        children: [
          for (final text in _columns(title).reversed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Text(text, textAlign: TextAlign.center, style: style),
            ),
        ],
      ),
    );
  }
}

class _ClassificationSeal extends StatelessWidget {
  const _ClassificationSeal({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final label = String.fromCharCodes(name.trim().runes.take(2));
    const ink = Color(0xFFAB4E38);
    return Container(
      key: const ValueKey('book-cover-classification-seal'),
      width: 24,
      height: 25,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xEBE8D5B2),
        border: Border.all(color: ink.withValues(alpha: .88), width: 1.2),
        borderRadius: BorderRadius.circular(1),
      ),
      child: FittedBox(
        child: Row(
          textDirection: TextDirection.ltr,
          children: [
            const Text(
              '藏\n書',
              style: TextStyle(
                fontFamily: 'Songti TC',
                fontFamilyFallback: _coverFontFallback,
                color: ink,
                fontSize: 9,
                height: 1.05,
              ),
            ),
            const SizedBox(width: 2),
            Text(
              label.runes.map((r) => String.fromCharCode(r)).join('\n'),
              style: const TextStyle(
                fontFamily: 'Songti TC',
                fontFamilyFallback: _coverFontFallback,
                color: ink,
                fontSize: 9,
                height: 1.05,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClothPainter extends CustomPainter {
  const _ClothPainter(this.color, this.seed);
  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(color, Colors.white, .08)!,
            color,
            Color.lerp(color, Colors.black, .18)!,
          ],
        ).createShader(rect),
    );
    final fiber = Paint()..strokeWidth = .35;
    for (var x = 0.0; x < size.width; x += 2.7) {
      fiber.color = (x.round() + seed).isEven
          ? const Color(0x0FFFFFFF)
          : const Color(0x13000000);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), fiber);
    }
    fiber.color = const Color(0x0AFFFFFF);
    for (var y = 0.0; y < size.height; y += 3.5) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), fiber);
    }
    canvas.drawRect(
      rect.deflate(.6),
      Paint()
        ..color = const Color(0x40000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ClothPainter oldDelegate) =>
      color != oldDelegate.color || seed != oldDelegate.seed;
}

class _BindingPainter extends CustomPainter {
  const _BindingPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, 12, size.height),
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.black.withValues(alpha: .32),
            Colors.black.withValues(alpha: .06),
            Colors.white.withValues(alpha: .08),
          ],
        ).createShader(Rect.fromLTWH(0, 0, 12, size.height)),
    );
    canvas.drawLine(
      const Offset(11, 0),
      Offset(11, size.height),
      Paint()
        ..color = const Color(0x45000000)
        ..strokeWidth = .7,
    );
    final thread = Paint()
      ..color = const Color(0xFFD8CDB8)
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke;
    final shadow = Paint()
      ..color = const Color(0x70000000)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final ys = [
      for (final fraction in [.16, .38, .62, .84]) size.height * fraction,
    ];
    final spine = Path()
      ..moveTo(10.5, 0)
      ..lineTo(10.5, size.height);
    for (final y in ys) {
      canvas.drawCircle(
        Offset(10.5, y),
        1.8,
        Paint()..color = const Color(0xB8000000),
      );
      // Double horizontal strands meet the single continuous vertical thread.
      final stitches = Path();
      for (final strand in [-.8, .8]) {
        stitches
          ..moveTo(0, y + strand)
          ..lineTo(10.5, y + strand);
      }
      canvas.drawPath(stitches, shadow);
      canvas.drawPath(stitches, thread);
    }
    canvas.drawPath(spine, shadow);
    canvas.drawPath(spine, thread);
  }

  @override
  bool shouldRepaint(_BindingPainter oldDelegate) => color != oldDelegate.color;
}

class _PaperSlipPainter extends CustomPainter {
  const _PaperSlipPainter(this.seed);
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.shift(const Offset(0, 1)),
        const Radius.circular(.8),
      ),
      Paint()..color = const Color(0x35000000),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF4EAD3), Color(0xFFE6D7B9)],
        ).createShader(rect),
    );
    final random = math.Random(seed);
    final grain = Paint()..color = const Color(0x186F573B);
    for (var i = 0; i < 85; i++) {
      final point = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      canvas.drawLine(
        point,
        point + Offset(.3 + random.nextDouble(), .15),
        grain..strokeWidth = .4,
      );
    }
    final border = Paint()
      ..color = const Color(0x9664523F)
      ..strokeWidth = .65
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect.deflate(1.8), border);
    canvas.drawRect(
      rect.deflate(3.4),
      border
        ..color = const Color(0x4564523F)
        ..strokeWidth = .4,
    );
  }

  @override
  bool shouldRepaint(_PaperSlipPainter oldDelegate) => seed != oldDelegate.seed;
}

class _PageEdgesPainter extends CustomPainter {
  const _PageEdgesPainter(this.depth, this.coverColor);
  final double depth;
  final Color coverColor;

  @override
  void paint(Canvas canvas, Size size) {
    final front = size.width - depth;
    final top = Path()
      ..moveTo(0, 3)
      ..lineTo(front, 3)
      ..lineTo(size.width, 0)
      ..lineTo(depth, 0)
      ..close();
    canvas.drawPath(
      top,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF8EFD9), Color(0xFFF1E6CD)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, 3)),
    );
    final side = Path()
      ..moveTo(front, 3)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height - 3)
      ..lineTo(front, size.height)
      ..close();
    final paperRect = Rect.fromLTWH(front, 0, depth, size.height);
    canvas.save();
    canvas.clipPath(side);
    canvas.drawRect(paperRect, Paint()..color = const Color(0xFFE3D5B8));
    canvas.restore();
    // Decorative texture density depends on visible depth, not actual pages.
    final textureCount = (depth / .7).floor().clamp(1, 32);
    final darkLines = Path();
    final lightLines = Path();
    for (var stripe = 0; stripe < textureCount; stripe++) {
      final fraction = (stripe + .5) / textureCount;
      final x = front + depth * fraction;
      final y = 3 * (1 - fraction);
      final lines = stripe.isEven ? darkLines : lightLines;
      lines.moveTo(x, y);
      lines.lineTo(x, size.height - 3 * fraction);
    }
    canvas.drawPath(
      darkLines,
      Paint()
        ..color = const Color(0x807B6B50)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .05,
    );
    canvas.drawPath(
      lightLines,
      Paint()
        ..color = const Color(0x80F0E5CD)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .05,
    );
    // Darken both edges, with a transparent center at 70% of the depth.
    canvas.drawPath(
      side,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x80000000), Color(0x00000000), Color(0x33000000)],
          stops: [0, .7, 1],
        ).createShader(Rect.fromLTWH(front, 0, depth, size.height)),
    );
    canvas.drawPath(
      side,
      Paint()
        ..color = const Color(0x506F5E43)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .05,
    );
    final coverEdges = Path()
      ..moveTo(0, 3)
      ..lineTo(depth, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height - 3);
    canvas.drawPath(
      coverEdges,
      Paint()
        ..color = coverColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7,
    );
  }

  @override
  bool shouldRepaint(_PageEdgesPainter old) =>
      depth != old.depth || coverColor != old.coverColor;
}

/// Connects both display surfaces to the same cached edition and live notes.
class RepositoryBookCover extends ConsumerWidget {
  const RepositoryBookCover({
    super.key,
    required this.book,
    this.onTap,
    this.onLongPress,
    this.showProgress = false,
    this.markers,
  });
  final Book book;
  final VoidCallback? onTap, onLongPress;
  final bool showProgress;
  final List<ShelfNoteMarker>? markers;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pagination = ref
        .watch(coverPaginationProvider(book.id))
        .asData
        ?.value;
    final entries = markers == null
        ? ref.watch(shelfEntriesProvider).asData?.value
        : null;
    final notes =
        markers ??
        [
          for (final entry in entries ?? <ShelfEntry>[])
            if (entry.book.id == book.id) ...entry.markers,
        ];
    return BookCover(
      book: book,
      pagination: pagination,
      markers: notes,
      showProgress: showProgress,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

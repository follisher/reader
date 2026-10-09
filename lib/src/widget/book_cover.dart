import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../repository.dart';

/// The bookshelf's cover artwork, reusable without a repository or ProviderScope.
///
/// By default only the cover is shown, without category labels, note tabs or
/// reading progress. The shelf opts into [markers] and [showProgress]. Parent
/// constraints override the default 110 x 162 size.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.book,
    this.onTap,
    this.onLongPress,
    this.showProgress = false,
    this.markers = const [],
  });

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
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: onLongPress,
          child: _BookCoverArtwork(
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
  });

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

import 'package:flutter_readium/flutter_readium.dart' as rd;

/// Pure range comparisons used by the EPUB selection toolbar.
///
/// Text is deliberately not considered here: the same sentence can occur more
/// than once in a resource, so text equality is not proof that two selections
/// point at the same content.
class EpubUnderlineRange {
  const EpubUnderlineRange._();

  static bool sameResource(rd.Locator a, rd.Locator b) =>
      a.href.split('#').first == b.href.split('#').first;

  static bool same(rd.Locator a, rd.Locator b) {
    if (!sameResource(a, b)) return false;
    final aRange = a.locations?.domRange;
    final bRange = b.locations?.domRange;
    if (aRange != null && bRange != null) return aRange == bRange;

    final aCfi = a.locations?.partialCfi;
    final bCfi = b.locations?.partialCfi;
    return aCfi != null && aCfi.isNotEmpty && aCfi == bCfi;
  }

  static int? comparePoint(rd.Point a, rd.Point b) {
    if (a.cssSelector != b.cssSelector) return null;
    final node = a.textNodeIndex.compareTo(b.textNodeIndex);
    return node != 0 ? node : (a.charOffset ?? 0).compareTo(b.charOffset ?? 0);
  }

  /// Returns true only when overlap can be proven from stable locator data.
  static bool overlaps(rd.Locator a, rd.Locator b) {
    if (!sameResource(a, b)) return false;
    if (same(a, b)) return true;
    final aRange = a.locations?.domRange;
    final bRange = b.locations?.domRange;
    if (aRange?.end == null || bRange?.end == null) return false;
    if (aRange!.start.cssSelector != aRange.end!.cssSelector ||
        bRange!.start.cssSelector != bRange.end!.cssSelector ||
        aRange.start.cssSelector != bRange.start.cssSelector) {
      return false;
    }
    final aStartsBeforeBEnds = comparePoint(aRange.start, bRange.end!);
    final aEndsAfterBStarts = comparePoint(aRange.end!, bRange.start);
    return aStartsBeforeBEnds != null &&
        aEndsAfterBStarts != null &&
        aStartsBeforeBEnds < 0 &&
        aEndsAfterBStarts > 0;
  }

  /// Whether [outer] can be proven to contain all of [inner].
  static bool covers(rd.Locator outer, rd.Locator inner) {
    if (!sameResource(outer, inner)) return false;
    if (same(outer, inner)) return true;
    final a = outer.locations?.domRange;
    final b = inner.locations?.domRange;
    if (a?.end == null || b?.end == null) return false;
    if (a!.start.cssSelector != a.end!.cssSelector ||
        b!.start.cssSelector != b.end!.cssSelector ||
        a.start.cssSelector != b.start.cssSelector) {
      return false;
    }
    final startsBefore = comparePoint(a.start, b.start);
    final endsAfter = comparePoint(a.end!, b.end!);
    return startsBefore != null &&
        endsAfter != null &&
        startsBefore <= 0 &&
        endsAfter >= 0;
  }
}

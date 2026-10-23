package dk.nota.flutterreadium

/** Convert a Readium 1-based page to the PDF view's 0-based display index once. */
internal fun pdfViewIndex(page: Int, pageCount: Int, reversed: Boolean): Int? {
    if (page !in 1..pageCount) return null
    return if (reversed) pageCount - page else page - 1
}

internal fun pdfPageNumber(viewIndex: Int, pageCount: Int, reversed: Boolean): Int =
    if (reversed) pageCount - viewIndex else viewIndex + 1

internal fun pdfTargetPage(fragments: List<String>, position: Int?): Int? {
    val pattern = Regex("(?:^|&)page=(\\d+)(?:&|$)")
    for (fragment in fragments) {
        val page = pattern.find(fragment)?.groupValues?.get(1)?.toIntOrNull()
        if (page != null && page > 0) return page
    }
    return position?.takeIf { it > 0 }
}

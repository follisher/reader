package dk.nota.flutterreadium.models

import com.github.barteksc.pdfviewer.PDFView
import org.readium.adapter.pdfium.navigator.PdfiumPreferences
import org.readium.adapter.pdfium.navigator.PdfiumSettings
import org.readium.r2.navigator.pdf.PdfNavigatorFactory
import org.readium.r2.navigator.preferences.Axis
import org.readium.r2.shared.ExperimentalReadiumApi

@OptIn(ExperimentalReadiumApi::class)
open class PdfReaderViewModel : ReaderViewModel() {
    var preferences: PdfiumPreferences? = null

    var navigatorFactory: PdfNavigatorFactory<PdfiumSettings, PdfiumPreferences, *>? = null
    var onViewPageChanged: ((Int) -> Unit)? = null

    /** Called for every load/reconfiguration, including after a mode switch. */
    fun configurePdfView(configurator: PDFView.Configurator) {
        val horizontal = preferences?.scrollAxis == Axis.HORIZONTAL
        configurator
            .pageSnap(horizontal)
            .pageFling(horizontal)
            .autoSpacing(horizontal)
            .fitEachPage(horizontal)
            // Readium installs onPageChange itself. Observe scrolling separately
            // so the reported page is the actual PDFView page, including the last.
            .onPageScroll { page, _ -> onViewPageChanged?.invoke(page) }
    }
}

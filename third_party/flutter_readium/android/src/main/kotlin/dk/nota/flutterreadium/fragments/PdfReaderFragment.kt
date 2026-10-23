package dk.nota.flutterreadium.fragments

import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import com.github.barteksc.pdfviewer.PDFView
import dk.nota.flutterreadium.pdfTargetPage
import dk.nota.flutterreadium.pdfViewIndex
import dk.nota.flutterreadium.pdfPageNumber
import org.readium.r2.navigator.preferences.Axis
import org.readium.r2.navigator.preferences.ReadingProgression
import androidx.fragment.app.commitNow
import androidx.lifecycle.lifecycleScope
import dk.nota.flutterreadium.R
import dk.nota.flutterreadium.ReadiumReader
import dk.nota.flutterreadium.models.PdfReaderViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import org.readium.adapter.pdfium.navigator.PdfiumNavigatorFragment
import org.readium.adapter.pdfium.navigator.PdfiumPreferences
import org.readium.r2.navigator.pdf.PdfNavigatorFragment
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.util.AbsoluteUrl

private const val TAG = "PdfReaderFragment"
private const val NAVIGATOR_FRAGMENT_TAG = "READIUM_PDF_READER_FRAGMENT"

private var instanceNo = 0

/**
 * Host fragment for the Readium PDF navigator. Mirrors [EpubReaderFragment] but
 * follows the upstream PDF test-app pattern: the navigator's
 * [androidx.fragment.app.FragmentFactory] must be installed on
 * `childFragmentManager` *before* `super.onCreate`, because
 * [PdfNavigatorFragment] has an `internal` constructor that only the
 * generated factory can invoke.
 */
@ExperimentalCoroutinesApi
@OptIn(ExperimentalReadiumApi::class)
class PdfReaderFragment :
    VisualReaderFragment(),
    PdfNavigatorFragment.Listener,
    CoroutineScope by MainScope() {
    interface Listener {
        fun onPageChanged(
            pageIndex: Int,
            totalPages: Int,
            locator: Locator,
        )

        fun onExternalLinkActivated(url: AbsoluteUrl)
    }

    var listener: Listener? = null

    val started = MutableStateFlow(false)

    private val instance = ++instanceNo

    private var pdfNavigator
        get() = navigator as? PdfiumNavigatorFragment
        set(value) {
            navigator = value
        }

    private val pdfVm
        get() = vm as PdfReaderViewModel?

    private var pdfLocations: MutableStateFlow<Locator>? = null
    override val currentLocator get() = pdfLocations ?: navigator?.currentLocator

    private fun findPdfView(view: View?): PDFView? {
        if (view is PDFView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                findPdfView(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }

    private val pagesReversed: Boolean
        get() = pdfVm?.preferences?.let {
            it.scrollAxis == Axis.HORIZONTAL && it.readingProgression == ReadingProgression.RTL
        } ?: false

    override fun go(locator: Locator?, animated: Boolean): Boolean {
        if (locator == null) return false
        val page = pdfTargetPage(locator.locations.fragments, locator.locations.position)
            ?: return super.go(locator, animated)
        val view = findPdfView(pdfNavigator?.view) ?: return false
        val index = pdfViewIndex(page, view.pageCount, pagesReversed) ?: return false
        view.stopFling()
        // jumpTo targets the page start in continuous mode. It also avoids
        // Readium 3.3's duplicate decrement between navigator and Pdfium.
        view.jumpTo(index, animated && !view.isSwipeVertical)
        onViewPageChanged(view.currentPage)
        return true
    }

    fun goBackward(animated: Boolean): Boolean = turnPage(-1, animated)
    fun goForward(animated: Boolean): Boolean = turnPage(1, animated)

    private fun turnPage(delta: Int, animated: Boolean): Boolean {
        val view = findPdfView(pdfNavigator?.view) ?: return false
        val page = pdfPageNumber(view.currentPage, view.pageCount, pagesReversed) + delta
        val index = pdfViewIndex(page, view.pageCount, pagesReversed) ?: return false
        view.stopFling()
        view.jumpTo(index, animated && !view.isSwipeVertical)
        onViewPageChanged(view.currentPage)
        return true
    }

    private fun onViewPageChanged(viewIndex: Int) {
        val view = findPdfView(pdfNavigator?.view) ?: return
        if (view.pageCount <= 0) return
        val page = pdfPageNumber(viewIndex, view.pageCount, pagesReversed)
        val locations = pdfLocations ?: return
        val progression = (page - 1).toDouble() / view.pageCount
        val locator = locations.value.copy(
            locations = Locator.Locations(
                fragments = listOf("page=$page"),
                position = page,
                progression = progression,
                totalProgression = progression,
            ),
        )
        locations.value = locator
        pdfVm?.locator = locator
        listener?.onPageChanged(page, view.pageCount, locator)
    }

    @OptIn(org.readium.r2.shared.ExperimentalReadiumApi::class)
    fun updatePreferences(preferences: PdfiumPreferences) {
        val model = pdfVm ?: return
        val merged = (model.preferences ?: PdfiumPreferences()) + preferences
        // Store before submit: its asynchronous reload invokes the engine hook.
        // The model also restores the mode when the navigator is recreated.
        model.preferences = merged
        val nav = pdfNavigator
        if (nav == null) {
            Log.d(TAG, "::updatePreferences - $instance - navigator not ready")
            return
        }
        nav.submitPreferences(merged)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        Log.d(TAG, "::onCreate - $instance")
        val model = pdfVm
        val navigatorFactory = model?.navigatorFactory
        if (model == null || navigatorFactory == null) {
            Log.e(TAG, "::onCreate - $instance - missing view model or navigator factory")
            // Without a factory installed before super.onCreate, the FragmentManager
            // would crash when it tries to instantiate the (internal-ctor)
            // PdfNavigatorFragment. Install the dummy factory so the host can
            // gracefully fail rather than throw at restore time.
            childFragmentManager.fragmentFactory =
                PdfNavigatorFragment.createDummyFactory(
                    pdfEngineProvider =
                        org.readium.adapter.pdfium.navigator
                            .PdfiumEngineProvider(),
                )
            super.onCreate(savedInstanceState)
            return
        }

        childFragmentManager.fragmentFactory =
            navigatorFactory.createFragmentFactory(
                initialLocator = model.locator,
                initialPreferences = model.preferences,
                listener = this,
            )
        super.onCreate(savedInstanceState)
    }

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        try {
            super.onViewCreated(view, savedInstanceState)
            Log.d(TAG, "::onViewCreated - $instance")

            val model = pdfVm
            if (model == null || model.navigatorFactory == null) {
                Log.e(TAG, "::onViewCreated - $instance - missing model / factory")
                return
            }

            attachingNavigatorFragment = true

            lifecycleScope.launch {
                if (ReadiumReader.currentPublication != null) {
                    attachNavigator()
                } else {
                    Log.d(TAG, "::onViewCreated - $instance - publication is missing")
                }
                attachingNavigatorFragment = false
            }
        } finally {
            Log.d(TAG, "::onViewCreated - $instance - ended")
        }
    }

    override fun onResume() {
        try {
            Log.d(TAG, "::onResume - $instance - attaching=$attachingNavigatorFragment")
            if (pdfVm == null) {
                Log.d(TAG, "::onResume - $instance - missing view model")
                return
            }
            if (attachingNavigatorFragment) {
                Log.d(TAG, "::onResume - $instance - don't attach navigator")
                return
            }
            attachNavigator()
        } finally {
            super.onResume()
        }
    }

    override fun onPause() {
        try {
            Log.d(TAG, "::onPause - $instance")
            pdfVm?.locator = currentLocator?.value
            pdfVm?.onViewPageChanged = null
            pdfNavigator?.let { fragment ->
                childFragmentManager.commitNow { remove(fragment) }
            }
            pdfNavigator = null
            started.value = false
            attachingNavigatorFragment = false
        } finally {
            super.onPause()
        }
    }

    private var attachingNavigatorFragment = false

    private fun attachNavigator() {
        Log.d(TAG, "::attachNavigator() - $instance")
        if (navigator != null) {
            Log.d(TAG, "::attachNavigator() - $instance - already attached")
            return
        }

        if (ReadiumReader.currentPublication == null) {
            Log.e(TAG, "::attachNavigator() - $instance - missing publication")
            return
        }

        // The FragmentFactory was already installed in onCreate. We instantiate by
        // class name via `replace`, and the FragmentManager calls the factory.
        childFragmentManager.commitNow {
            replace(
                R.id.fragment_reader_container,
                PdfNavigatorFragment::class.java,
                Bundle(),
                NAVIGATOR_FRAGMENT_TAG,
            )
        }

        val pdfNav =
            childFragmentManager.findFragmentByTag(NAVIGATOR_FRAGMENT_TAG) as? PdfiumNavigatorFragment
        if (pdfNav == null) {
            Log.e(TAG, "::attachNavigator() - $instance - failed to retrieve PdfNavigatorFragment")
            return
        }
        pdfNavigator = pdfNav
        Log.d(TAG, "::attachNavigator() - $instance - got navigator = $pdfNav")

        if (pdfLocations == null) {
            pdfLocations = MutableStateFlow(pdfNav.currentLocator.value)
        }
        pdfVm?.onViewPageChanged = {
            // PDFView calls onPageScroll before showPage updates currentPage.
            // Read it after that synchronous update to avoid a stale page.
            val view = findPdfView(pdfNav.view)
            view?.post {
                if (findPdfView(pdfNavigator?.view) === view) {
                    onViewPageChanged(view.currentPage)
                }
            }
        }
        // A restored, already loaded view may not emit a scroll immediately.
        findPdfView(pdfNav.view)?.let { onViewPageChanged(it.currentPage) }

        started.value = true
    }
}

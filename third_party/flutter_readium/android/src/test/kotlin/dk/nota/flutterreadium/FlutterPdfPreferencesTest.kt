package dk.nota.flutterreadium

import org.junit.Assert.assertEquals
import org.junit.Test
import org.readium.r2.navigator.preferences.Axis
import org.readium.r2.shared.ExperimentalReadiumApi

@OptIn(ExperimentalReadiumApi::class)
class FlutterPdfPreferencesTest {
    @Test
    fun `legacy paginated and horizontal select the page snapping axis`() {
        for (layout in listOf("paginated", "scrollHorizontal")) {
            val preferences = FlutterPdfPreferences.fromMap(mapOf("layout" to layout))
            assertEquals(Axis.HORIZONTAL, preferences.toPdfiumPreferences().scrollAxis)
        }
    }

    @Test
    fun `vertical switch retains spacing and switches back to horizontal`() {
        val initial =
            FlutterPdfPreferences.fromMap(
                mapOf("layout" to "scrollHorizontal", "pageSpacing" to 8.0),
            ).toPdfiumPreferences()
        val vertical =
            initial + FlutterPdfPreferences.fromMap(mapOf("layout" to "scrollVertical")).toPdfiumPreferences()
        assertEquals(Axis.VERTICAL, vertical.scrollAxis)
        assertEquals(8.0, vertical.pageSpacing)
        val horizontal =
            vertical + FlutterPdfPreferences.fromMap(mapOf("layout" to "scrollHorizontal")).toPdfiumPreferences()
        assertEquals(Axis.HORIZONTAL, horizontal.scrollAxis)
        assertEquals(8.0, horizontal.pageSpacing)
    }
}

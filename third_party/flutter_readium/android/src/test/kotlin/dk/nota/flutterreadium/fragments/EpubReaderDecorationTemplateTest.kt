package dk.nota.flutterreadium.fragments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.readium.r2.navigator.Decoration
import org.readium.r2.navigator.html.HtmlDecorationTemplate

internal class EpubReaderDecorationTemplateTest {
    @Test
    fun underline_isRenderedOnEveryRangeBoxAboveTheContent() {
        val template = readerNoteDecorationTemplates()[Decoration.Style.Underline::class]!!
        val underline = underlineDecorationElement(0xff336699.toInt())

        assertEquals(HtmlDecorationTemplate.Layout.BOXES, template.layout)
        assertEquals(HtmlDecorationTemplate.Width.WRAP, template.width)
        assertTrue(underline.contains("flutter-readium-underline"))
        assertTrue(underline.contains("border-block-end: 2px solid"))
        assertTrue(underline.contains("rgba(51,102,153,1.0)"))
        assertFalse(underline.contains("--decoration-z-index: -1"))
    }
}

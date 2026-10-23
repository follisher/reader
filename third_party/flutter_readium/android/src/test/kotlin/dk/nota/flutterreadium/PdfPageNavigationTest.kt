package dk.nota.flutterreadium

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PdfPageNavigationTest {
    @Test
    fun `directory pages are converted once including first and last`() {
        for (page in listOf(1, 2, 12, 100)) {
            val target = pdfTargetPage(listOf("page=$page"), 1)!!
            val index = pdfViewIndex(target, 100, false)!!
            assertEquals(page - 1, index)
            assertEquals(page, pdfPageNumber(index, 100, false))
        }
    }

    @Test
    fun `bookmark position and compound fragments keep their exact page`() {
        assertEquals(8, pdfTargetPage(emptyList(), 8))
        assertEquals(12, pdfTargetPage(listOf("page=12&zoom=100"), 1))
        assertNull(pdfTargetPage(listOf("page=0"), null))
        assertNull(pdfViewIndex(0, 100, false))
        assertNull(pdfViewIndex(101, 100, false))
    }

    @Test
    fun `RTL reverses display order without changing logical page numbers`() {
        for (page in 1..10) {
            val index = pdfViewIndex(page, 10, true)!!
            assertEquals(10 - page, index)
            assertEquals(page, pdfPageNumber(index, 10, true))
        }
    }
}

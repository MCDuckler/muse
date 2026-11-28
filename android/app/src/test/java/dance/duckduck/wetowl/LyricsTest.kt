package dance.duckduck.wetowl

import dance.duckduck.wetowl.ui.parseLrc
import org.junit.Assert.assertEquals
import org.junit.Test

class LyricsTest {
    @Test fun `lrc lines read with every stamp, in order`() {
        val l = parseLrc("[ar:Someone]\n[00:12.5]second\n[00:01.20][01:02.345]first and again\n\n[00:20]")
        assertEquals(listOf(1200L, 12500L, 20000L, 62345L), l.map { it.atMs })
        assertEquals("first and again", l[0].text)
        assertEquals("", l[2].text)
    }
}

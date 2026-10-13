package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.services.SearchDeriver.Companion.template
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SearchDeriverTest {
    // The address a search landed on is the rule: the query comes back out as `{query}` and
    // everything else the site put there stays.
    @Test
    fun theLandingAddressBecomesTheTemplate() {
        assertEquals(
            "https://x.com/search.php?searchkey={query}&t=1",
            template("https://x.com/search.php?searchkey=%E9%9D%92%E5%B1%B1&t=1", "青山"),
        )
    }

    // A form sends a space as `+`: a title with a space in it must still be found in the address.
    @Test
    fun aQueryWithASpaceIsFoundAsAFormSendsIt() {
        assertEquals("https://x.com/s?q={query}", template("https://x.com/s?q=one+piece", "one piece"))
    }

    // A GBK site's bytes cannot be rebuilt for another query: no template beats a broken one.
    @Test
    fun aQueryInAnotherCharsetIsNotATemplate() {
        assertNull(template("https://x.com/s?q=%C7%E0%C9%BD", "青山"))
    }
}

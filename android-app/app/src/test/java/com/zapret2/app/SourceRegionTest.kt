package com.zapret2.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The reported defect, reduced to the primitive every source-shaped policy test now shares.
 *
 * A test that cuts a region out of a production file with `substringAfter`/`substringBefore` keeps
 * passing after its anchor is renamed, because both functions return the receiver unchanged when
 * the delimiter is absent: the region becomes the whole file, and `contains` finds the expected
 * text somewhere else in it. The assertions below are the ones that used to hold silently.
 */
class SourceRegionTest {

    private val source = """
        fun before() {
            marker()
        }

        fun target() {
            wanted()
        }

        fun after() {
        }
    """.trimIndent()

    @Test
    fun cutsExactlyTheRegionBetweenItsAnchors() {
        val region = source.sourceRegion(after = "fun target() {", before = "fun after() {")

        assertTrue(region.contains("wanted()"))
        assertTrue("the region must stop at its closing anchor", !region.contains("marker()"))
    }

    @Test
    fun failsLoudlyWhenTheOpeningAnchorIsGone() {
        val failure = runCatching {
            source.sourceRegion(after = "fun renamedTarget() {", before = "fun after() {")
        }.exceptionOrNull()

        assertEquals(
            "Source anchor disappeared: \"fun renamedTarget() {\"",
            failure?.message,
        )
    }

    @Test
    fun failsLoudlyWhenTheClosingAnchorIsGone() {
        val failure = runCatching {
            source.sourceRegion(after = "fun target() {", before = "fun renamedAfter() {")
        }.exceptionOrNull()

        assertEquals(
            "Source anchor disappeared: \"fun renamedAfter() {\" " +
                "(searched after \"fun target() {\")",
            failure?.message,
        )
    }

    /**
     * The exact silent widening the four affected tests inherited: with a missing anchor the plain
     * standard-library cut hands back text the test never meant to inspect, and `contains` on it
     * still succeeds.
     */
    @Test
    fun theStandardLibraryCutWouldHaveWidenedToTheWholeFileInstead() {
        val widened = source
            .substringAfter("fun renamedTarget() {")
            .substringBefore("fun after() {")

        assertTrue("this is why the pattern is banned", widened.contains("marker()"))
    }
}

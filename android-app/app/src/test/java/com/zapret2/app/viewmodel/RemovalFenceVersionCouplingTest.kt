package com.zapret2.app.viewmodel

import com.zapret2.app.repositorySourceFile
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The scheduled-removal sentence is gated on the module being new enough to publish its removal
 * fence before it touches anything. That gate is a version number written by hand, and a version
 * number written by hand can point at a release that never happens: the constant said 2.2.0 while
 * the tree shipped 2.1.6, so the predicate answered false for the very module that does fence, and
 * the sentence would have stayed silent forever. Fail-closed, and therefore silent about being
 * wrong — which is exactly why it needs pinning.
 *
 * The constant must not move with each release; it names the first release that fences, and stays
 * there. So this asserts the only thing that is true for every future release: whatever the tree
 * is about to ship must already be recognised as fencing.
 */
class RemovalFenceVersionCouplingTest {

    @Test
    fun theReleaseBeingShippedIsRecognisedAsPublishingTheFenceFirst() {
        val versionCode = repositorySourceFile("version.properties")
            .readLines()
            .firstNotNullOfOrNull { line ->
                line.trim().removePrefix("VERSION_CODE=").takeIf { it != line.trim() }
            }
            ?.toLongOrNull()
        requireNotNull(versionCode) { "version.properties does not declare VERSION_CODE" }

        val versionName = repositorySourceFile("version.properties")
            .readLines()
            .firstNotNullOfOrNull { line ->
                line.trim().removePrefix("VERSION_NAME=").takeIf { it != line.trim() }
            }
        requireNotNull(versionName) { "version.properties does not declare VERSION_NAME" }

        assertTrue(
            "the module this tree ships ($versionName) publishes its removal fence before " +
                "cleanup, but the app does not recognise it as doing so — the gate points at a " +
                "release that has not shipped, so the sentence it guards can never appear",
            modulePublishesRemovalFenceBeforeCleanup(versionName),
        )
        assertTrue(
            "the shipped version code must satisfy the gate directly too",
            modulePublishesRemovalFenceBeforeCleanup("v$versionName") && versionCode > 0,
        )
    }
}

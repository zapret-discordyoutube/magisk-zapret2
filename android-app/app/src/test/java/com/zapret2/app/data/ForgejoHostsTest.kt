package com.zapret2.app.data

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Names handed out now (random labels) come from the project's entry lists when every known name is silent. */
class ForgejoHostsTest {
    private val asset = "/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/app.apk"

    @After
    fun forget() = ForgejoHosts.forgetForTests()

    @Test
    fun aRandomGitNameFromTheEntryListIsTriedFirstAndTrustedForAssets() {
        assertFalse(isTrustedReleaseAssetUrl("https://cwdnvtsqdc.zapret.moe$asset"))
        val learned = ForgejoHosts.learn(listOf("cwdnvtsqdc.zapret.moe", "git2.zapret.moe"))
        assertEquals(listOf("cwdnvtsqdc.zapret.moe", "git2.zapret.moe"), learned)
        assertEquals("cwdnvtsqdc.zapret.moe", ForgejoHosts.all().first())
        assertTrue(isTrustedReleaseAssetUrl("https://cwdnvtsqdc.zapret.moe$asset"))
        assertFalse(isTrustedReleaseAssetUrl("https://wiki2.zapret.moe$asset"))
    }

    @Test
    fun aListCannotLeadOutsideTheProjectDomainOrToAnotherSite() {
        val learned = ForgejoHosts.learn(
            listOf("evil.example", "git.zapret.moe.evil.test", "wiki2.zapret.moe", "lk.zapret.moe", "a b.zapret.moe", " GIT5.Zapret.Moe "),
        )
        assertEquals(listOf("lk.zapret.moe", "git5.zapret.moe"), learned)
        assertFalse(ForgejoHosts.isKnown("evil.example"))
    }

    @Test
    fun aListWithoutAcceptedNamesKeepsTheBuiltInOnes() {
        assertEquals(emptyList<String>(), ForgejoHosts.learn(listOf("evil.example", "wiki3.zapret.moe")))
        assertEquals(ForgejoHosts.BUILT_IN, ForgejoHosts.all())
    }

    @Test
    fun entryListsAreReadOnlyFromTheirPlatforms() {
        ForgejoHosts.ENTRY_LISTS.forEach { assertTrue(it, isEntryListUrl(it)) }
        assertTrue(isEntryListUrl("https://script.googleusercontent.com/macros/echo?user_content_key=x"))
        listOf(
            "http://script.google.com/macros/s/x/exec",
            "https://script.google.com.evil.test/x",
            "https://user@gist.githubusercontent.com/x",
            "https://gist.githubusercontent.com:8443/x",
            "https://git2.zapret.moe/_sites/links.json",
        ).forEach { assertFalse(it, isEntryListUrl(it)) }
    }
}

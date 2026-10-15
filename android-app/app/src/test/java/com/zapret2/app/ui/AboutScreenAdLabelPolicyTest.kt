package com.zapret2.app.ui

import com.zapret2.app.repositorySourceFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every link to the VPN bot must carry its own advertising label (`start` deep link), so the bot's
 * advertising panel shows where a person came from. Label format: `<source>_<place>`, only
 * `A-Za-z0-9_-`, at most 64 characters, never the reserved `ref_` prefix.
 */
class AboutScreenAdLabelPolicyTest {

    private val labelPattern = Regex("^[A-Za-z0-9_-]{1,64}$")

    @Test
    fun everyVpnBotLinkCarriesAValidAdLabel() {
        val source = repositorySourceFile(
            "android-app/app/src/main/java/com/zapret2/app/ui/screen/AboutScreen.kt",
        ).readText()
        val links = Regex("\"(https://t\\.me/zapretvpns_bot[^\"]*)\"").findAll(source).map { it.groupValues[1] }.toList()
        assertTrue("AboutScreen no longer links to the VPN bot", links.isNotEmpty())
        links.forEach { link ->
            val label = link.substringAfter("?start=", missingDelimiterValue = "")
            assertTrue("VPN bot link without start label: $link", label.isNotEmpty())
            assertTrue("Invalid ad label: $label", labelPattern.matches(label))
            assertTrue("Reserved ref_ prefix in label: $label", !label.startsWith("ref_"))
            assertTrue("Label must start with the z2app source: $label", label.startsWith("z2app_"))
        }
        assertEquals(
            "https://t.me/zapretvpns_bot?start=z2app_about",
            links.single(),
        )
    }
}

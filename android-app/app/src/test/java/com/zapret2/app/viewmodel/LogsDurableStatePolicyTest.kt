package com.zapret2.app.viewmodel

import com.zapret2.app.repositorySourceFile
import com.zapret2.app.sourceRegion
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The logs screen was the one feature view model without a [androidx.lifecycle.SavedStateHandle],
 * so the tab, the filter and auto-scroll were silently discarded when the process died — the user
 * came back to a screen that had quietly forgotten what they had chosen.
 *
 * What must not come back is the log text itself: it is re-read on every start and is unbounded,
 * so persisting it would trade a bounded saved state for an unbounded one to recover something
 * that costs nothing to fetch again.
 */
class LogsDurableStatePolicyTest {

    private val source by lazy {
        repositorySourceFile(
            "android-app/app/src/main/java/com/zapret2/app/viewmodel/LogsViewModel.kt",
        ).readText()
    }

    @Test
    fun everyChoiceTheUserMakesIsWrittenBackAsItIsMade() {
        listOf(
            "fun selectTab(tab: LogTab) {" to "KEY_TAB",
            "fun setFilter(text: String) {" to "KEY_FILTER",
            "fun toggleAutoScroll() {" to "KEY_AUTO_SCROLL",
        ).forEach { (anchor, key) ->
            val body = source.sourceRegion(after = anchor, before = "\n    }")
            assertTrue(
                "$anchor must persist its choice under $key",
                body.contains("savedStateHandle[$key]"),
            )
        }
    }

    @Test
    fun restoredStateCoversTheChoicesAndNothingExpensive() {
        val construction = source.sourceRegion(
            after = "private val _uiState = MutableStateFlow(",
            before = "val uiState:",
        )

        assertTrue("the tab must survive process death", construction.contains("KEY_TAB"))
        assertTrue("the filter must survive process death", construction.contains("KEY_FILTER"))
        assertTrue(
            "auto-scroll must survive process death",
            construction.contains("KEY_AUTO_SCROLL"),
        )

        listOf("logs =", "cmdline =", "rawCmdline =").forEach { field ->
            assertFalse(
                "restoring $field would put unbounded log text into the saved state",
                construction.contains(field),
            )
        }
    }
}

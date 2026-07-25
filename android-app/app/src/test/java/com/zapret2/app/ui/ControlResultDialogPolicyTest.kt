package com.zapret2.app.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rollback and purge result dialogs are the last screen a destructive operation shows, and
 * both are pure rendering, so what they are allowed to withhold is pinned here.
 *
 * The gate itself — [com.zapret2.app.viewmodel.FullRollbackUiState.Result.showsDiagnostic] and its
 * purge twin — is decided in the state model and exercised there. This only holds the composables
 * to it: neither may re-attach the module's own text to its success verdict, which would silence
 * a receipt that says it could not write its status record or a command the transport cut short,
 * leaving the one static sentence about IPv6 in its place.
 */
class ControlResultDialogPolicyTest {

    @Test
    fun destructiveResultDialogs_neverHideTheModuleDiagnosticBehindTheirSuccessVerdict() {
        val source = productionFile("ui/screen/ControlScreen.kt").readText()

        mapOf(
            "FullRollbackResultDialog" to "control_full_rollback_failure_unknown",
            "ModulePurgeResultDialog" to "control_purge_failure_unknown",
        ).forEach { (dialog, blankFallback) ->
            val body = source
                .substringAfter("private fun $dialog(")
                .substringBefore("\n@Composable")

            assertTrue("$dialog lost its diagnostic block", body.contains("result.diagnostic"))
            assertTrue(
                "$dialog must gate its diagnostic on the state model, not on its own verdict",
                body.contains("if (result.showsDiagnostic) {"),
            )
            assertTrue(
                "$dialog must keep the fallback for a result that returned no text",
                body.contains("R.string.$blankFallback"),
            )
            assertFalse(
                "$dialog re-attached the module diagnostic to its success verdict",
                body.contains("if (!success)"),
            )
        }
    }

    private fun productionFile(relativePath: String): File = repositoryPath(
        "android-app/app/src/main/java/com/zapret2/app/$relativePath",
    )

    private fun repositoryPath(relativePath: String): File {
        var current = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
        repeat(8) {
            val candidate = File(current, relativePath)
            if (candidate.exists()) return candidate
            current = current.parentFile ?: return@repeat
        }
        error("Unable to locate repository path: $relativePath")
    }
}

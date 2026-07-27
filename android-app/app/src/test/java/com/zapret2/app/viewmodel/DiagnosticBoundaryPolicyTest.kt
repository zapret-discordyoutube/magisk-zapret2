package com.zapret2.app.viewmodel

import com.zapret2.app.repositorySourceFile
import com.zapret2.app.sourceRegion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The DNS manager was the one producer of user-visible dynamic text that skipped the shared
 * redaction boundary, so a missing `runtime.ini` — reachable before the module's first run —
 * rendered the module's own six-field error envelope as body copy under a localized title, with
 * no redaction, no length bound and no localized answer when there was no message at all.
 */
class DiagnosticBoundaryPolicyTest {

    private val moduleErrorEnvelope = buildString {
        appendLine("schema=1")
        appendLine("status=ERROR")
        appendLine("domain=CONFIG")
        appendLine("stage=RUNTIME_OPEN")
        appendLine("code=RUNTIME_MISSING")
        append("detail=runtime.ini is required for read-only status")
    }

    @Test
    fun sharedBoundaryBoundsTheModulesOwnErrorEnvelopeWithoutLosingItsFact() {
        val sanitized = sanitizedBoundedUiDiagnostic(moduleErrorEnvelope)

        assertTrue(
            "the boundary must keep the fact the envelope reports",
            sanitized.contains("RUNTIME_MISSING"),
        )

        val overlong = "x".repeat(64_000)
        assertTrue(
            "the boundary must bound what reaches the screen",
            sanitizedBoundedUiDiagnostic(overlong).length < overlong.length,
        )
    }

    @Test
    fun dnsManagerSendsBothOfItsDynamicDiagnosticsThroughTheBoundary() {
        val source = repositorySourceFile(
            "android-app/app/src/main/java/com/zapret2/app/viewmodel/DnsManagerViewModel.kt",
        ).readText()

        val loadFailure = source.sourceRegion(
            after = "} catch (error: Exception) {",
            before = "} finally {",
        )
        assertTrue(
            "a failed DNS load must not put an unredacted message on screen",
            loadFailure.contains("sanitizedBoundedUiDiagnostic("),
        )
        assertTrue(
            "a failure with no message at all must still say something localized",
            loadFailure.contains("R.string.dns_load_error_body"),
        )

        val moduleFailure = source.sourceRegion(
            after = "is ApplyOutcome.ModuleFailed ->",
            before = "is ApplyOutcome.Conflict ->",
        )
        assertTrue(
            "module stdout/stderr must cross the same boundary as any other diagnostic",
            moduleFailure.contains("sanitizedBoundedUiDiagnostic(outcome.diagnostic)"),
        )

        // The conflicting module's id is read off the device, so it is a device-supplied string
        // reaching the UI exactly like a module diagnostic — as a resource argument rather than
        // a Dynamic, which is why the escape count above cannot see it.
        val conflict = source.sourceRegion(
            after = "is ApplyOutcome.Conflict -> UiText.Resource(",
            before = "else -> UiText.resource(",
        )
        assertTrue(
            "a device-supplied module id must cross the boundary before it is rendered",
            conflict.contains("sanitizedBoundedUiDiagnostic(outcome.moduleId)"),
        )

        // Anything constructed straight from a raw string is what this test exists to stop, so
        // count the escapes rather than trusting that the two known sites are the only ones.
        val unbounded = Regex("UiText\\.Dynamic\\((?!sanitizedBoundedUiDiagnostic)")
            .findAll(source)
            .count()
        assertEquals(
            "every dynamic diagnostic in the DNS manager must go through the boundary",
            0,
            unbounded,
        )
    }
}

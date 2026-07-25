package com.zapret2.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModulePurgeControllerTest {

    @Test
    fun prepareProtocol_acceptsOnlyExactCompleteOneTimeRecord() {
        val valid = listOf(
            "Z2_PURGE_PREPARE_VERSION=1",
            "Z2_PURGE_PREPARE_STATUS=armed",
            "Z2_PURGE_PREPARE_TOKEN=app.1234.token",
            "Z2_PURGE_PREPARE_DIAGNOSTIC=armed",
            "Z2_PURGE_PREPARE_COMPLETE=1",
        )

        val parsed = ModulePurgeController.parsePrepareOutput(valid)
        assertTrue(parsed is ModulePurgeController.ParseResult.Valid)
        assertEquals(
            "app.1234.token",
            (parsed as ModulePurgeController.ParseResult.Valid).value.token,
        )
        assertTrue(
            ModulePurgeController.parsePrepareOutput(valid.dropLast(1))
                is ModulePurgeController.ParseResult.Invalid,
        )
        assertTrue(
            ModulePurgeController.parsePrepareOutput(valid + "Z2_PURGE_PREPARE_COMPLETE=1")
                is ModulePurgeController.ParseResult.Invalid,
        )
    }

    @Test
    fun resultProtocol_requiresCompleteContractAndProvesApkWasUntouched() {
        val parsed = ModulePurgeController.parseReportOutput(completeReport())

        assertTrue(parsed is ModulePurgeController.ParseResult.Valid)
        val report = (parsed as ModulePurgeController.ParseResult.Valid).value
        assertTrue(report.satisfiesCompleteContract)
        assertFalse(report.apkTouched)
        assertTrue(report.rebootRequired)
    }

    @Test
    fun resultProtocol_rejectsDuplicateUnknownAndNonBooleanFields() {
        val duplicate = completeReport().toMutableList().apply {
            add(size - 1, "Z2_PURGE_STATUS=complete")
        }
        val unknown = completeReport().toMutableList().apply {
            this[1] = "Z2_PURGE_UNKNOWN=complete"
        }
        val invalidBoolean = completeReport().map {
            if (it.startsWith("Z2_PURGE_APK_TOUCHED=")) "Z2_PURGE_APK_TOUCHED=false" else it
        }

        listOf(duplicate, unknown, invalidBoolean).forEach { lines ->
            assertTrue(
                ModulePurgeController.parseReportOutput(lines)
                    is ModulePurgeController.ParseResult.Invalid,
            )
        }
    }

    @Test
    fun completeStatusCannotSatisfyContractWhenAnyRemovalProofIsMissing() {
        val parsed = ModulePurgeController.parseReportOutput(
            completeReport().map {
                if (it == "Z2_PURGE_STATE_REMOVED=1") "Z2_PURGE_STATE_REMOVED=0" else it
            },
        ) as ModulePurgeController.ParseResult.Valid

        assertEquals(ModulePurgeController.Status.COMPLETE, parsed.value.status)
        assertFalse(parsed.value.satisfiesCompleteContract)
    }

    @Test
    fun partialReceiptThatRemovedEverythingIsErasedWithAnUnverifiedCleanupReservation() {
        val result = purgeResult(
            outcome = ModulePurgeController.Outcome.PARTIAL,
            status = "partial",
            overrides = mapOf("Z2_PURGE_FIREWALL_CLEAN" to "0"),
        )

        assertTrue(result.moduleFullyRemoved)
        assertTrue(result.erased)
        assertTrue(result.erasedWithUnverifiedCleanup)
    }

    @Test
    fun completeReceiptIsErasedWithoutAnyReservation() {
        val result = purgeResult(outcome = ModulePurgeController.Outcome.COMPLETE)

        assertTrue(result.erased)
        assertFalse(result.erasedWithUnverifiedCleanup)
    }

    @Test
    fun partialReceiptIsNotErasedWhenAnythingItOwnsSurvived() {
        val artifactsRemain = purgeResult(
            outcome = ModulePurgeController.Outcome.PARTIAL,
            status = "partial",
            overrides = mapOf(
                "Z2_PURGE_FIREWALL_CLEAN" to "0",
                "Z2_PURGE_STATE_REMOVED" to "0",
            ),
        )
        val apkTouched = purgeResult(
            outcome = ModulePurgeController.Outcome.PARTIAL,
            status = "partial",
            overrides = mapOf("Z2_PURGE_APK_TOUCHED" to "1"),
        )
        val appDataSurvived = purgeResult(
            outcome = ModulePurgeController.Outcome.PARTIAL,
            status = "partial",
            overrides = mapOf("Z2_PURGE_FIREWALL_CLEAN" to "0"),
        ).copy(appDataCleared = false)

        assertFalse(artifactsRemain.erased)
        assertFalse(apkTouched.erased)
        assertTrue(appDataSurvived.moduleFullyRemoved)
        assertFalse(appDataSurvived.erased)
    }

    private fun purgeResult(
        outcome: ModulePurgeController.Outcome,
        status: String = "complete",
        overrides: Map<String, String> = emptyMap(),
    ): ModulePurgeController.Result {
        val lines = completeReport().map { line ->
            val key = line.substringBefore('=')
            val value = if (key == "Z2_PURGE_STATUS") status else overrides[key]
            if (value == null) line else "$key=$value"
        }
        val parsed = ModulePurgeController.parseReportOutput(lines)
            as ModulePurgeController.ParseResult.Valid
        return ModulePurgeController.Result(outcome = outcome, report = parsed.value)
    }

    private fun completeReport(): List<String> = listOf(
        "Z2_PURGE_VERSION=1",
        "Z2_PURGE_STATUS=complete",
        "Z2_PURGE_PROCESS_CLEAN=1",
        "Z2_PURGE_FIREWALL_CLEAN=1",
        "Z2_PURGE_MODULE_REMOVED=1",
        "Z2_PURGE_STATE_REMOVED=1",
        "Z2_PURGE_EXTERNAL_REMOVED=1",
        "Z2_PURGE_APK_TOUCHED=0",
        "Z2_PURGE_REBOOT_REQUIRED=1",
        "Z2_PURGE_DIAGNOSTIC=APK preserved",
        "Z2_PURGE_COMPLETE=1",
    )
}

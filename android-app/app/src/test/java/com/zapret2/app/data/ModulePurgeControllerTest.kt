package com.zapret2.app.data

import com.zapret2.app.viewmodel.ModulePurgeUiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModulePurgeControllerTest {

    @Test
    fun prepareProtocol_acceptsOnlyExactCompleteOneTimeRecord() {
        val valid = prepareRecord()

        val parsed = ModulePurgeController.parsePrepareOutput(valid)
        assertTrue(parsed is ModulePurgeController.ParseResult.Valid)
        val report = (parsed as ModulePurgeController.ParseResult.Valid).value
        assertEquals("app.1234.token", report.token)
        assertTrue(report.armed)
        assertTrue(
            ModulePurgeController.parsePrepareOutput(valid.dropLast(1))
                is ModulePurgeController.ParseResult.Invalid,
        )
        assertTrue(
            ModulePurgeController.parsePrepareOutput(valid + "Z2_PURGE_PREPARE_COMPLETE=1")
                is ModulePurgeController.ParseResult.Invalid,
        )
    }

    /**
     * A record the parser cannot trust at all is still rejected outright, and none of these may
     * arm the commit.
     */
    @Test
    fun prepareProtocol_rejectsUnknownStatusOrVersionAndNeverArmsOnABadToken() {
        listOf(
            "Z2_PURGE_PREPARE_VERSION" to "2",
            "Z2_PURGE_PREPARE_STATUS" to "refused",
            "Z2_PURGE_PREPARE_STATUS" to "",
        ).forEach { (key, value) ->
            assertTrue(
                "$key=$value must be rejected outright",
                ModulePurgeController.parsePrepareOutput(prepareRecord(overrides = mapOf(key to value)))
                    is ModulePurgeController.ParseResult.Invalid,
            )
        }

        listOf("", "app 1234 token", "app/1234", "a".repeat(129)).forEach { token ->
            val parsed = ModulePurgeController.parsePrepareOutput(
                prepareRecord(overrides = mapOf("Z2_PURGE_PREPARE_TOKEN" to token)),
            )
            assertFalse(
                "token '$token' must never arm the commit",
                (parsed as ModulePurgeController.ParseResult.Valid).value.armed,
            )
            assertEquals(
                "Purge prepare protocol rejected the one-time confirmation",
                parsed.value.refusalError,
            )
        }
    }

    /**
     * The reported defect. `prepare_purge` refuses for eight distinct reasons and names each one
     * in `Z2_PURGE_PREPARE_DIAGNOSTIC`; a stale uninstall tombstone is the one whose remedy is
     * documented (`docs/USER_OPERATIONS_RU.md`). The parser used to discard the whole record and
     * report only "Purge prepare protocol rejected the one-time confirmation", which reads like a
     * version mismatch, and `CommandResult.diagnosticText()` could not recover the sentence: it
     * collects stderr and `ERROR:`/`DIAGNOSTIC:` prefixes, and `Z2_PURGE_PREPARE_DIAGNOSTIC=` is
     * neither. The commit path never lost its receipt this way.
     */
    @Test
    fun prepareRefusalCarriesTheModulesOwnReasonToTheUser() {
        val refusals = mapOf(
            "blocked" to listOf(
                "another update or rollback transaction is active",
                "uninstall evidence is active, malformed, or unsafe",
                "installed module identity is unsafe",
                "another irreversible purge confirmation is already armed",
                "module removal marker is unsafe",
                "stale purge request is unsafe",
                "root access is required",
            ),
            "error" to listOf(
                "secure purge state is unavailable",
                "cannot create one-time purge token",
            ),
        )

        refusals.forEach { (status, diagnostics) ->
            diagnostics.forEach { diagnostic ->
                // prepare_purge prints an empty token beside every refusal, and returns 1.
                val record = prepareRecord(
                    overrides = mapOf(
                        "Z2_PURGE_PREPARE_STATUS" to status,
                        "Z2_PURGE_PREPARE_TOKEN" to "",
                        "Z2_PURGE_PREPARE_DIAGNOSTIC" to diagnostic,
                    ),
                )
                val prepareCommand = ServiceLifecycleController.CommandResult(
                    success = false,
                    stdout = record,
                    exitCode = 1,
                )
                // The record carries no `ERROR:`/`DIAGNOSTIC:` prefix and nothing reaches stderr,
                // so the transport has nothing of its own to say. This is the whole defect.
                assertEquals(diagnostic, "", prepareCommand.diagnosticText())

                val parsed = ModulePurgeController.parsePrepareOutput(record)
                assertTrue(diagnostic, parsed is ModulePurgeController.ParseResult.Valid)
                val report = (parsed as ModulePurgeController.ParseResult.Valid).value
                assertFalse(diagnostic, report.armed)

                // What `purgeInsideExclusiveTask` builds for a prepare it could not arm, and what
                // `showModulePurgeResult` then renders.
                val result = ModulePurgeController.Result(
                    outcome = ModulePurgeController.Outcome.COMMAND_FAILED,
                    prepareReport = report,
                    command = prepareCommand,
                    error = report.refusalError,
                )

                assertEquals(
                    "the user must be told why the purge was refused",
                    "Module purge was refused before anything was removed\n$diagnostic",
                    result.diagnosticText(),
                )
                assertFalse(diagnostic, result.moduleDirectoryRemoved)
                assertFalse(diagnostic, result.erased)
            }
        }
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
        // The outcome is graded by production from the receipt and the command, not handed to the
        // fixture, so asserting it is an assertion about `classifyReport` rather than about the
        // argument the test just passed in. `commit_purge` returns 0 on this path on purpose —
        // "the return code still says the module is gone" — which is why the erase is admitted.
        val result = gradedPurgeResult(
            status = "partial",
            overrides = mapOf("Z2_PURGE_FIREWALL_CLEAN" to "0"),
            commandSucceeded = true,
        )

        assertEquals(ModulePurgeController.Outcome.PARTIAL, result.outcome)
        assertTrue(result.moduleFullyRemoved)
        assertTrue(result.erased)
        assertTrue(purgeDialog(result).unverifiedCleanup)
    }

    @Test
    fun completeReceiptIsErasedWithoutAnyReservation() {
        val result = gradedPurgeResult(status = "complete", commandSucceeded = true)

        assertEquals(ModulePurgeController.Outcome.COMPLETE, result.outcome)
        assertTrue(result.erased)
        assertFalse(purgeDialog(result).unverifiedCleanup)
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
            overrides = mapOf(
                "Z2_PURGE_FIREWALL_CLEAN" to "0",
                "Z2_PURGE_APK_TOUCHED" to "1",
            ),
        )
        val serviceSurvived = purgeResult(
            outcome = ModulePurgeController.Outcome.PARTIAL,
            status = "partial",
            overrides = mapOf(
                "Z2_PURGE_FIREWALL_CLEAN" to "0",
                "Z2_PURGE_PROCESS_CLEAN" to "0",
            ),
        )
        val rebootNotDemanded = purgeResult(
            outcome = ModulePurgeController.Outcome.PARTIAL,
            status = "partial",
            overrides = mapOf(
                "Z2_PURGE_FIREWALL_CLEAN" to "0",
                "Z2_PURGE_REBOOT_REQUIRED" to "0",
            ),
        )
        val appDataSurvived = purgeResult(
            outcome = ModulePurgeController.Outcome.PARTIAL,
            status = "partial",
            overrides = mapOf("Z2_PURGE_FIREWALL_CLEAN" to "0"),
        ).copy(appDataCleared = false)

        assertFalse(artifactsRemain.erased)
        assertFalse(apkTouched.erased)
        assertFalse(serviceSurvived.erased)
        assertFalse(rebootNotDemanded.erased)
        assertTrue(appDataSurvived.moduleFullyRemoved)
        assertFalse(appDataSurvived.erased)
    }

    /**
     * The reported defect: a module that printed a flawless `complete` receipt and then failed —
     * a lifecycle timeout after the payload, for one — is classified as a receipt that cannot be
     * trusted, and the erase verdict has to follow that classification rather than the payload.
     */
    @Test
    fun completeReceiptFromACommandThatFailedIsNeverErased() {
        val rejected = purgeResult(
            outcome = ModulePurgeController.Outcome.INVALID_PROTOCOL,
            command = commandResult(success = false),
        )

        assertTrue(checkNotNull(rejected.report).satisfiesCompleteContract)
        assertFalse(rejected.moduleFullyRemoved)
        assertFalse(rejected.erased)
    }

    /**
     * A `partial` that asserts a verified-clean firewall contradicts its own status: the module
     * reserves `partial` for the run that removed everything and could not re-read one family.
     * Honouring it would put the IPv6 reservation on screen for a firewall the module verified.
     */
    @Test
    fun partialReceiptThatAlreadyProvedTheFirewallCleanIsNotErased() {
        val contradictory = purgeResult(
            outcome = ModulePurgeController.Outcome.PARTIAL,
            status = "partial",
        )

        val receipt = checkNotNull(contradictory.report)
        assertTrue(receipt.satisfiesRemovedContract)
        assertTrue(receipt.firewallClean)
        assertFalse(contradictory.moduleFullyRemoved)
        assertFalse(contradictory.erased)
    }

    /**
     * Exhaustive agreement contract: outcome x receipt status x firewall proof x command exit.
     * Only the two self-consistent verdicts erase anything, and only from a command that survived.
     */
    @Test
    fun erasedRequiresTheOutcomeTheReceiptAndTheCommandToAgree() {
        val statuses = ModulePurgeController.Status.entries.map(
            ModulePurgeController.Status::wireValue,
        )
        ModulePurgeController.Outcome.entries.forEach { outcome ->
            statuses.forEach { status ->
                listOf(true, false).forEach { firewallClean ->
                    listOf(true, false).forEach { commandSucceeded ->
                        val result = purgeResult(
                            outcome = outcome,
                            status = status,
                            overrides = mapOf(
                                "Z2_PURGE_FIREWALL_CLEAN" to if (firewallClean) "1" else "0",
                            ),
                            command = commandResult(commandSucceeded),
                        )
                        val expected = commandSucceeded && when (outcome) {
                            ModulePurgeController.Outcome.COMPLETE ->
                                status == "complete" && firewallClean
                            ModulePurgeController.Outcome.PARTIAL ->
                                status == "partial" && !firewallClean
                            else -> false
                        }
                        val label = "$outcome/$status/firewall=$firewallClean/ok=$commandSucceeded"

                        assertEquals(label, expected, result.moduleFullyRemoved)
                        assertEquals(label, expected, result.erased)
                        // The screen reserves the IPv6 caveat for exactly what stayed unproven,
                        // across the command dimension the dialog's own test does not enumerate.
                        // The expected side is the fixture's firewall bit; the actual side is the
                        // production predicate the dialog renders.
                        assertEquals(
                            label,
                            expected && !firewallClean,
                            purgeDialog(result).unverifiedCleanup,
                        )
                    }
                }
            }
        }
    }

    /**
     * The reported defect, on the controller's side of it.
     *
     * Clearing APK-private state is the last step of a purge and the only one that runs after the
     * module verdict is already in. When it fails, the module is nonetheless gone — its directory,
     * its state tree and the purge script that would retry went with it — so the failure has to
     * land on the erase verdict without taking the module verdict back with it. Rewriting the
     * outcome does exactly that: it puts the outcome at odds with the receipt it grades, and
     * `moduleFullyRemoved`, which requires the two to agree, silently turns false.
     */
    @Test
    fun retainedApkPrivateStateFailsTheEraseWithoutUndoingTheModuleVerdict() {
        listOf(
            ModulePurgeController.Outcome.COMPLETE to "complete",
            ModulePurgeController.Outcome.PARTIAL to "partial",
        ).forEach { (outcome, status) ->
            val honoured = purgeResult(
                outcome = outcome,
                status = status,
                overrides = mapOf(
                    "Z2_PURGE_FIREWALL_CLEAN" to if (status == "complete") "1" else "0",
                ),
                command = commandResult(success = true),
            )
            assertTrue(status, honoured.erased)

            val appDataSurvived = honoured.withAppDataRetained()

            assertEquals(status, honoured.outcome, appDataSurvived.outcome)
            assertEquals(status, honoured.report, appDataSurvived.report)
            assertTrue(status, appDataSurvived.moduleFullyRemoved)
            assertFalse(status, appDataSurvived.appDataCleared)
            assertFalse(status, appDataSurvived.erased)
            assertTrue(
                status,
                appDataSurvived.diagnosticText().contains("APK-private state could not be cleared"),
            )
        }
    }

    private fun commandResult(success: Boolean) = ServiceLifecycleController.CommandResult(
        success = success,
        exitCode = if (success) 0 else 1,
        error = if (success) null else "Root command timed out",
    )

    private fun prepareRecord(
        overrides: Map<String, String> = emptyMap(),
    ): List<String> = listOf(
        "Z2_PURGE_PREPARE_VERSION" to "1",
        "Z2_PURGE_PREPARE_STATUS" to "armed",
        "Z2_PURGE_PREPARE_TOKEN" to "app.1234.token",
        "Z2_PURGE_PREPARE_DIAGNOSTIC" to "armed",
        "Z2_PURGE_PREPARE_COMPLETE" to "1",
    ).map { (key, value) -> "$key=${overrides[key] ?: value}" }

    /** The screen predicate this controller's verdict feeds, so assertions can read it directly. */
    private fun purgeDialog(result: ModulePurgeController.Result) = ModulePurgeUiState.Result(
        outcome = result.outcome,
        erased = result.erased,
        rebootRequired = result.rebootRequired,
        diagnostic = "",
    )

    /**
     * A result whose outcome comes from [ModulePurgeController.classifyReport], the way
     * `purgeInsideExclusiveTask` builds it — as opposed to [purgeResult], which lets a test pair an
     * arbitrary outcome with an arbitrary receipt to prove the two must agree.
     */
    private fun gradedPurgeResult(
        status: String,
        overrides: Map<String, String> = emptyMap(),
        commandSucceeded: Boolean,
    ): ModulePurgeController.Result {
        val lines = completeReport().map { line ->
            val key = line.substringBefore('=')
            val value = if (key == "Z2_PURGE_STATUS") status else overrides[key]
            if (value == null) line else "$key=$value"
        }
        val report = (
            ModulePurgeController.parseReportOutput(lines)
                as ModulePurgeController.ParseResult.Valid
            ).value
        return ModulePurgeController.Result(
            outcome = ModulePurgeController.classifyReport(report, commandSucceeded),
            report = report,
            command = commandResult(commandSucceeded),
        )
    }

    private fun purgeResult(
        outcome: ModulePurgeController.Outcome,
        status: String = "complete",
        overrides: Map<String, String> = emptyMap(),
        command: ServiceLifecycleController.CommandResult? = null,
    ): ModulePurgeController.Result {
        val lines = completeReport().map { line ->
            val key = line.substringBefore('=')
            val value = if (key == "Z2_PURGE_STATUS") status else overrides[key]
            if (value == null) line else "$key=$value"
        }
        val parsed = ModulePurgeController.parseReportOutput(lines)
            as ModulePurgeController.ParseResult.Valid
        return ModulePurgeController.Result(
            outcome = outcome,
            report = parsed.value,
            command = command,
        )
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

package com.zapret2.app.viewmodel

import com.zapret2.app.data.ModuleInstallState
import com.zapret2.app.data.ModuleMutationState
import com.zapret2.app.data.ModulePurgeController
import com.zapret2.app.data.PendingModuleState
import com.zapret2.app.data.ServiceLifecycleController
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the purge owes the user after it commits, on both sides of its verdict.
 *
 * Every receipt below is one of the exact `purge_report` calls in
 * `zapret2/scripts/lifecycle/zapret-purge.sh`, in the module's own field order
 * (`status process_clean firewall_clean module_removed state_removed external_removed
 * reboot_required diagnostic`), parsed and graded by the production code path.
 *
 * The one fact that ties them together is the order inside `commit_purge`: the durable
 * `$MODDIR/remove` fence is published *before* the module touches any tree, and every rejection
 * that can still happen before the fence goes up reports `blocked` or `error`. `partial` therefore
 * means "the fence is already up", which is what the failure dialog has to say out loud, and a
 * `complete`/erasing receipt means the module is gone for the rest of this process.
 */
class ModulePurgeTerminalSessionTest {

    /**
     * D2. A failing purge that already published the removal fence must not leave the user with
     * "erase failed" alone: the module is retired at the next boot either way, and a user who reads
     * only the failure concludes the module survived.
     */
    @Test
    fun failedPurgeAfterTheRemovalFenceStillTellsTheUserTheModuleIsScheduledForRemoval() {
        val postFenceFailures = mapOf(
            // purge_report partial 0 0 0 0 0 1 "verified service/firewall uninstall failed: ..."
            "uninstall failed" to purgeReceipt(
                status = "partial",
                processClean = "0",
                firewallClean = "0",
                moduleRemoved = "0",
                stateRemoved = "0",
                externalRemoved = "0",
                rebootRequired = "1",
                diagnostic = "verified service/firewall uninstall failed: stop refused",
            ),
            // purge_report partial 1 0 "$module_removed" "$state_removed" "$external_removed" 1
            "external workspace survived, IPv6 unverified" to purgeReceipt(
                status = "partial",
                processClean = "1",
                firewallClean = "0",
                moduleRemoved = "1",
                stateRemoved = "1",
                externalRemoved = "0",
                rebootRequired = "1",
                diagnostic = "the module stays scheduled for removal at the next reboot, but " +
                    "these remain now: external staging workspace; the IPv6 ruleset could not " +
                    "be verified",
            ),
            // purge_report partial 1 1 "$module_removed" "$state_removed" "$external_removed" 1
            "module directory and private state survived" to purgeReceipt(
                status = "partial",
                processClean = "1",
                firewallClean = "1",
                moduleRemoved = "0",
                stateRemoved = "0",
                externalRemoved = "1",
                rebootRequired = "1",
                diagnostic = "service and firewall are clean and the module stays scheduled for " +
                    "removal at the next reboot, but these remain now: module directory, " +
                    "private state",
            ),
            // The same call with every removal flag measured as 1: field-for-field the twin of the
            // erasing receipt below, separated from it only by the command that returned 1.
            "unidentified cleanup step failed" to purgeReceipt(
                status = "partial",
                processClean = "1",
                firewallClean = "0",
                moduleRemoved = "1",
                stateRemoved = "1",
                externalRemoved = "1",
                rebootRequired = "1",
                diagnostic = "the module stays scheduled for removal at the next reboot, but " +
                    "an unidentified cleanup step failed; the IPv6 ruleset could not be verified",
            ),
        )

        postFenceFailures.forEach { (label, receipt) ->
            // commit_purge returns 1 on each of these, so the root command failed too.
            val dialog = purgeDialogState(receipt, commandSucceeded = false)

            assertFalse(label, dialog.erased)
            assertEquals(label, ModulePurgeController.Outcome.PARTIAL, dialog.outcome)
            assertTrue(
                "$label must tell the user the module is still scheduled for removal",
                dialog.moduleRemovalStillScheduled,
            )
        }
    }

    /**
     * The same sentence must never appear for a rejection that never reached the fence: those
     * really do leave the module installed, and promising a reboot would delete it is worse than
     * saying nothing.
     */
    @Test
    fun purgeRejectedBeforeTheRemovalFenceNeverClaimsTheModuleIsScheduledForRemoval() {
        val preFenceRejections = mapOf(
            // purge_report blocked 0 0 0 0 0 0 "purge confirmation is missing, expired, ..."
            "expired confirmation" to purgeReceipt(
                status = "blocked",
                processClean = "0",
                firewallClean = "0",
                moduleRemoved = "0",
                stateRemoved = "0",
                externalRemoved = "0",
                rebootRequired = "0",
                diagnostic = "purge confirmation is missing, expired, or belongs to another caller",
            ),
            // purge_report blocked 0 0 0 0 0 0 "installed module identity changed"
            "identity changed" to purgeReceipt(
                status = "blocked",
                processClean = "0",
                firewallClean = "0",
                moduleRemoved = "0",
                stateRemoved = "0",
                externalRemoved = "0",
                rebootRequired = "0",
                diagnostic = "installed module identity changed",
            ),
            // purge_report error 0 0 0 0 0 0 "cannot publish the permanent module-removal gate"
            "fence could not be published" to purgeReceipt(
                status = "error",
                processClean = "0",
                firewallClean = "0",
                moduleRemoved = "0",
                stateRemoved = "0",
                externalRemoved = "0",
                rebootRequired = "0",
                diagnostic = "cannot publish the permanent module-removal gate",
            ),
        )

        preFenceRejections.forEach { (label, receipt) ->
            val dialog = purgeDialogState(receipt, commandSucceeded = false)

            assertFalse(label, dialog.erased)
            assertNotEquals(label, ModulePurgeController.Outcome.PARTIAL, dialog.outcome)
            assertFalse(
                "$label never published the fence and must not promise a removal",
                dialog.moduleRemovalStillScheduled,
            )
        }
    }

    /** An erased receipt already says the module is gone; it must not also be "scheduled". */
    @Test
    fun erasedPurgeResultsNeverShowTheScheduledRemovalSentence() {
        // purge_report complete 1 1 1 1 1 1 "Zapret2 module data was permanently removed; ..."
        val complete = purgeDialogState(completeReceipt(), commandSucceeded = true)
        assertTrue(complete.erased)
        assertFalse(complete.moduleRemovalStillScheduled)

        // purge_report partial 1 0 1 1 1 1 "... but the IPv6 ruleset could not be verified"
        val erasedWithUnverifiedFirewall = purgeDialogState(
            purgeReceipt(
                status = "partial",
                processClean = "1",
                firewallClean = "0",
                moduleRemoved = "1",
                stateRemoved = "1",
                externalRemoved = "1",
                rebootRequired = "1",
                diagnostic = "Zapret2 module data was permanently removed, but the IPv6 ruleset " +
                    "could not be verified; the pending reboot clears it",
            ),
            commandSucceeded = true,
        )
        assertTrue(erasedWithUnverifiedFirewall.erased)
        assertTrue(erasedWithUnverifiedFirewall.unverifiedCleanup)
        assertFalse(erasedWithUnverifiedFirewall.moduleRemovalStillScheduled)
    }

    /**
     * D3. Once the purge removed the module, the reset it publishes has to survive every later
     * status read of this process. The read that was already in flight when the purge committed is
     * the sharp case: it holds the pre-purge environment it sampled, the refresh sequence retires
     * only *older* reads, and nothing else would ever correct the screen again.
     */
    @Test
    fun completedPurgeIsTerminalAndALaterStatusPublicationCannotReviveTheModule() {
        val erased = purgeControllerResult(completeReceipt(), commandSucceeded = true)
        assertTrue(erased.moduleFullyRemoved)

        val reset = installedControlState().afterModulePurge(erased)
        assertTrue(reset.modulePurgeCompleted)

        // Exactly what refreshStatus() would publish from an environment it sampled pre-purge.
        val republished = reset.withModuleStatusPublication {
            copy(
                isRunning = true,
                canStopService = true,
                status = ControlStatus.RUNNING,
                moduleInstallState = ModuleInstallState.READY,
                pendingModuleState = PendingModuleState.NONE,
                moduleMutationState = ModuleMutationState.IDLE,
                moduleVersion = "2.1.5",
                hasAuthoritativeRuntimeSettings = true,
                iptablesActive = true,
                nfqueueRulesCount = 2,
            )
        }

        assertEquals(reset, republished)
        assertEquals(ModuleInstallState.MISSING, republished.moduleInstallState)
        assertEquals("", republished.moduleVersion)
        assertFalse(republished.isRunning)
        assertFalse(republished.canStopService)
        assertFalse(republished.iptablesActive)
        assertFalse(republished.hasAuthoritativeRuntimeSettings)
        assertFalse(republished.canPurgeModule)
        assertFalse(republished.canFullRollback)
        assertFalse(republished.canEditSettings)
    }

    /**
     * The gate is armed by the module verdict alone. A purge that left the module behind — and a
     * screen that never purged — must keep taking status updates, or the screen would freeze on
     * whatever it happened to show.
     */
    @Test
    fun statusPublicationsKeepApplyingWhileTheModuleStillExists() {
        val installed = installedControlState()
        assertFalse(installed.modulePurgeCompleted)
        assertEquals(
            ControlStatus.STOPPED,
            installed.withModuleStatusPublication { copy(status = ControlStatus.STOPPED) }.status,
        )

        val failed = purgeControllerResult(
            purgeReceipt(
                status = "partial",
                processClean = "1",
                firewallClean = "1",
                moduleRemoved = "0",
                stateRemoved = "0",
                externalRemoved = "1",
                rebootRequired = "1",
                diagnostic = "service and firewall are clean and the module stays scheduled for " +
                    "removal at the next reboot, but these remain now: module directory, " +
                    "private state",
            ),
            commandSucceeded = false,
        )
        val afterFailure = installed.afterModulePurge(failed)

        assertFalse(afterFailure.modulePurgeCompleted)
        assertEquals(
            ControlStatus.STOPPED,
            afterFailure
                .withModuleStatusPublication { copy(status = ControlStatus.STOPPED) }
                .status,
        )
    }

    /**
     * The gate only works if `refreshStatus()` actually goes through it. Nothing inside it may
     * write the screen directly, and the read itself must be skipped once the module — and the
     * status script the read needs — is gone.
     */
    @Test
    fun everyStatusPublicationInTheViewModelGoesThroughTheTerminalPurgeGate() {
        val source = productionFile("viewmodel/ControlViewModel.kt").readText()
        val refreshStatus = source
            .substringAfter("private suspend fun refreshStatus(): ServiceSnapshot {")
            .substringBefore("\n    fun refreshStatusManually()")

        assertTrue(
            "refreshStatus must not even query a module this session already erased",
            refreshStatus.contains("if (_uiState.value.modulePurgeCompleted) return"),
        )
        val publications = Regex("_uiState\\.update").findAll(refreshStatus).count()
        val gated = Regex("withModuleStatusPublication").findAll(refreshStatus).count()
        assertTrue("refreshStatus stopped publishing anything", publications > 0)
        assertEquals(
            "refreshStatus publishes the module state outside the terminal purge gate",
            publications,
            gated,
        )

        val purgeLaunch = source
            .substringAfter("private fun startModulePurge(reason: ModulePurgeLaunchReason) {")
            .substringBefore("private fun showModulePurgeResult(")
        assertTrue(
            "the purge must arm the terminal gate through afterModulePurge",
            purgeLaunch.contains("afterModulePurge(result)"),
        )
    }

    private fun installedControlState() = ControlUiState(
        isRunning = true,
        status = ControlStatus.RUNNING,
        autostart = true,
        moduleVersion = "2.1.5",
        canStopService = true,
        iptablesActive = true,
        nfqueueRulesCount = 2,
        hasRootAccess = true,
        hasAuthoritativeRuntimeSettings = true,
        moduleInstallState = ModuleInstallState.READY,
    )

    private fun purgeDialogState(
        receipt: List<String>,
        commandSucceeded: Boolean,
    ): ModulePurgeUiState.Result {
        val result = purgeControllerResult(receipt, commandSucceeded)
        return modulePurgeResultState(result, sanitizedBoundedUiDiagnostic(result.diagnosticText()))
    }

    private fun purgeControllerResult(
        receipt: List<String>,
        commandSucceeded: Boolean,
    ): ModulePurgeController.Result {
        val parsed = ModulePurgeController.parseReportOutput(receipt)
        val report = (parsed as ModulePurgeController.ParseResult.Valid).value
        return ModulePurgeController.Result(
            outcome = ModulePurgeController.classifyReport(report, commandSucceeded),
            report = report,
            command = ServiceLifecycleController.CommandResult(
                success = commandSucceeded,
                exitCode = if (commandSucceeded) 0 else 1,
            ),
        )
    }

    private fun completeReceipt(): List<String> = purgeReceipt(
        status = "complete",
        processClean = "1",
        firewallClean = "1",
        moduleRemoved = "1",
        stateRemoved = "1",
        externalRemoved = "1",
        rebootRequired = "1",
        diagnostic = "Zapret2 module data was permanently removed; APK preserved; reboot required",
    )

    @Suppress("LongParameterList")
    private fun purgeReceipt(
        status: String,
        processClean: String,
        firewallClean: String,
        moduleRemoved: String,
        stateRemoved: String,
        externalRemoved: String,
        rebootRequired: String,
        diagnostic: String,
    ): List<String> = listOf(
        "Z2_PURGE_VERSION=1",
        "Z2_PURGE_STATUS=$status",
        "Z2_PURGE_PROCESS_CLEAN=$processClean",
        "Z2_PURGE_FIREWALL_CLEAN=$firewallClean",
        "Z2_PURGE_MODULE_REMOVED=$moduleRemoved",
        "Z2_PURGE_STATE_REMOVED=$stateRemoved",
        "Z2_PURGE_EXTERNAL_REMOVED=$externalRemoved",
        "Z2_PURGE_APK_TOUCHED=0",
        "Z2_PURGE_REBOOT_REQUIRED=$rebootRequired",
        "Z2_PURGE_DIAGNOSTIC=$diagnostic",
        "Z2_PURGE_COMPLETE=1",
    )

    private fun productionFile(relativePath: String): File {
        val target = "android-app/app/src/main/java/com/zapret2/app/$relativePath"
        var current = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
        repeat(8) {
            val candidate = File(current, target)
            if (candidate.exists()) return candidate
            current = current.parentFile ?: return@repeat
        }
        error("Unable to locate repository path: $target")
    }
}

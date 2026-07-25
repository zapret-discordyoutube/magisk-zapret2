package com.zapret2.app.viewmodel

import com.zapret2.app.data.ModuleEnvironmentSnapshot
import com.zapret2.app.data.ModuleInstallState
import com.zapret2.app.data.ModuleMutationState
import com.zapret2.app.data.ModulePurgeController
import com.zapret2.app.data.NetworkStatsManager
import com.zapret2.app.data.PendingModuleState
import com.zapret2.app.data.ServiceLifecycleController
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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
     * The sentence is only true of a module that publishes the removal fence before it touches
     * anything. Shipped releases up to v2.1.5 print the *same* version-1 `partial` receipt for the
     * opposite case — `publish_remove_marker` failed, no marker exists, the module survives the
     * reboot — and the app legitimately runs ahead of the module: `updateAll` installs the two
     * independently, the pending-APK and partial update outcomes leave the APK newer until the
     * next reboot, and a sideloaded APK does the same.
     */
    @Test
    fun scheduledRemovalSentenceIsWithheldFromModulesThatPrintPartialWhenTheFenceFailed() {
        // zapret-purge.sh v2.1.5:185 — purge_report partial 1 1 0 0 0 1 "cannot publish ..."
        val fenceFailed = purgeReceipt(
            status = "partial",
            processClean = "1",
            firewallClean = "1",
            moduleRemoved = "0",
            stateRemoved = "0",
            externalRemoved = "0",
            rebootRequired = "1",
            diagnostic = "cannot publish the permanent module-removal gate",
        )

        val onShippedModule = purgeDialogState(
            fenceFailed,
            commandSucceeded = false,
            moduleVersion = PRE_FENCE_MODULE_VERSION,
        )
        assertEquals(ModulePurgeController.Outcome.PARTIAL, onShippedModule.outcome)
        assertTrue(onShippedModule.rebootRequired)
        assertFalse(
            "a module that prints partial when the fence failed must not promise a removal",
            onShippedModule.moduleRemovalStillScheduled,
        )

        val onFenceFirstModule = purgeDialogState(
            fenceFailed,
            commandSucceeded = false,
            moduleVersion = FENCE_FIRST_MODULE_VERSION,
        )
        assertTrue(
            "a module that reserves partial for post-fence states still owes the sentence",
            onFenceFirstModule.moduleRemovalStillScheduled,
        )

        listOf("", "unknown", "v2.1.6-rc1", "2.1", "v0.0.0").forEach { version ->
            assertFalse(
                "module version '$version' must fail closed",
                purgeDialogState(
                    fenceFailed,
                    commandSucceeded = false,
                    moduleVersion = version,
                ).moduleRemovalStillScheduled,
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
     * The reset must retire every field that described the erased module's runtime.
     *
     * `afterModulePurge` is the last write the screen accepts — it arms the terminal gate, and
     * `refreshStatus()` returns early afterwards — so anything it leaves behind stays on screen
     * for the life of the process, sourced from a killed process and a deleted module. Before this
     * was fixed the screen showed "Stopped" with an uptime of the dead nfqws2, its whole process
     * card, the NFQUEUE capability badge and the module's own red diagnostic.
     *
     * The projection is the same one `refreshStatus()` publishes for a module it cannot query.
     */
    @Test
    fun purgeResetRetiresEveryRuntimeFactOfTheErasedModule() {
        val installed = installedControlState()
        // Guard: a fixture that never had these cannot prove they were cleared.
        assertNotEquals("", installed.uptime)
        assertNotEquals(ProcessStats(), installed.processStats)
        assertNotEquals(NetworkStatsManager.IptablesDetail(), installed.iptablesDetail)
        assertNotNull(installed.moduleDiagnostic)
        assertTrue(installed.nfqueueSupported)

        val reset = installed.afterModulePurge(
            purgeControllerResult(completeReceipt(), commandSucceeded = true),
        )

        assertEquals(ControlStatus.NOT_INSTALLED, reset.status)
        assertEquals("", reset.uptime)
        assertEquals(ProcessStats(), reset.processStats)
        assertEquals(NetworkStatsManager.IptablesDetail(), reset.iptablesDetail)
        assertNull(reset.moduleDiagnostic)
        assertFalse(reset.nfqueueSupported)
        assertEquals(ModuleInstallState.MISSING, reset.moduleInstallState)
        assertEquals(PendingModuleState.NONE, reset.pendingModuleState)
        assertTrue(reset.modulePurgeCompleted)

        // The same projection `refreshStatus()` reaches for a module it cannot query.
        assertEquals(
            ControlStatus.NOT_INSTALLED,
            ModuleEnvironmentSnapshot(
                activeState = ModuleInstallState.MISSING,
                pendingState = PendingModuleState.NONE,
                nfqueueSupported = false,
            ).serviceAccess.statusWithoutQuery(),
        )
    }

    /**
     * The screen follows the one fact it needs: the module directory was measured gone.
     *
     * `purge_report partial 1 1 1 1 0 1` reports exactly that — module directory and private state
     * removed, only the external `/data/adb/zapret2-install.*` staging workspace left — and
     * `commit_purge` returns 1 for it. Gating the screen on the erase verdict, which additionally
     * demands that unrelated workspace, left the user on a READY module with a version and live
     * start/stop/rollback/erase controls whose scripts had been deleted with the directory; the
     * erase button would re-run a `zapret-purge.sh` that no longer exists. The erase verdict itself
     * stays fail-closed, because it is what authorises wiping APK-private data.
     */
    @Test
    fun screenResetFollowsTheMeasuredModuleDirectoryNotTheWholeEraseContract() {
        val externalWorkspaceSurvived = purgeControllerResult(
            purgeReceipt(
                status = "partial",
                processClean = "1",
                firewallClean = "1",
                moduleRemoved = "1",
                stateRemoved = "1",
                externalRemoved = "0",
                rebootRequired = "1",
                diagnostic = "the module stays scheduled for removal at the next reboot, but " +
                    "these remain now: external staging workspace",
            ),
            commandSucceeded = false,
        )

        assertTrue(externalWorkspaceSurvived.moduleDirectoryRemoved)
        assertFalse(externalWorkspaceSurvived.moduleFullyRemoved)
        assertFalse("APK-private data must not be wiped on this receipt", externalWorkspaceSurvived.erased)

        val reset = installedControlState().afterModulePurge(externalWorkspaceSurvived)

        assertEquals(ModuleInstallState.MISSING, reset.moduleInstallState)
        assertEquals(ControlStatus.NOT_INSTALLED, reset.status)
        assertEquals("", reset.moduleVersion)
        assertTrue(reset.modulePurgeCompleted)
        assertFalse(reset.canPurgeModule)
        assertFalse(reset.canFullRollback)
        assertFalse(reset.canStopService)
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

    /**
     * A screen describing a *running* module, which is the only state that populates the fields a
     * purge has to retire: a live process card, its uptime, the counted firewall detail, the
     * capability badge and the module's own diagnostic. A reset asserted against a state that
     * never had them cannot tell a cleared field from one that was never set.
     */
    private fun installedControlState() = ControlUiState(
        isRunning = true,
        status = ControlStatus.RUNNING,
        uptime = "3:12:44",
        autostart = true,
        moduleVersion = "2.1.5",
        canStopService = true,
        iptablesActive = true,
        nfqueueRulesCount = 2,
        nfqueueSupported = true,
        processStats = ProcessStats(
            pid = "4242",
            memory = "8192 KB",
            threads = "3",
            uptime = "3:12:44",
        ),
        iptablesDetail = NetworkStatsManager.IptablesDetail(
            rulesOk = 2,
            rulesTotal = 2,
            ipv4Active = true,
            rulesetVerified = true,
        ),
        moduleDiagnostic = "FIREWALL/POSTCONDITION_FAILED: stale diagnostic from the erased module",
        hasRootAccess = true,
        hasAuthoritativeRuntimeSettings = true,
        moduleInstallState = ModuleInstallState.READY,
    )

    private fun purgeDialogState(
        receipt: List<String>,
        commandSucceeded: Boolean,
        moduleVersion: String = FENCE_FIRST_MODULE_VERSION,
    ): ModulePurgeUiState.Result {
        val result = purgeControllerResult(receipt, commandSucceeded)
        return modulePurgeResultState(
            result,
            sanitizedBoundedUiDiagnostic(result.diagnosticText()),
            moduleVersion,
        )
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

    private companion object {
        /** The oldest module release whose `partial` receipt proves the removal fence is up. */
        const val FENCE_FIRST_MODULE_VERSION = "v2.2.0"

        /** The newest shipped release that prints `partial` when the fence could NOT be published. */
        const val PRE_FENCE_MODULE_VERSION = "v2.1.5"
    }

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

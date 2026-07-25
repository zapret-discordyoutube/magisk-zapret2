package com.zapret2.app.viewmodel

import androidx.lifecycle.SavedStateHandle
import com.zapret2.app.R
import com.zapret2.app.data.ModulePurgeController
import com.zapret2.app.data.ServiceLifecycleController
import com.zapret2.app.ui.UiText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ControlDialogStateModelTest {

    @Test
    fun uiDiagnostics_areRedactedBeforeTheyCanBePersistedOrDisplayed() {
        val diagnostic = sanitizedBoundedUiDiagnostic(
            "token=super-secret host=my-phone 192.168.1.2 " +
                "/data/user/0/com.zapret2.app/cache/update.apk"
        )

        assertFalse(diagnostic.contains("super-secret"))
        assertFalse(diagnostic.contains("my-phone"))
        assertFalse(diagnostic.contains("192.168.1.2"))
        assertFalse(diagnostic.contains("/data/user/0"))
        assertTrue(diagnostic.contains("[REDACTED_SECRET]"))
        assertTrue(diagnostic.contains("[REDACTED_PRIVATE]"))
    }

    @Test
    fun restoredDynamicDiagnostics_areSanitizedAgain() {
        val savedState = SavedStateHandle(
            mapOf(
                "control_dialog_kind" to ControlDialogKind.ERROR.name,
                "control_error_kind" to ControlErrorKind.UPDATE.name,
                "control_error_detail_dynamic" to "token=old-secret host=old-phone",
            ),
        )
        val restored = restoreControlUiState(savedState)

        val details = restored.errorDialog?.details as UiText.Dynamic
        assertFalse(details.value.contains("old-secret"))
        assertFalse(details.value.contains("old-phone"))
        assertTrue(details.value.contains("[REDACTED_SECRET]"))
        assertEquals(details.value, savedState.get<String>("control_error_detail_dynamic"))
    }

    @Test
    fun errorDialog_reconstructionRequiresKindAndDetails() {
        val restored = restoreControlUiState(
            SavedStateHandle(
                mapOf(
                    "control_dialog_kind" to ControlDialogKind.ERROR.name,
                    "control_error_kind" to ControlErrorKind.START_SERVICE.name,
                    "control_error_detail_resource" to R.string.control_unknown_error,
                ),
            ),
        )

        assertEquals(ControlDialogKind.ERROR, restored.pendingDialog)
        assertEquals(ControlErrorKind.START_SERVICE, restored.errorDialog?.kind)
        assertEquals(
            UiText.Resource(R.string.control_unknown_error),
            restored.errorDialog?.details,
        )
    }

    @Test
    fun errorDialog_reconstructionRejectsUnknownResourceIds() {
        val savedState = SavedStateHandle(
            mapOf(
                "control_dialog_kind" to ControlDialogKind.ERROR.name,
                "control_error_kind" to ControlErrorKind.START_SERVICE.name,
                "control_error_detail_resource" to Int.MAX_VALUE,
                "control_error_detail_dynamic" to "must not bypass the resource allowlist",
            ),
        )
        val restored = restoreControlUiState(savedState)

        assertEquals(
            UiText.Resource(R.string.control_unknown_error),
            restored.errorDialog?.details,
        )
        assertFalse(savedState.contains("control_error_detail_dynamic"))
    }

    @Test
    fun incompleteErrorDialog_isDroppedAndItsPayloadIsCleared() {
        val savedState = SavedStateHandle(
            mapOf(
                "control_dialog_kind" to ControlDialogKind.ERROR.name,
                "control_error_detail_dynamic" to "stale diagnostic",
            ),
        )

        val restored = restoreControlUiState(savedState)

        assertNull(restored.pendingDialog)
        assertNull(restored.errorDialog)
        assertFalse(savedState.contains("control_dialog_kind"))
        assertFalse(savedState.contains("control_error_detail_dynamic"))
    }

    @Test
    fun fullRollbackConfirmationAndResultRemainTypedAcrossReconstruction() {
        val confirmation = restoreControlUiState(
            SavedStateHandle(
                mapOf("control_dialog_kind" to ControlDialogKind.FULL_ROLLBACK_CONFIRM.name),
            ),
        )
        assertEquals(FullRollbackUiState.Confirmation, confirmation.fullRollback)

        val result = restoreControlUiState(
            SavedStateHandle(
                mapOf(
                    "control_dialog_kind" to ControlDialogKind.FULL_ROLLBACK_RESULT.name,
                    "control_full_rollback_outcome" to
                        ServiceLifecycleController.FullRollbackOutcome.PARTIAL.name,
                    "control_full_rollback_reboot_required" to true,
                    "control_full_rollback_diagnostic" to "firewall cleanup incomplete",
                ),
            ),
        )
        val rollback = result.fullRollback as FullRollbackUiState.Result
        assertEquals(ServiceLifecycleController.FullRollbackOutcome.PARTIAL, rollback.outcome)
        assertEquals(true, rollback.rebootRequired)
        assertEquals("firewall cleanup incomplete", rollback.diagnostic)
        // A partial receipt claims nothing on its own; only the persisted verdict can.
        assertFalse(rollback.rolledBack)
        assertFalse(rollback.unverifiedCleanup)
    }

    @Test
    fun rolledBackPartialResultSurvivesRecreationAsDoneWithItsReservation() {
        val restored = restoreControlUiState(
            SavedStateHandle(
                mapOf(
                    "control_dialog_kind" to ControlDialogKind.FULL_ROLLBACK_RESULT.name,
                    "control_full_rollback_outcome" to
                        ServiceLifecycleController.FullRollbackOutcome.PARTIAL.name,
                    "control_full_rollback_rolled_back" to true,
                    "control_full_rollback_reboot_required" to true,
                    "control_full_rollback_diagnostic" to "the IPv6 mangle table could not be read",
                ),
            ),
        )

        val rollback = restored.fullRollback as FullRollbackUiState.Result
        assertTrue(rollback.rolledBack)
        assertTrue(rollback.unverifiedCleanup)
    }

    @Test
    fun persistedRolledBackFlag_cannotUpgradeAnOutcomeThatNeverRolledBack() {
        listOf(
            ServiceLifecycleController.FullRollbackOutcome.ERROR,
            ServiceLifecycleController.FullRollbackOutcome.BLOCKED,
            ServiceLifecycleController.FullRollbackOutcome.VERIFICATION_FAILED,
            ServiceLifecycleController.FullRollbackOutcome.INVALID_PROTOCOL,
            ServiceLifecycleController.FullRollbackOutcome.COMMAND_FAILED,
        ).forEach { outcome ->
            val restored = restoreControlUiState(
                SavedStateHandle(
                    mapOf(
                        "control_dialog_kind" to ControlDialogKind.FULL_ROLLBACK_RESULT.name,
                        "control_full_rollback_outcome" to outcome.name,
                        "control_full_rollback_rolled_back" to true,
                        "control_full_rollback_reboot_required" to true,
                        "control_full_rollback_diagnostic" to "stale",
                    ),
                ),
            )

            val rollback = restored.fullRollback as FullRollbackUiState.Result
            assertFalse(outcome.name, rollback.rolledBack)
            assertFalse(outcome.name, rollback.unverifiedCleanup)
        }
    }

    @Test
    fun rolledBackResultReportsSuccessAndReservesOnlyTheUnverifiedPartialStep() {
        val partial = FullRollbackUiState.Result(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            rolledBack = true,
            rebootRequired = true,
            diagnostic = "the IPv6 mangle table could not be queried",
        )

        assertTrue(partial.unverifiedCleanup)
        assertFalse(
            partial.copy(outcome = ServiceLifecycleController.FullRollbackOutcome.COMPLETE)
                .unverifiedCleanup,
        )
        assertFalse(partial.copy(rolledBack = false).unverifiedCleanup)
    }

    @Test
    fun incompleteRollbackResult_isDroppedInsteadOfBlockingTheControlScreen() {
        val savedState = SavedStateHandle(
            mapOf(
                "control_dialog_kind" to ControlDialogKind.FULL_ROLLBACK_RESULT.name,
                "control_full_rollback_outcome" to "corrupt",
                "control_full_rollback_rolled_back" to true,
                "control_full_rollback_reboot_required" to true,
                "control_full_rollback_diagnostic" to "stale",
            ),
        )

        val restored = restoreControlUiState(savedState)

        assertNull(restored.pendingDialog)
        assertEquals(FullRollbackUiState.Idle, restored.fullRollback)
        assertFalse(savedState.contains("control_dialog_kind"))
        assertFalse(savedState.contains("control_full_rollback_outcome"))
        assertFalse(savedState.contains("control_full_rollback_rolled_back"))
        assertFalse(savedState.contains("control_full_rollback_reboot_required"))
        assertFalse(savedState.contains("control_full_rollback_diagnostic"))
    }

    @Test
    fun modulePurgeConfirmationAndResultRemainTypedAcrossReconstruction() {
        val confirmation = restoreControlUiState(
            SavedStateHandle(
                mapOf("control_dialog_kind" to ControlDialogKind.MODULE_PURGE_CONFIRM.name),
            ),
        )
        assertEquals(ModulePurgeUiState.Confirmation, confirmation.modulePurge)

        val result = restoreControlUiState(
            SavedStateHandle(
                mapOf(
                    "control_dialog_kind" to ControlDialogKind.MODULE_PURGE_RESULT.name,
                    "control_module_purge_outcome" to ModulePurgeController.Outcome.PARTIAL.name,
                    "control_module_purge_reboot_required" to true,
                    "control_module_purge_diagnostic" to "state cleanup incomplete",
                ),
            ),
        )
        val purge = result.modulePurge as ModulePurgeUiState.Result
        assertEquals(ModulePurgeController.Outcome.PARTIAL, purge.outcome)
        assertTrue(purge.rebootRequired)
        assertEquals("state cleanup incomplete", purge.diagnostic)
        // Only a failed erase is persisted, so a restored result never claims the module is gone.
        assertFalse(purge.erased)
        assertFalse(purge.unverifiedCleanup)
    }

    @Test
    fun erasedPurgeResultReportsSuccessAndReservesOnlyTheUnverifiedPartialStep() {
        val partial = ModulePurgeUiState.Result(
            outcome = ModulePurgeController.Outcome.PARTIAL,
            erased = true,
            rebootRequired = true,
            diagnostic = "the IPv6 ruleset could not be verified",
        )

        assertTrue(partial.unverifiedCleanup)
        assertFalse(partial.copy(outcome = ModulePurgeController.Outcome.COMPLETE).unverifiedCleanup)
        assertFalse(partial.copy(erased = false).unverifiedCleanup)
    }

    /**
     * The purge reservation is the IPv6 sentence on the result dialog, and it must describe the
     * one fact the module left unproven rather than any outcome that merely is not COMPLETE. The
     * dialog state carries no firewall field, so the guarantee has to survive the whole path from
     * receipt to screen: every erase the controller admits under a non-COMPLETE outcome withheld
     * `firewall_clean`, and no other erase may show the sentence.
     */
    @Test
    fun purgeReservationAppearsForExactlyTheFirewallFactTheReceiptWithheld() {
        val statuses = ModulePurgeController.Status.entries.map(
            ModulePurgeController.Status::wireValue,
        )
        ModulePurgeController.Outcome.entries.forEach { outcome ->
            statuses.forEach { status ->
                listOf(true, false).forEach { firewallClean ->
                    val result = purgeControllerResult(outcome, status, firewallClean)
                    val dialog = ModulePurgeUiState.Result(
                        outcome = result.outcome,
                        erased = result.erased,
                        rebootRequired = result.rebootRequired,
                        diagnostic = "",
                    )
                    val label = "$outcome/$status/firewallClean=$firewallClean"

                    assertEquals(label, result.erased && !firewallClean, dialog.unverifiedCleanup)
                }
            }
        }
    }

    /**
     * The same guarantee for the rollback the purge is modelled on: its reservation is reachable
     * only through a receipt that withheld `firewall_clean`, and the one outcome that skips the
     * receipt fields — COMPLETE — is minted only for a receipt that proved the firewall clean.
     */
    @Test
    fun rollbackReservationAppearsForExactlyTheFirewallFactTheReceiptWithheld() {
        ServiceLifecycleController.FullRollbackStatus.entries.forEach { status ->
            listOf(true, false).forEach { firewallClean ->
                val report = rollbackReport(status, firewallClean)
                assertEquals(
                    "$status/firewallClean=$firewallClean",
                    status == ServiceLifecycleController.FullRollbackStatus.COMPLETE &&
                        firewallClean,
                    report.satisfiesCompleteContract,
                )
                ServiceLifecycleController.FullRollbackOutcome.entries.forEach { outcome ->
                    val result = ServiceLifecycleController.FullRollbackResult(
                        outcome = outcome,
                        report = report,
                    )
                    val dialog = FullRollbackUiState.Result(
                        outcome = result.outcome,
                        rolledBack = result.rolledBack,
                        rebootRequired = result.rebootRequired,
                        diagnostic = "",
                    )
                    val label = "$outcome/$status/firewallClean=$firewallClean"

                    if (dialog.unverifiedCleanup) assertFalse(label, firewallClean)
                }
            }
        }
    }

    private fun rollbackReport(
        status: ServiceLifecycleController.FullRollbackStatus,
        firewallClean: Boolean,
    ) = ServiceLifecycleController.FullRollbackReport(
        status = status,
        processClean = true,
        firewallClean = firewallClean,
        rollbackArmed = true,
        hostsPreserved = true,
        rebootRequired = true,
        userDataPreserved = true,
        legacyAmbiguous = false,
        diagnostic = "",
    )

    private fun purgeControllerResult(
        outcome: ModulePurgeController.Outcome,
        status: String,
        firewallClean: Boolean,
    ): ModulePurgeController.Result {
        val lines = listOf(
            "Z2_PURGE_VERSION=1",
            "Z2_PURGE_STATUS=$status",
            "Z2_PURGE_PROCESS_CLEAN=1",
            "Z2_PURGE_FIREWALL_CLEAN=${if (firewallClean) 1 else 0}",
            "Z2_PURGE_MODULE_REMOVED=1",
            "Z2_PURGE_STATE_REMOVED=1",
            "Z2_PURGE_EXTERNAL_REMOVED=1",
            "Z2_PURGE_APK_TOUCHED=0",
            "Z2_PURGE_REBOOT_REQUIRED=1",
            "Z2_PURGE_DIAGNOSTIC=receipt",
            "Z2_PURGE_COMPLETE=1",
        )
        val parsed = ModulePurgeController.parseReportOutput(lines)
            as ModulePurgeController.ParseResult.Valid
        return ModulePurgeController.Result(
            outcome = outcome,
            report = parsed.value,
            command = ServiceLifecycleController.CommandResult(success = true, exitCode = 0),
        )
    }

    @Test
    fun persistedModulePurgeProgressRestoresWithoutConfirmationAndWinsNoRollbackState() {
        val restored = restoreControlUiState(
            SavedStateHandle(mapOf("control_module_purge_in_progress" to true)),
        )

        assertEquals(ModulePurgeUiState.InProgress, restored.modulePurge)
        assertEquals(FullRollbackUiState.Idle, restored.fullRollback)
        assertNull(restored.pendingDialog)
    }

    @Test
    fun lastResultRestoresIndependentlyFromDialogAndRejectsCorruption() {
        val handle = SavedStateHandle(
            mapOf(
                "control_dialog_kind" to ControlDialogKind.ERROR.name,
                "control_last_result" to ControlLastResult.UPDATE_REBOOT_REQUIRED.name,
            ),
        )

        assertEquals(ControlLastResult.UPDATE_REBOOT_REQUIRED, restoreControlLastResult(handle))
        handle.remove<String>("control_dialog_kind")
        assertEquals(ControlLastResult.UPDATE_REBOOT_REQUIRED, restoreControlLastResult(handle))

        handle["control_last_result"] = "corrupt"
        assertNull(restoreControlLastResult(handle))
        assertFalse(handle.contains("control_last_result"))
    }

    @Test
    fun persistedFullRollbackProgress_restoresInProgressWithoutConfirmation() {
        val restored = restoreControlUiState(
            SavedStateHandle(
                mapOf(
                    "control_dialog_kind" to ControlDialogKind.FULL_ROLLBACK_CONFIRM.name,
                    "control_full_rollback_in_progress" to true,
                ),
            ),
        )

        assertEquals(FullRollbackUiState.InProgress, restored.fullRollback)
        assertNull(restored.pendingDialog)
    }

    @Test
    fun restoredProgress_isAutomaticallyEligibleExactlyOnce() {
        val savedState = SavedStateHandle(
            mapOf("control_full_rollback_in_progress" to true),
        )
        val restored = restoreControlUiState(savedState)
        val coordinator = FullRollbackOperationCoordinator(savedState)
        var launches = 0

        assertTrue(
            coordinator.tryBegin(FullRollbackLaunchReason.RESTORED, restored) { launches += 1 },
        )
        assertFalse(
            coordinator.tryBegin(FullRollbackLaunchReason.RESTORED, restored) { launches += 1 },
        )
        assertEquals(1, launches)
    }

    @Test
    fun duplicateConfirmedRollback_isBlockedAfterProgressIsPersisted() {
        val savedState = SavedStateHandle(
            mapOf("control_dialog_kind" to ControlDialogKind.FULL_ROLLBACK_CONFIRM.name),
        )
        val state = ControlUiState(
            status = ControlStatus.RUNNING,
            hasRootAccess = true,
            moduleInstallState = com.zapret2.app.data.ModuleInstallState.READY,
            fullRollback = FullRollbackUiState.Confirmation,
        )
        val coordinator = FullRollbackOperationCoordinator(savedState)
        var launches = 0

        assertTrue(
            coordinator.tryBegin(FullRollbackLaunchReason.CONFIRMED, state) {
                assertEquals(true, savedState["control_full_rollback_in_progress"])
                launches += 1
            },
        )
        assertFalse(
            coordinator.tryBegin(FullRollbackLaunchReason.CONFIRMED, state) { launches += 1 },
        )
        assertEquals(1, launches)
    }

    @Test
    fun terminalResult_clearsProgressOnlyAfterCompleteTerminalPersistence() {
        val savedState = SavedStateHandle(
            mapOf("control_full_rollback_in_progress" to true),
        )
        var terminalObserved = false
        val coordinator = FullRollbackOperationCoordinator(
            savedStateHandle = savedState,
            onTerminalPersisted = {
                terminalObserved = true
                assertEquals(true, savedState["control_full_rollback_in_progress"])
                assertEquals(
                    ServiceLifecycleController.FullRollbackOutcome.PARTIAL.name,
                    savedState["control_full_rollback_outcome"],
                )
                assertEquals(false, savedState["control_full_rollback_rolled_back"])
                assertEquals(true, savedState["control_full_rollback_reboot_required"])
                assertEquals("cleanup incomplete", savedState["control_full_rollback_diagnostic"])
                assertEquals(
                    ControlDialogKind.FULL_ROLLBACK_RESULT.name,
                    savedState["control_dialog_kind"],
                )
                assertEquals(
                    ControlLastResult.ROLLBACK_FAILED.name,
                    savedState["control_last_result"],
                )
                assertTrue(
                    restoreControlUiState(savedState).fullRollback is FullRollbackUiState.Result,
                )
            },
        )
        val result = ServiceLifecycleController.FullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            report = ServiceLifecycleController.FullRollbackReport(
                status = ServiceLifecycleController.FullRollbackStatus.PARTIAL,
                processClean = false,
                firewallClean = false,
                rollbackArmed = true,
                hostsPreserved = true,
                rebootRequired = true,
                userDataPreserved = true,
                legacyAmbiguous = false,
                diagnostic = "cleanup incomplete",
            ),
        )

        coordinator.persistTerminal(
            result = result,
            diagnostic = "cleanup incomplete",
            lastResult = ControlLastResult.ROLLBACK_FAILED,
        )

        assertTrue(terminalObserved)
        assertNull(savedState.get<Boolean>("control_full_rollback_in_progress"))
    }

    @Test
    fun rollbackThatOnlyLeftItsFirewallCheckUnverified_isPersistedAndRestoredAsDone() {
        val savedState = SavedStateHandle(mapOf("control_full_rollback_in_progress" to true))
        val result = ServiceLifecycleController.FullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            // The observation the module really answers with here: the receipt it just published
            // denies the status script its fast path, so the script reports an owned, degraded,
            // never fully stopped state. A synthetic stopped status would not exercise this.
            serviceStatus = ipv6UnverifiedRollbackStatus(),
            report = ServiceLifecycleController.FullRollbackReport(
                status = ServiceLifecycleController.FullRollbackStatus.PARTIAL,
                processClean = true,
                firewallClean = false,
                rollbackArmed = true,
                hostsPreserved = true,
                rebootRequired = true,
                userDataPreserved = true,
                legacyAmbiguous = false,
                diagnostic = "the IPv6 mangle table could not be queried",
            ),
        )
        assertFalse(result.serviceStatus?.fullyStopped == true)
        assertTrue(result.rolledBack)

        FullRollbackOperationCoordinator(savedState).persistTerminal(
            result = result,
            diagnostic = "the IPv6 mangle table could not be queried",
            lastResult = ControlLastResult.ROLLBACK_COMPLETED,
        )

        assertEquals(true, savedState["control_full_rollback_rolled_back"])
        assertEquals(
            ControlLastResult.ROLLBACK_COMPLETED.name,
            savedState["control_last_result"],
        )
        val restored = restoreControlUiState(savedState).fullRollback as FullRollbackUiState.Result
        assertTrue(restored.rolledBack)
        assertTrue(restored.unverifiedCleanup)
    }

    @Test
    fun cancelledAttempt_retainsProgressForRecreationAndResume() {
        val savedState = SavedStateHandle(
            mapOf("control_dialog_kind" to ControlDialogKind.FULL_ROLLBACK_CONFIRM.name),
        )
        val confirmation = ControlUiState(
            status = ControlStatus.STOPPED,
            hasRootAccess = true,
            moduleInstallState = com.zapret2.app.data.ModuleInstallState.READY,
            fullRollback = FullRollbackUiState.Confirmation,
        )
        val originalCoordinator = FullRollbackOperationCoordinator(savedState)
        assertTrue(
            originalCoordinator.tryBegin(FullRollbackLaunchReason.CONFIRMED, confirmation) {},
        )

        originalCoordinator.finishAttempt()

        assertEquals(true, savedState["control_full_rollback_in_progress"])
        val restored = restoreControlUiState(savedState)
        assertEquals(FullRollbackUiState.InProgress, restored.fullRollback)
        var resumed = 0
        assertTrue(
            FullRollbackOperationCoordinator(savedState).tryBegin(
                FullRollbackLaunchReason.RESTORED,
                restored,
            ) { resumed += 1 },
        )
        assertEquals(1, resumed)
    }

    /**
     * `zapret-status.sh --machine-v6` right after a rollback that finished everything but could
     * not re-read the IPv6 family: the published receipt (`ruleset_verified=0`, `ipv6_active=1`)
     * denies the stopped fast path, `IPV6_UNKNOWN=1` forces `Z2_OWNED=1`, and the payload is
     * graded `degraded` with exit 2.
     */
    private fun ipv6UnverifiedRollbackStatus(): ServiceLifecycleController.ServiceStatus =
        ServiceLifecycleController.parseStatusCommandResult(
            ServiceLifecycleController.CommandResult(
                success = false,
                exitCode = 2,
                stdout = listOf(
                    "Z2_PROTOCOL=6",
                    "Z2_STATUS=degraded",
                    "Z2_OWNED=1",
                    "Z2_PROCESS=0",
                    "Z2_ACTIVE=0",
                    "Z2_PID=",
                    "Z2_PID_VERIFIED=0",
                    "Z2_PID_STARTTIME=",
                    "Z2_OWNER_GENERATION=",
                    "Z2_OWNER_METADATA_VERIFIED=0",
                    "Z2_QNUM=200",
                    "Z2_IPV4=0",
                    "Z2_IPV6=0",
                    "Z2_RULES=0",
                    "Z2_EXPECTED_RULES=0",
                    "Z2_IPV4_RULES=0",
                    "Z2_IPV6_RULES=0",
                    "Z2_RULESET_VERIFIED=0",
                    "Z2_NFQUEUE=1",
                    "Z2_QUEUE_BYPASS=1",
                    "Z2_UPDATE_BLOCKED=0",
                    "Z2_UNINSTALL_TOMBSTONE=0",
                    "Z2_LIFECYCLE_STATE=idle",
                    "Z2_LIFECYCLE_OWNER_KIND=none",
                    "Z2_CHAINS=0",
                    "Z2_ANCHORS=0",
                    "Z2_ERROR_SCHEMA=1",
                    "Z2_ERROR_STATUS=ERROR",
                    "Z2_ERROR_DOMAIN=STATUS",
                    "Z2_ERROR_CODE=STATUS_DEGRADED",
                    "Z2_ERROR_STAGE=STATUS_QUERY",
                    "Z2_ERROR_DETAIL=Service state is degraded; " +
                        "inspect the lifecycle log for full details",
                    "Z2_COMPLETE=1",
                ),
            ),
        )
}

package com.zapret2.app.viewmodel

import com.zapret2.app.R
import com.zapret2.app.data.LifecycleErrorContract
import com.zapret2.app.data.ModuleInstallState
import com.zapret2.app.data.ModuleMutationState
import com.zapret2.app.data.ModuleEnvironmentSnapshot
import com.zapret2.app.data.PendingModuleState
import com.zapret2.app.data.ServiceLifecycleController
import com.zapret2.app.data.runningMarkedForRemovalStatusLines
import com.zapret2.app.data.tombstoneOwnedQuietStatusLines
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModuleServiceStatusPolicyTest {

    @Test
    fun activeRuntime_isTheOnlyStateThatPermitsStatusScriptExecution() {
        listOf(ModuleInstallState.READY, ModuleInstallState.DISABLED).forEach { active ->
            assertNull(
                statusWithoutQuery(
                    active,
                    PendingModuleState.NONE,
                ),
            )
        }
    }

    @Test
    fun stagedFreshInstall_requiresRebootWithoutCallingMissingStatusScript() {
        assertEquals(
            ControlStatus.REBOOT_REQUIRED,
            statusWithoutQuery(
                ModuleInstallState.MISSING,
                PendingModuleState.READY,
            ),
        )
    }

    @Test
    fun absentAndBrokenInstallations_haveSpecificStatus() {
        assertEquals(
            ControlStatus.NOT_INSTALLED,
            statusWithoutQuery(
                ModuleInstallState.MISSING,
                PendingModuleState.NONE,
            ),
        )
        listOf(
            ModuleInstallState.PARTIAL,
            ModuleInstallState.UNREADABLE,
            ModuleInstallState.UNSUPPORTED_ABI,
        ).forEach { active ->
            assertEquals(
                ControlStatus.MODULE_NOT_READY,
                statusWithoutQuery(
                    active,
                    PendingModuleState.NONE,
                ),
            )
        }
    }

    @Test
    fun pendingUpdate_doesNotDisableHealthyActiveRuntime() {
        assertNull(
            statusWithoutQuery(
                ModuleInstallState.READY,
                PendingModuleState.READY,
            ),
        )
        val state = ControlUiState(
            moduleInstallState = ModuleInstallState.READY,
            pendingModuleState = PendingModuleState.READY,
        )
        assertTrue(state.isModuleOperational)
        assertEquals(R.string.control_module_state_update_reboot, state.moduleStateLabelRes)
    }

    @Test
    fun invalidPendingGeneration_isNotReadyWhenNoActiveGenerationExists() {
        listOf(
            PendingModuleState.PARTIAL,
            PendingModuleState.UNSUPPORTED_ABI,
            PendingModuleState.UNREADABLE,
        ).forEach { pending ->
            assertEquals(
                ControlStatus.MODULE_NOT_READY,
                statusWithoutQuery(ModuleInstallState.MISSING, pending),
            )
        }
    }

    @Test
    fun lifecycleState_isAnIndependentOperationalFence() {
        val state = ControlUiState(
            moduleInstallState = ModuleInstallState.READY,
            moduleMutationState = ModuleMutationState.IN_PROGRESS,
        )

        assertFalse(state.isModuleOperational)
        assertEquals(R.string.control_service_lifecycle_busy, state.moduleStateLabelRes)
        assertNull(statusWithoutQuery(state.moduleInstallState, state.pendingModuleState))
        assertEquals(
            ModuleMutationState.IN_PROGRESS,
            ServiceLifecycleController.LifecycleState.ACTIVE.toModuleMutationState(),
        )
        assertEquals(
            ModuleMutationState.IN_PROGRESS,
            ServiceLifecycleController.LifecycleState.OWNED.toModuleMutationState(),
        )
        assertEquals(
            ModuleMutationState.BLOCKED,
            ServiceLifecycleController.LifecycleState.AMBIGUOUS.toModuleMutationState(),
        )
        assertEquals(
            ControlStatus.LIFECYCLE_BUSY,
            projectedControlStatus(
                serviceStatus = ServiceLifecycleController.ServiceStatus(
                    rootGranted = true,
                    processRunning = false,
                    lifecycleState = ServiceLifecycleController.LifecycleState.ACTIVE,
                ),
                canStopService = false,
            ),
        )
        val active = ServiceLifecycleController.ServiceStatus(
            rootGranted = true,
            processRunning = false,
            lifecycleState = ServiceLifecycleController.LifecycleState.ACTIVE,
            lifecycleError = LifecycleErrorContract.error(
                domain = "LIFECYCLE",
                code = "LIFECYCLE_ACTIVE",
                stage = "LIFECYCLE_OBSERVE",
                detail = "Another verified lifecycle owner is active",
            ),
        )
        assertNull(projectedLifecycleDiagnostic(active))
    }

    /**
     * A completed stop is reported as done in both shapes the module can report it in, and the
     * one check it could not repeat is named rather than dropped or turned into a failure.
     *
     * Both payloads below are what `zapret-stop.sh` really emits: the ordinary teardown proves
     * every family and certifies the ruleset, while the teardown on a device whose IPv6 mangle
     * table cannot be read tears the same rules down, measures the same zeroes, and withholds
     * only `Z2_RULESET_VERIFIED`.
     */
    @Test
    fun stopThatCouldNotRereadTheIpv6Family_isReportedDoneWithTheCheckNamed() {
        val proven = stopReceiptStatus(rulesetVerified = true)
        val reserved = stopReceiptStatus(rulesetVerified = false)

        assertTrue(proven.fullyStopped)
        assertTrue(reserved.fullyStopped)
        assertEquals(
            ControlLastResult.SERVICE_STOPPED,
            stoppedServiceResult(proven.rulesetVerified),
        )
        assertEquals(
            R.string.control_service_stopped_result,
            stoppedServiceResult(proven.rulesetVerified).messageRes,
        )
        assertEquals(
            ControlLastResult.SERVICE_STOPPED_IPV6_UNVERIFIED,
            stoppedServiceResult(reserved.rulesetVerified),
        )
        assertEquals(
            R.string.control_service_stopped_ipv6_unverified,
            stoppedServiceResult(reserved.rulesetVerified).messageRes,
        )
    }

    /**
     * The `emit_committed_status_v6 stopped idle none` receipt, with `Z2_RULESET_VERIFIED`
     * carrying `STATUS_RULESET_VERIFIED` exactly as `write_stop_status stopped` recorded it.
     */
    private fun stopReceiptStatus(
        rulesetVerified: Boolean,
    ): ServiceLifecycleController.ServiceStatus = requireNotNull(
        ServiceLifecycleController.parseLifecycleReceipt(
            ServiceLifecycleController.CommandResult(
                success = true,
                exitCode = 0,
                stdout = listOf(
                    "Z2_PROTOCOL=6",
                    "Z2_STATUS=stopped",
                    "Z2_OWNED=0",
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
                    "Z2_RULESET_VERIFIED=${if (rulesetVerified) 1 else 0}",
                    "Z2_NFQUEUE=0",
                    "Z2_QUEUE_BYPASS=0",
                    "Z2_UPDATE_BLOCKED=0",
                    "Z2_UNINSTALL_TOMBSTONE=0",
                    "Z2_LIFECYCLE_STATE=idle",
                    "Z2_LIFECYCLE_OWNER_KIND=none",
                    "Z2_CHAINS=0",
                    "Z2_ANCHORS=0",
                    "Z2_ERROR_SCHEMA=1",
                    "Z2_ERROR_STATUS=OK",
                    "Z2_ERROR_DOMAIN=NONE",
                    "Z2_ERROR_STAGE=NONE",
                    "Z2_ERROR_CODE=NONE",
                    "Z2_ERROR_DETAIL=",
                    "Z2_COMPLETE=1",
                ),
            ),
        ),
    ) { "the module's own stop receipt must parse" }

    /**
     * The recovery actions must survive the module being marked for removal.
     *
     * `canPurgeModule` and `canFullRollback` both require the projected status to be one of
     * RUNNING/DEGRADED/STOPPED. Rejecting either payload the module prints in that state graded it
     * `unknown`, which carried "Invalid or incomplete Zapret2 machine status output" into
     * `ServiceStatus.error`, which `projectedControlStatus` turns into UNAVAILABLE — switching both
     * actions off in the exact state where erasing or rolling back is the way out.
     */
    @Test
    fun moduleMarkedForRemoval_keepsEraseAndRollbackReachableInBothPayloadsItPrints() {
        mapOf(
            "running service" to runningMarkedForRemovalStatusLines(),
            "quiet teardown owned only by the removal mark" to tombstoneOwnedQuietStatusLines(),
        ).forEach { (label, lines) ->
            val serviceStatus = ServiceLifecycleController.parseStatusOutput(lines)

            assertTrue(label, serviceStatus.metadataComplete)
            assertTrue(label, serviceStatus.uninstallTombstone)
            assertNull("$label must not be graded as a broken payload", serviceStatus.error)

            val state = ControlUiState(
                status = projectedControlStatus(
                    serviceStatus = serviceStatus,
                    canStopService = serviceStatus.provesLiveRuntime,
                ),
                hasRootAccess = true,
                canStopService = serviceStatus.provesLiveRuntime,
                moduleInstallState = ModuleInstallState.READY,
                moduleMutationState = ModuleMutationState.IDLE,
            )

            assertNotEquals(label, ControlStatus.UNAVAILABLE, state.status)
            assertTrue("$label must keep the erase action reachable", state.canPurgeModule)
            assertTrue("$label must keep the rollback action reachable", state.canFullRollback)
        }
    }

    private fun statusWithoutQuery(
        activeState: ModuleInstallState,
        pendingState: PendingModuleState,
    ): ControlStatus? = ModuleEnvironmentSnapshot(
        activeState = activeState,
        pendingState = pendingState,
        nfqueueSupported = true,
    ).serviceAccess.statusWithoutQuery()
}

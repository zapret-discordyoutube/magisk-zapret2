package com.zapret2.app.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ServiceLifecycleControllerTest {

    @Test
    fun rootAccessClassifier_distinguishesGrantedDeniedMissingTimeoutAndShellFailure() {
        val granted = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(success = true),
            uid = "0",
        )
        val deniedByUid = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(success = true),
            uid = "2000",
        )
        val deniedByManager = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(
                success = false,
                stderr = listOf("Permission denied by root manager"),
            ),
            uid = null,
        )
        val missingManager = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(
                success = false,
                stderr = listOf("su: not found"),
            ),
            uid = null,
        )
        val timedOut = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(
                success = false,
                error = "Root request timed out",
            ),
            uid = null,
        )
        val shellFailure = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(
                success = false,
                error = "Root transport disconnected",
            ),
            uid = null,
        )
        val deniedWithoutShellDiagnostic = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(
                success = false,
                error = "Root command exited unsuccessfully",
            ),
            uid = null,
            appGrantedRoot = false,
        )
        val failedGrantedShell = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(
                success = false,
                error = "Root shell disconnected",
            ),
            uid = null,
            appGrantedRoot = true,
        )
        val malformedUid = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(success = true),
            uid = "root",
        )
        val busy = ServiceLifecycleController.classifyRootAccess(
            ServiceLifecycleController.CommandResult(
                success = false,
                lifecycleError = LifecycleErrorContract.rootQueueBusy,
            ),
            uid = null,
        )

        assertEquals(ServiceLifecycleController.RootAccessState.GRANTED, granted.state)
        assertEquals(ServiceLifecycleController.RootAccessState.DENIED, deniedByUid.state)
        assertEquals(ServiceLifecycleController.RootAccessState.DENIED, deniedByManager.state)
        assertEquals(
            ServiceLifecycleController.RootAccessState.MANAGER_UNAVAILABLE,
            missingManager.state,
        )
        assertEquals(ServiceLifecycleController.RootAccessState.TIMEOUT, timedOut.state)
        assertEquals(LifecycleErrorContract.ROOT_COMMAND_TIMEOUT, timedOut.lifecycleError?.code)
        assertEquals(ServiceLifecycleController.RootAccessState.SHELL_FAILURE, shellFailure.state)
        assertEquals(LifecycleErrorContract.ROOT_SHELL_FAILED, shellFailure.lifecycleError?.code)
        assertEquals(
            ServiceLifecycleController.RootAccessState.DENIED,
            deniedWithoutShellDiagnostic.state,
        )
        assertEquals(
            "Root access was not granted by the root manager",
            deniedWithoutShellDiagnostic.error,
        )
        assertEquals(LifecycleErrorContract.ROOT_DENIED, deniedWithoutShellDiagnostic.lifecycleError?.code)
        assertEquals(
            ServiceLifecycleController.RootAccessState.SHELL_FAILURE,
            failedGrantedShell.state,
        )
        assertEquals(ServiceLifecycleController.RootAccessState.SHELL_FAILURE, malformedUid.state)
        assertEquals(ServiceLifecycleController.RootAccessState.BUSY, busy.state)
        assertEquals(LifecycleErrorContract.ROOT_COMMAND_QUEUE_BUSY, busy.lifecycleError?.code)
    }

    @Test
    fun statusCommandResult_requiresExactPayloadExitCodeMapping() {
        val healthy = ServiceLifecycleController.parseStatusCommandResult(
            ServiceLifecycleController.CommandResult(
                success = true,
                stdout = healthyStatusLines(),
                exitCode = 0,
            )
        )
        val stopped = ServiceLifecycleController.parseStatusCommandResult(
            ServiceLifecycleController.CommandResult(
                success = false,
                stdout = stoppedStatusLines(),
                exitCode = 1,
            )
        )
        val mismatched = ServiceLifecycleController.parseStatusCommandResult(
            ServiceLifecycleController.CommandResult(
                success = true,
                stdout = stoppedStatusLines(),
                exitCode = 0,
            )
        )
        val lifecycleBarrier = ServiceLifecycleController.parseStatusCommandResult(
            ServiceLifecycleController.CommandResult(
                success = false,
                stdout = lifecycleBarrierStatusLines(
                    lifecycleState = "active",
                    ownerKind = "shell",
                    errorCode = "LIFECYCLE_ACTIVE",
                ),
                exitCode = 2,
            ),
        )

        assertTrue(healthy.healthy)
        assertTrue(stopped.fullyStopped)
        assertTrue(lifecycleBarrier.metadataComplete)
        assertEquals(
            ServiceLifecycleController.LifecycleState.ACTIVE,
            lifecycleBarrier.lifecycleState,
        )
        assertFalse(mismatched.metadataComplete)
        assertEquals("unknown", mismatched.declaredStatus)
        assertEquals(0, ServiceLifecycleController.statusExitCode("ok"))
        assertEquals(1, ServiceLifecycleController.statusExitCode("stopped"))
        assertEquals(2, ServiceLifecycleController.statusExitCode("degraded"))
    }

    @Test
    fun lifecycleReceipt_acceptsVerifiedRunningAndStoppedCommitsWithCommandExitZero() {
        val running = ServiceLifecycleController.parseLifecycleReceipt(
            ServiceLifecycleController.CommandResult(
                success = true,
                stdout = versionSixStatusLines(
                    healthyStatusLines(),
                    lifecycleState = "owned",
                    ownerKind = "android-mutation",
                    chains = 4,
                    anchors = 4,
                ),
                exitCode = 0,
            ),
        )
        val stopped = ServiceLifecycleController.parseLifecycleReceipt(
            ServiceLifecycleController.CommandResult(
                success = true,
                stdout = versionSixStatusLines(
                    stoppedStatusLines(),
                    lifecycleState = "idle",
                    chains = 0,
                    anchors = 0,
                ),
                exitCode = 0,
            ),
        )

        assertTrue(running?.healthy == true)
        assertTrue(stopped?.fullyStopped == true)
    }

    @Test
    fun indeterminateLifecycleResult_commitsOnlyTheExactRequestedRunningGeneration() {
        val expected = ServiceLifecycleController.parseStatusOutput(
            versionSixStatusLines(
                healthyStatusLines().map {
                    if (it.startsWith("Z2_OWNER_GENERATION=")) {
                        "Z2_OWNER_GENERATION=app-request-generation"
                    } else {
                        it
                    }
                },
                lifecycleState = "idle",
                chains = 4,
                anchors = 4,
            ),
        )
        val stale = expected.copy(ownerGeneration = "previous-generation")
        val deterministicFailure = ServiceLifecycleController.CommandResult(
            success = false,
            indeterminate = false,
        )
        val indeterminate = deterministicFailure.copy(indeterminate = true)

        assertTrue(
            ServiceLifecycleController.indeterminateLifecycleCommitMatches(
                indeterminate,
                expected,
                expectedRunning = true,
                expectedOwnerGeneration = "app-request-generation",
            ),
        )
        assertFalse(
            ServiceLifecycleController.indeterminateLifecycleCommitMatches(
                indeterminate,
                stale,
                expectedRunning = true,
                expectedOwnerGeneration = "app-request-generation",
            ),
        )
        assertFalse(
            ServiceLifecycleController.indeterminateLifecycleCommitMatches(
                deterministicFailure,
                expected,
                expectedRunning = true,
                expectedOwnerGeneration = "app-request-generation",
            ),
        )
        assertFalse(
            ServiceLifecycleController.indeterminateLifecycleCommitMatches(
                indeterminate,
                expected,
                expectedRunning = false,
                expectedOwnerGeneration = "app-request-generation",
            ),
        )
    }

    @Test
    fun lifecycleReceipt_rejectsMissingDuplicateOrMalformedV6Payloads() {
        val valid = versionSixStatusLines(
            healthyStatusLines(),
            lifecycleState = "idle",
            chains = 4,
            anchors = 4,
        )
        val missingProtocol = valid.filterNot { it == "Z2_PROTOCOL=6" }
        val duplicateStatus = valid.toMutableList().apply {
            add(lastIndex, "Z2_STATUS=ok")
        }
        val unsuccessful = ServiceLifecycleController.CommandResult(
            success = false,
            stdout = valid,
            exitCode = 1,
        )

        assertNull(
            ServiceLifecycleController.parseLifecycleReceipt(
                ServiceLifecycleController.CommandResult(
                    success = true,
                    stdout = missingProtocol,
                    exitCode = 0,
                ),
            ),
        )
        assertNull(
            ServiceLifecycleController.parseLifecycleReceipt(
                ServiceLifecycleController.CommandResult(
                    success = true,
                    stdout = duplicateStatus,
                    exitCode = 0,
                ),
            ),
        )
        assertNull(ServiceLifecycleController.parseLifecycleReceipt(unsuccessful))
    }

    @Test
    fun statusObservation_negotiatesTheModuleProtocolOnceAndRetriesTheCascadeAfterItChanges() =
        runBlocking {
            ServiceLifecycleController.invalidateStatusProtocolNegotiation()
            val requested = mutableListOf<Int>()
            var spokenProtocol = 1
            val probe: suspend (Int) -> ServiceLifecycleController.CommandResult = { version ->
                requested += version
                when (version) {
                    spokenProtocol -> stoppedPayload(version)
                    else -> unsupportedProtocolResult()
                }
            }

            val negotiated = ServiceLifecycleController.observeNegotiatedStatus(probe)
            assertTrue(negotiated.fullyStopped)
            assertEquals(listOf(6, 5, 4, 3, 1), requested)

            requested.clear()
            assertTrue(ServiceLifecycleController.observeNegotiatedStatus(probe).fullyStopped)
            assertEquals(listOf(1), requested)

            spokenProtocol = 6
            requested.clear()
            val renegotiated = ServiceLifecycleController.observeNegotiatedStatus(probe)
            assertTrue(renegotiated.fullyStopped)
            assertEquals(listOf(1, 6), requested)

            requested.clear()
            assertTrue(ServiceLifecycleController.observeNegotiatedStatus(probe).fullyStopped)
            assertEquals(listOf(6), requested)

            ServiceLifecycleController.invalidateStatusProtocolNegotiation()
        }

    @Test
    fun statusObservation_neverLosesAnInvalidationRaisedWhileTheCascadeIsStillRunning() =
        runBlocking {
            ServiceLifecycleController.invalidateStatusProtocolNegotiation()
            val requested = mutableListOf<Int>()
            var invalidateWhileProbing = false
            val probe: suspend (Int) -> ServiceLifecycleController.CommandResult = { version ->
                requested += version
                when (version) {
                    5 -> {
                        // The installation authority observes a replaced package after this
                        // cascade started but before its result is published. An installed script
                        // still answers every older flag, so the retired result must not survive.
                        if (invalidateWhileProbing) {
                            ServiceLifecycleController.invalidateStatusProtocolNegotiation()
                        }
                        stoppedPayload(version)
                    }
                    else -> unsupportedProtocolResult()
                }
            }

            invalidateWhileProbing = true
            assertTrue(ServiceLifecycleController.observeNegotiatedStatus(probe).fullyStopped)
            assertEquals(listOf(6, 5), requested)

            invalidateWhileProbing = false
            requested.clear()
            assertTrue(ServiceLifecycleController.observeNegotiatedStatus(probe).fullyStopped)
            assertEquals(listOf(6, 5), requested)

            requested.clear()
            assertTrue(ServiceLifecycleController.observeNegotiatedStatus(probe).fullyStopped)
            assertEquals(listOf(5), requested)

            ServiceLifecycleController.invalidateStatusProtocolNegotiation()
        }

    @Test
    fun statusObservation_discardsTheCachedAnswerWhenAnInvalidationLandsWhileItsProbeRuns() =
        runBlocking {
            ServiceLifecycleController.invalidateStatusProtocolNegotiation()
            val requested = mutableListOf<Int>()
            var spokenProtocols = setOf(5)
            var invalidateDuringCachedProbe = false
            val probe: suspend (Int) -> ServiceLifecycleController.CommandResult = { version ->
                requested += version
                if (invalidateDuringCachedProbe) {
                    // The installation authority observes a replaced package while the remembered
                    // version is being probed. The installed script still answers that older flag
                    // truthfully, so only the invalidation can reject the answer it produced.
                    invalidateDuringCachedProbe = false
                    ServiceLifecycleController.invalidateStatusProtocolNegotiation()
                }
                if (version in spokenProtocols) {
                    stoppedPayload(version)
                } else {
                    unsupportedProtocolResult()
                }
            }

            assertTrue(ServiceLifecycleController.observeNegotiatedStatus(probe).fullyStopped)
            assertEquals(listOf(6, 5), requested)

            requested.clear()
            spokenProtocols = setOf(6, 5)
            invalidateDuringCachedProbe = true
            assertTrue(ServiceLifecycleController.observeNegotiatedStatus(probe).fullyStopped)
            assertEquals(listOf(5, 6), requested)

            requested.clear()
            assertTrue(ServiceLifecycleController.observeNegotiatedStatus(probe).fullyStopped)
            assertEquals(listOf(6), requested)

            ServiceLifecycleController.invalidateStatusProtocolNegotiation()
        }

    @Test
    fun statusObservation_neverRemembersAVersionThePayloadItselfDidNotDeclare() = runBlocking {
        ServiceLifecycleController.invalidateStatusProtocolNegotiation()
        val requested = mutableListOf<Int>()
        val probe: suspend (Int) -> ServiceLifecycleController.CommandResult = { version ->
            requested += version
            when (version) {
                // A complete payload proves the protocol it names, not the one that was asked for.
                5 -> stoppedPayload(4)
                else -> unsupportedProtocolResult()
            }
        }

        val answered = ServiceLifecycleController.observeNegotiatedStatus(probe)
        assertTrue(answered.metadataComplete)
        assertEquals(listOf(6, 5), requested)

        requested.clear()
        assertTrue(ServiceLifecycleController.observeNegotiatedStatus(probe).metadataComplete)
        assertEquals(listOf(6, 5), requested)

        ServiceLifecycleController.invalidateStatusProtocolNegotiation()
    }

    @Test
    fun statusObservation_neverRemembersAProtocolThatAnsweredAnIncompletePayload() = runBlocking {
        ServiceLifecycleController.invalidateStatusProtocolNegotiation()
        val requested = mutableListOf<Int>()
        val probe: suspend (Int) -> ServiceLifecycleController.CommandResult = { version ->
            requested += version
            when (version) {
                5 -> ServiceLifecycleController.CommandResult(
                    success = false,
                    stdout = versionFiveStatusLines(
                        stoppedStatusLines(),
                        lifecycleState = "idle",
                        chains = 0,
                        anchors = 0,
                    ).dropLast(1),
                    exitCode = 1,
                )
                else -> unsupportedProtocolResult()
            }
        }

        val incomplete = ServiceLifecycleController.observeNegotiatedStatus(probe)
        assertFalse(incomplete.metadataComplete)
        assertEquals(listOf(6, 5), requested)

        requested.clear()
        ServiceLifecycleController.observeNegotiatedStatus(probe)
        assertEquals(listOf(6, 5), requested)

        ServiceLifecycleController.invalidateStatusProtocolNegotiation()
    }

    @Test
    fun parseStatusOutput_acceptsOnlyCompleteVerifiedHealthyState() {
        val status = ServiceLifecycleController.parseStatusOutput(healthyStatusLines())

        assertTrue(status.healthy)
        assertFalse(status.fullyStopped)
        assertTrue(status.metadataComplete)
        assertTrue(status.hasOwnedState)
        assertEquals("4242", status.pid)
        assertEquals(3, status.nfqueueRulesCount)
        assertEquals(200, status.qnum)
        assertNull(status.error)
    }

    @Test
    fun parseStatusOutput_acceptsVersionThreeAndCarriesOpaqueModuleError() {
        val lines = stoppedStatusLines().toMutableList().apply {
            add(0, "Z2_PROTOCOL=3")
            add(lastIndex, "Z2_ERROR_SCHEMA=1")
            add(lastIndex, "Z2_ERROR_STATUS=ERROR")
            add(lastIndex, "Z2_ERROR_DOMAIN=FIREWALL")
            add(lastIndex, "Z2_ERROR_STAGE=START_IPV4_BUILD_RULE")
            add(lastIndex, "Z2_ERROR_CODE=FUTURE_FIREWALL_FAILURE")
            add(lastIndex, "Z2_ERROR_DETAIL=iptables rejected the future rule")
        }

        val status = ServiceLifecycleController.parseStatusOutput(lines)

        assertTrue(status.metadataComplete)
        assertTrue(status.fullyStopped)
        assertEquals("FIREWALL", status.lifecycleError?.domain)
        assertEquals("FUTURE_FIREWALL_FAILURE", status.lifecycleError?.code)
        assertEquals("START_IPV4_BUILD_RULE", status.lifecycleError?.stage)
        assertEquals("iptables rejected the future rule", status.lifecycleError?.detail)
    }

    @Test
    fun parseStatusOutput_acceptsVersionFourIdleAndRecoveredSnapshots() {
        val idle = ServiceLifecycleController.parseStatusOutput(
            versionFourStatusLines(healthyStatusLines(), lifecycleState = "idle"),
        )
        val recovered = ServiceLifecycleController.parseStatusOutput(
            versionFourStatusLines(stoppedStatusLines(), lifecycleState = "recovered"),
        )

        assertTrue(idle.metadataComplete)
        assertTrue(idle.healthy)
        assertEquals(ServiceLifecycleController.LifecycleState.IDLE, idle.lifecycleState)
        assertTrue(recovered.metadataComplete)
        assertTrue(recovered.fullyStopped)
        assertEquals(ServiceLifecycleController.LifecycleState.RECOVERED, recovered.lifecycleState)
    }

    @Test
    fun parseStatusOutput_acceptsVersionFiveAsCompleteFirewallUiContract() {
        val status = ServiceLifecycleController.parseStatusOutput(
            versionFiveStatusLines(
                healthyStatusLines(),
                lifecycleState = "idle",
                chains = 4,
                anchors = 4,
            ),
        )

        assertTrue(status.metadataComplete)
        assertTrue(status.healthy)
        assertEquals(4, status.chainsCount)
        assertEquals(4, status.anchorsCount)
        assertEquals(ServiceLifecycleController.LifecycleState.IDLE, status.lifecycleState)
    }

    @Test
    fun parseStatusOutput_acceptsCallerOwnedVersionSixTransaction() {
        val status = ServiceLifecycleController.parseStatusOutput(
            versionSixStatusLines(
                healthyStatusLines(),
                lifecycleState = "owned",
                ownerKind = "android-mutation",
                chains = 4,
                anchors = 4,
            ),
        )

        assertTrue(status.metadataComplete)
        assertTrue(status.healthy)
        assertEquals(ServiceLifecycleController.LifecycleState.OWNED, status.lifecycleState)
        assertEquals("android-mutation", status.lifecycleOwnerKind)
        assertFalse(status.updateBlocked)
    }

    @Test
    fun parseStatusOutput_rejectsCallerOwnedStateFromLegacyProtocol() {
        val status = ServiceLifecycleController.parseStatusOutput(
            versionFiveStatusLines(
                healthyStatusLines(),
                lifecycleState = "owned",
                ownerKind = "android-mutation",
                chains = 4,
                anchors = 4,
            ),
        )

        assertFalse(status.metadataComplete)
    }

    @Test
    fun parseStatusOutput_rejectsIncompleteOrContradictoryVersionFiveTopologyFacts() {
        val missing = versionFiveStatusLines(
            healthyStatusLines(),
            lifecycleState = "idle",
            chains = 2,
            anchors = 2,
        ).filterNot { it.startsWith("Z2_ANCHORS=") }
        val contradictory = versionFiveStatusLines(
            healthyStatusLines(),
            lifecycleState = "idle",
            chains = 1,
            anchors = 2,
        )

        assertFalse(ServiceLifecycleController.parseStatusOutput(missing).metadataComplete)
        assertFalse(ServiceLifecycleController.parseStatusOutput(contradictory).metadataComplete)
    }

    @Test
    fun parseStatusOutput_distinguishesLiveAndAmbiguousLifecycleBarriers() {
        val active = ServiceLifecycleController.parseStatusOutput(
            lifecycleBarrierStatusLines("active", "shell", "LIFECYCLE_ACTIVE"),
        )
        val ambiguous = ServiceLifecycleController.parseStatusOutput(
            lifecycleBarrierStatusLines("ambiguous", "unknown", "LIFECYCLE_AMBIGUOUS"),
        )

        assertTrue(active.metadataComplete)
        assertEquals(ServiceLifecycleController.LifecycleState.ACTIVE, active.lifecycleState)
        assertTrue(active.updateBlocked)
        assertEquals("LIFECYCLE_ACTIVE", active.lifecycleError?.code)
        assertTrue(ambiguous.metadataComplete)
        assertEquals(ServiceLifecycleController.LifecycleState.AMBIGUOUS, ambiguous.lifecycleState)
        assertEquals("LIFECYCLE_AMBIGUOUS", ambiguous.lifecycleError?.code)
    }

    @Test
    fun parseStatusOutput_rejectsContradictoryVersionFourLifecycleIdentity() {
        val invalid = versionFourStatusLines(
            healthyStatusLines(),
            lifecycleState = "active",
            ownerKind = "none",
        )

        assertFalse(ServiceLifecycleController.parseStatusOutput(invalid).metadataComplete)
    }

    @Test
    fun parseStatusOutput_rejectsPartialButAcceptsUnknownVersionThreeIdentity() {
        val valid = stoppedStatusLines().toMutableList().apply {
            add(0, "Z2_PROTOCOL=3")
            add(lastIndex, "Z2_ERROR_SCHEMA=1")
            add(lastIndex, "Z2_ERROR_STATUS=OK")
            add(lastIndex, "Z2_ERROR_DOMAIN=NONE")
            add(lastIndex, "Z2_ERROR_STAGE=NONE")
            add(lastIndex, "Z2_ERROR_CODE=NONE")
            add(lastIndex, "Z2_ERROR_DETAIL=")
        }
        val partial = valid.filterNot { it.startsWith("Z2_ERROR_STAGE=") }
        val unknown = valid.map {
            when {
                it == "Z2_ERROR_STATUS=OK" -> "Z2_ERROR_STATUS=ERROR"
                it == "Z2_ERROR_DOMAIN=NONE" -> "Z2_ERROR_DOMAIN=FUTURE"
                it == "Z2_ERROR_STAGE=NONE" -> "Z2_ERROR_STAGE=FUTURE_STAGE"
                it == "Z2_ERROR_CODE=NONE" -> "Z2_ERROR_CODE=FUTURE_FAILURE"
                it == "Z2_ERROR_DETAIL=" -> "Z2_ERROR_DETAIL=future detail"
                else -> it
            }
        }

        assertFalse(ServiceLifecycleController.parseStatusOutput(partial).metadataComplete)
        assertTrue(ServiceLifecycleController.parseStatusOutput(unknown).metadataComplete)
        assertEquals(
            "FUTURE_FAILURE",
            ServiceLifecycleController.parseStatusOutput(unknown).lifecycleError?.code,
        )
    }

    @Test
    fun parseStatusOutput_rejectsApparentlyRunningStatusWithMissingMetadata() {
        val status = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().filterNot { it.startsWith("Z2_OWNER_METADATA_VERIFIED=") },
        )

        assertTrue(status.processRunning)
        assertFalse(status.metadataComplete)
        assertFalse(status.healthy)
    }

    @Test
    fun parseStatusOutput_rejectsRuleCountMismatchAndInvalidPid() {
        val lines = healthyStatusLines().map { line ->
            when {
                line.startsWith("Z2_PID=") -> "Z2_PID=not-a-pid"
                line.startsWith("Z2_RULES=") -> "Z2_RULES=2"
                else -> line
            }
        }
        val status = ServiceLifecycleController.parseStatusOutput(lines)

        assertEquals("", status.pid)
        assertFalse(status.processRunning)
        assertEquals(2, status.nfqueueRulesCount)
        assertFalse(status.healthy)
    }

    @Test
    fun parseStatusOutput_identifiesCleanStoppedState() {
        val status = ServiceLifecycleController.parseStatusOutput(
            stoppedStatusLines(),
        )

        assertTrue(status.fullyStopped)
        assertFalse(status.healthy)
        assertFalse(status.hasOwnedState)
    }

    @Test
    fun parseStatusOutput_neverTreatsTruncatedStoppedRecordAsFullyStopped() {
        val status = ServiceLifecycleController.parseStatusOutput(
            stoppedStatusLines().filterNot { it.startsWith("Z2_OWNER_GENERATION=") },
        )

        assertFalse(status.metadataComplete)
        assertFalse(status.fullyStopped)
        assertTrue(status.hasOwnedState)
        assertEquals("unknown", status.declaredStatus)
    }

    @Test
    fun parseStatusOutput_rejectsRecordMissingRequiredTerminalField() {
        val status = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().dropLast(1),
        )

        assertFalse(status.metadataComplete)
        assertFalse(status.healthy)
        assertEquals("unknown", status.declaredStatus)
    }

    @Test
    fun parseStatusOutput_rejectsDuplicateOrNonTerminalProtocolFields() {
        val duplicate = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().toMutableList().apply { add(size - 1, "Z2_PID=4242") },
        )
        val nonTerminal = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines() + "Z2_STATUS=ok",
        )
        val duplicateCompletion = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines() + "Z2_COMPLETE=1",
        )
        assertFalse(duplicate.metadataComplete)
        assertFalse(nonTerminal.metadataComplete)
        assertFalse(duplicateCompletion.metadataComplete)
    }

    @Test
    fun parseStatusOutput_rejectsUnknownMachineField() {
        val status = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().toMutableList().apply { add(size - 1, "Z2_FUTURE_FIELD=1") },
        )

        assertFalse(status.metadataComplete)
        assertFalse(status.healthy)
        assertEquals("unknown", status.declaredStatus)
    }

    @Test
    fun parseStatusOutput_exposesUpdateAndUninstallGatesFromRealRecord() {
        val status = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().map {
                when {
                    it.startsWith("Z2_STATUS=") -> "Z2_STATUS=degraded"
                    it.startsWith("Z2_ACTIVE=") -> "Z2_ACTIVE=0"
                    it.startsWith("Z2_UPDATE_BLOCKED=") -> "Z2_UPDATE_BLOCKED=1"
                    it.startsWith("Z2_UNINSTALL_TOMBSTONE=") -> "Z2_UNINSTALL_TOMBSTONE=1"
                    else -> it
                }
            },
        )

        assertTrue(status.metadataComplete)
        assertTrue(status.updateBlocked)
        assertTrue(status.uninstallTombstone)
        assertFalse(status.healthy)
    }

    @Test
    fun parseStatusOutput_acceptsValidDegradedMultipleOrphanShape() {
        val status = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().map { line ->
                when {
                    line.startsWith("Z2_STATUS=") -> "Z2_STATUS=degraded"
                    line.startsWith("Z2_ACTIVE=") -> "Z2_ACTIVE=0"
                    line.startsWith("Z2_PID=") -> "Z2_PID="
                    line.startsWith("Z2_PID_VERIFIED=") -> "Z2_PID_VERIFIED=0"
                    line.startsWith("Z2_PID_STARTTIME=") -> "Z2_PID_STARTTIME="
                    line.startsWith("Z2_OWNER_GENERATION=") -> "Z2_OWNER_GENERATION="
                    line.startsWith("Z2_OWNER_METADATA_VERIFIED=") -> "Z2_OWNER_METADATA_VERIFIED=0"
                    line.startsWith("Z2_RULESET_VERIFIED=") -> "Z2_RULESET_VERIFIED=0"
                    else -> line
                }
            },
        )

        assertTrue(status.metadataComplete)
        assertTrue(status.processRunning)
        assertEquals("", status.pid)
        assertFalse(status.healthy)
    }

    @Test
    fun parseStatusOutput_enforcesQueueNumberBoundaries() {
        listOf("1", "65535").forEach { value ->
            val status = ServiceLifecycleController.parseStatusOutput(
                healthyStatusLines().map { if (it.startsWith("Z2_QNUM=")) "Z2_QNUM=$value" else it },
            )
            assertEquals(value.toInt(), status.qnum)
            assertTrue(status.healthy)
        }

        listOf("0", "-1", "65536", "1.0", "999999999999999999999").forEach { value ->
            val status = ServiceLifecycleController.parseStatusOutput(
                healthyStatusLines().map { if (it.startsWith("Z2_QNUM=")) "Z2_QNUM=$value" else it },
            )
            assertNull(status.qnum)
            assertFalse(status.healthy)
        }
    }

    @Test
    fun parseStatusOutput_acceptsCanonicalNonnegative64BitStartTicks() {
        listOf("0", "2147483648", "9223372036854775807").forEach { ticks ->
            val status = ServiceLifecycleController.parseStatusOutput(
                healthyStatusLines().map {
                    if (it.startsWith("Z2_PID_STARTTIME=")) "Z2_PID_STARTTIME=$ticks" else it
                },
            )
            assertTrue("start ticks $ticks must remain valid", status.metadataComplete)
            assertEquals(ticks, status.pidStarttime)
            assertTrue(status.healthy)
        }

        listOf("-1", "+1", "01", "9223372036854775808", "18446744073709551615").forEach { ticks ->
            val status = ServiceLifecycleController.parseStatusOutput(
                healthyStatusLines().map {
                    if (it.startsWith("Z2_PID_STARTTIME=")) "Z2_PID_STARTTIME=$ticks" else it
                },
            )
            assertFalse("start ticks $ticks must fail closed", status.metadataComplete)
            assertFalse(status.healthy)
        }
    }

    @Test
    fun parseStatusOutput_rejectsNegativeCountsAndUnknownStatusValue() {
        val status = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().map { line ->
                when {
                    line.startsWith("Z2_STATUS=") -> "Z2_STATUS=error=iptables"
                    line.startsWith("Z2_RULES=") -> "Z2_RULES=-7"
                    line.startsWith("Z2_EXPECTED_RULES=") -> "Z2_EXPECTED_RULES=-2"
                    line.startsWith("Z2_IPV4_RULES=") -> "Z2_IPV4_RULES=-1"
                    line.startsWith("Z2_IPV6_RULES=") -> "Z2_IPV6_RULES=-3"
                    else -> line
                }
            },
        )

        assertEquals("unknown", status.declaredStatus)
        assertEquals(0, status.nfqueueRulesCount)
        assertEquals(0, status.expectedRulesCount)
        assertEquals(0, status.ipv4RulesCount)
        assertEquals(0, status.ipv6RulesCount)
        assertTrue(status.hasOwnedState)
        assertFalse(status.metadataComplete)
    }

    @Test
    fun parseStatusOutput_rejectsEveryNonCanonicalBooleanEncoding() {
        val booleanFields = listOf(
            "Z2_OWNED", "Z2_PROCESS", "Z2_ACTIVE", "Z2_PID_VERIFIED",
            "Z2_OWNER_METADATA_VERIFIED", "Z2_IPV4", "Z2_IPV6", "Z2_RULESET_VERIFIED",
            "Z2_NFQUEUE", "Z2_QUEUE_BYPASS", "Z2_UPDATE_BLOCKED", "Z2_UNINSTALL_TOMBSTONE",
            "Z2_COMPLETE",
        )
        booleanFields.forEach { field ->
            listOf("2", "true", "", "01").forEach { invalid ->
                val status = ServiceLifecycleController.parseStatusOutput(
                    healthyStatusLines().map { if (it.startsWith("$field=")) "$field=$invalid" else it },
                )
                assertFalse("$field=$invalid must fail closed", status.metadataComplete)
                assertFalse("$field=$invalid must not authorize healthy state", status.healthy)
            }
        }
    }

    @Test
    fun parseStatusOutput_rejectsNegativeNonCanonicalAndOverflowingCounts() {
        val integerFields = listOf(
            "Z2_RULES", "Z2_EXPECTED_RULES", "Z2_IPV4_RULES", "Z2_IPV6_RULES",
        )
        integerFields.forEach { field ->
            listOf("-1", "+1", "01", "2147483648", "999999999999999999999", "").forEach { invalid ->
                val status = ServiceLifecycleController.parseStatusOutput(
                    healthyStatusLines().map { if (it.startsWith("$field=")) "$field=$invalid" else it },
                )
                assertFalse("$field=$invalid must fail closed", status.metadataComplete)
                assertEquals("unknown", status.declaredStatus)
            }
        }
    }

    @Test
    fun parseStatusOutput_rejectsCrossContractContradictions() {
        val contradictoryRecords = listOf(
            mapOf("Z2_STATUS" to "stopped"),
            mapOf("Z2_OWNED" to "0"),
            mapOf("Z2_PROCESS" to "0"),
            mapOf("Z2_PID_VERIFIED" to "0"),
            mapOf("Z2_OWNER_METADATA_VERIFIED" to "0"),
            mapOf("Z2_RULESET_VERIFIED" to "0"),
            mapOf("Z2_RULES" to "4"),
            mapOf("Z2_IPV4_RULES" to "3"),
            mapOf("Z2_UPDATE_BLOCKED" to "1"),
        )
        contradictoryRecords.forEach { overrides ->
            val status = ServiceLifecycleController.parseStatusOutput(
                healthyStatusLines().map { line ->
                    val key = line.substringBefore('=')
                    overrides[key]?.let { "$key=$it" } ?: line
                },
            )
            assertFalse("Contradiction $overrides must fail closed", status.metadataComplete)
            assertFalse(status.healthy)
        }
    }

    @Test
    fun parseStatusOutput_rejectsWhitespaceAndPrefixKeyInjection() {
        val whitespaceKey = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().map { if (it.startsWith("Z2_OWNED=")) "Z2_OWNED =1" else it },
        )
        val prefixedKey = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().toMutableList().apply { add(size - 1, "Z2_OWNED_EXTRA=1") },
        )
        val whitespaceValue = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines().map { if (it.startsWith("Z2_OWNED=")) "Z2_OWNED=1 " else it },
        )
        val leadingWhitespaceInjection = ServiceLifecycleController.parseStatusOutput(
            healthyStatusLines() + " Z2_OWNED=0",
        )

        assertFalse(whitespaceKey.metadataComplete)
        assertFalse(prefixedKey.metadataComplete)
        assertFalse(whitespaceValue.metadataComplete)
        assertFalse(leadingWhitespaceInjection.metadataComplete)
    }

    @Test
    fun commandDiagnostics_collectsUsefulUniqueMessagesOnly() {
        val result = ServiceLifecycleController.CommandResult(
            success = false,
            stdout = listOf("ordinary output", "DIAGNOSTIC: queue unavailable", "DIAGNOSTIC: queue unavailable"),
            stderr = listOf("", "iptables failed"),
            error = "root command failed",
        )

        assertEquals(
            "root command failed\niptables failed\nqueue unavailable",
            result.diagnosticText(),
        )
    }

    @Test
    fun commandDiagnostics_includeStableErrorCodeBeforeShellDetail() {
        val result = ServiceLifecycleController.CommandResult(
            success = false,
            stdout = listOf(
                "Z2_ERROR_CODE=FIREWALL_BUILD_FAILED",
                "ERROR: cannot build detached IPv4 chains; iptables BUILD_RULE failed: xtables lock",
            ),
            lifecycleError = LifecycleError(
                status = "ERROR",
                domain = "FIREWALL",
                stage = "START_IPV4_BUILD_RULE",
                code = "FIREWALL_BUILD_FAILED",
                detail = "iptables BUILD_RULE failed: xtables lock",
            ),
        )

        assertEquals(
            "schema=1\nstatus=ERROR\ndomain=FIREWALL\nstage=START_IPV4_BUILD_RULE\n" +
                "code=FIREWALL_BUILD_FAILED\ndetail=iptables BUILD_RULE failed: xtables lock\n" +
                "cannot build detached IPv4 chains; iptables BUILD_RULE failed: xtables lock",
            result.diagnosticText(),
        )
    }

    @Test
    fun parseFullRollbackOutput_acceptsExactCompleteProtocolAndPropagatesReboot() {
        val parsed = ServiceLifecycleController.parseFullRollbackOutput(fullRollbackLines())

        assertTrue(parsed is ServiceLifecycleController.FullRollbackParseResult.Valid)
        val report = (parsed as ServiceLifecycleController.FullRollbackParseResult.Valid).report
        assertEquals(ServiceLifecycleController.FullRollbackStatus.COMPLETE, report.status)
        assertTrue(report.satisfiesCompleteContract)
        assertTrue(report.rebootRequired)
        assertEquals("full rollback complete; reboot required", report.diagnostic)
    }

    @Test
    fun parseFullRollbackOutput_rejectsDuplicateMissingAndUnknownFields() {
        val duplicate = fullRollbackLines().toMutableList().apply {
            add(size - 1, "Z2_RB_PROCESS_CLEAN=1")
        }
        val missing = fullRollbackLines().filterNot { it.startsWith("Z2_RB_HOSTS_PRESERVED=") }
        val unknown = fullRollbackLines().toMutableList().apply {
            add(size - 1, "Z2_RB_FUTURE=1")
            removeAt(indexOfFirst { it.startsWith("Z2_RB_HOSTS_PRESERVED=") })
        }

        listOf(duplicate, missing, unknown).forEach { lines ->
            assertTrue(
                ServiceLifecycleController.parseFullRollbackOutput(lines) is
                    ServiceLifecycleController.FullRollbackParseResult.Invalid,
            )
        }
    }

    @Test
    fun parseFullRollbackOutput_requiresCompleteOneAsFinalField() {
        val nonTerminal = fullRollbackLines().toMutableList().apply {
            add(0, removeAt(lastIndex))
        }
        val badSentinel = fullRollbackLines().dropLast(1) + "Z2_RB_COMPLETE=0"

        assertTrue(
            ServiceLifecycleController.parseFullRollbackOutput(nonTerminal) is
                ServiceLifecycleController.FullRollbackParseResult.Invalid,
        )
        assertTrue(
            ServiceLifecycleController.parseFullRollbackOutput(badSentinel) is
                ServiceLifecycleController.FullRollbackParseResult.Invalid,
        )
    }

    @Test
    fun parseFullRollbackOutput_rejectsBadBooleanAndUnknownStatus() {
        val badBoolean = fullRollbackLines(
            overrides = mapOf("Z2_RB_PROCESS_CLEAN" to "true"),
        )
        val badStatus = fullRollbackLines(status = "success")

        assertTrue(
            ServiceLifecycleController.parseFullRollbackOutput(badBoolean) is
                ServiceLifecycleController.FullRollbackParseResult.Invalid,
        )
        assertTrue(
            ServiceLifecycleController.parseFullRollbackOutput(badStatus) is
                ServiceLifecycleController.FullRollbackParseResult.Invalid,
        )
    }

    @Test
    fun parseFullRollbackOutput_keepsPartialBlockedAndErrorTyped() {
        listOf(
            "partial" to ServiceLifecycleController.FullRollbackStatus.PARTIAL,
            "blocked" to ServiceLifecycleController.FullRollbackStatus.BLOCKED,
            "error" to ServiceLifecycleController.FullRollbackStatus.ERROR,
        ).forEach { (wireStatus, expected) ->
            val parsed = ServiceLifecycleController.parseFullRollbackOutput(
                fullRollbackLines(
                    status = wireStatus,
                    overrides = mapOf(
                        "Z2_RB_PROCESS_CLEAN" to "0",
                        "Z2_RB_REBOOT_REQUIRED" to if (wireStatus == "blocked") "0" else "1",
                    ),
                ),
            ) as ServiceLifecycleController.FullRollbackParseResult.Valid

            assertEquals(expected, parsed.report.status)
            assertEquals(wireStatus != "blocked", parsed.report.rebootRequired)
            assertFalse(parsed.report.satisfiesCompleteContract)
        }
    }

    @Test
    fun parseFullRollbackOutput_completeStatusFailsClosedOnInconsistentInvariants() {
        listOf(
            "Z2_RB_PROCESS_CLEAN",
            "Z2_RB_FIREWALL_CLEAN",
            "Z2_RB_ROLLBACK_ARMED",
            "Z2_RB_HOSTS_PRESERVED",
            "Z2_RB_REBOOT_REQUIRED",
            "Z2_RB_USER_DATA_PRESERVED",
        ).forEach { field ->
            val parsed = ServiceLifecycleController.parseFullRollbackOutput(
                fullRollbackLines(overrides = mapOf(field to "0")),
            ) as ServiceLifecycleController.FullRollbackParseResult.Valid
            assertFalse(field, parsed.report.satisfiesCompleteContract)
        }
        val legacyAmbiguous = ServiceLifecycleController.parseFullRollbackOutput(
            fullRollbackLines(overrides = mapOf("Z2_RB_LEGACY_AMBIGUOUS" to "1")),
        ) as ServiceLifecycleController.FullRollbackParseResult.Valid
        assertFalse(legacyAmbiguous.report.satisfiesCompleteContract)
    }

    /**
     * The payload `zapret-status.sh --machine-v6` really answers with right after a rollback that
     * finished everything but could not re-read the IPv6 family.
     *
     * The rollback publishes an honest receipt (`ruleset_verified=0`, `ipv6_active=1`), which
     * denies the status script its stopped fast path; the script then cannot query IPv6 either,
     * so `IPV6_UNKNOWN=1` forces `Z2_OWNED=1` and grades the payload `degraded` (exit 2). This is
     * the observation the partial verdict must survive, so it is reproduced field for field
     * instead of being stood in for by a synthetic stopped status.
     */
    @Test
    fun ipv6UnverifiedRollbackObservation_isACompleteDegradedPayloadThatIsNeverFullyStopped() {
        val status = ipv6UnverifiedRollbackStatus()

        assertTrue(status.metadataComplete)
        assertEquals("degraded", status.declaredStatus)
        assertTrue(status.hasOwnedState)
        assertFalse(status.rulesetVerified)
        assertFalse(status.processRunning)
        assertFalse(status.iptablesActive)
        assertEquals(0, status.nfqueueRulesCount)
        // The exact reason the previous gate could never be satisfied by this scenario.
        assertFalse(status.fullyStopped)
        assertFalse(status.provesLiveRuntime)
    }

    @Test
    fun partialRollbackThatFinishedEverythingIsRolledBackWithAnUnverifiedCleanupReservation() {
        val result = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            status = "partial",
            overrides = mapOf("Z2_RB_FIREWALL_CLEAN" to "0"),
            serviceStatus = ipv6UnverifiedRollbackStatus(),
        )

        assertFalse(result.success)
        // Regression guard: this is the real observation the module produces for this receipt.
        // Re-adding a `serviceStatus.fullyStopped` requirement to the partial branch fails here.
        assertFalse(result.serviceStatus?.fullyStopped == true)
        assertTrue(result.rolledBack)
        assertNotEquals(ServiceLifecycleController.FullRollbackOutcome.COMPLETE, result.outcome)
        assertTrue(result.report?.satisfiesRolledBackContract == true)
        assertFalse(result.report?.satisfiesCompleteContract == true)
    }

    /**
     * Only one receipt shape may claim "rolled back with a reservation": every completion field
     * asserted, no legacy ambiguity, and the firewall assertion the module withheld. Enumerating
     * the whole boolean space proves no other combination can forge that verdict, including
     * against the real degraded observation that no longer gates it.
     */
    @Test
    fun onlyTheExactUnverifiedFirewallReceiptCanClaimARolledBackPartial() {
        val booleans = listOf(
            "Z2_RB_PROCESS_CLEAN",
            "Z2_RB_FIREWALL_CLEAN",
            "Z2_RB_ROLLBACK_ARMED",
            "Z2_RB_HOSTS_PRESERVED",
            "Z2_RB_REBOOT_REQUIRED",
            "Z2_RB_USER_DATA_PRESERVED",
            "Z2_RB_LEGACY_AMBIGUOUS",
        )
        val rolledBackShape = mapOf(
            "Z2_RB_PROCESS_CLEAN" to "1",
            "Z2_RB_FIREWALL_CLEAN" to "0",
            "Z2_RB_ROLLBACK_ARMED" to "1",
            "Z2_RB_HOSTS_PRESERVED" to "1",
            "Z2_RB_REBOOT_REQUIRED" to "1",
            "Z2_RB_USER_DATA_PRESERVED" to "1",
            "Z2_RB_LEGACY_AMBIGUOUS" to "0",
        )
        var accepted = 0

        repeat(1 shl booleans.size) { mask ->
            val overrides = booleans.withIndex().associate { (index, field) ->
                field to if ((mask shr index) and 1 == 1) "1" else "0"
            }
            val result = fullRollbackResult(
                outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
                status = "partial",
                overrides = overrides,
                serviceStatus = ipv6UnverifiedRollbackStatus(),
            )
            val expected = overrides == rolledBackShape
            if (expected) accepted += 1
            assertEquals(overrides.toString(), expected, result.rolledBack)
        }

        assertEquals(1, accepted)
    }

    /** The wire status is part of the claim: a receipt that says something else cannot borrow it. */
    @Test
    fun rolledBackPartialRequiresTheOutcomeAndTheReceiptToAgree() {
        ServiceLifecycleController.FullRollbackOutcome.entries
            .filter { it != ServiceLifecycleController.FullRollbackOutcome.COMPLETE }
            .forEach { outcome ->
                val mismatchedOutcome = fullRollbackResult(
                    outcome = outcome,
                    status = "partial",
                    overrides = mapOf("Z2_RB_FIREWALL_CLEAN" to "0"),
                    serviceStatus = ipv6UnverifiedRollbackStatus(),
                )
                assertEquals(
                    outcome.name,
                    outcome == ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
                    mismatchedOutcome.rolledBack,
                )
            }

        listOf("complete", "blocked", "error").forEach { wireStatus ->
            val mismatchedReceipt = fullRollbackResult(
                outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
                status = wireStatus,
                overrides = mapOf("Z2_RB_FIREWALL_CLEAN" to "0"),
                serviceStatus = ipv6UnverifiedRollbackStatus(),
            )
            assertFalse(wireStatus, mismatchedReceipt.rolledBack)
        }
    }

    @Test
    fun completeRollbackIsRolledBackWithoutAnyReservation() {
        val result = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.COMPLETE,
        )

        assertTrue(result.rolledBack)
        assertEquals(ServiceLifecycleController.FullRollbackOutcome.COMPLETE, result.outcome)
    }

    @Test
    fun partialRollbackIsNotRolledBackWhenAnythingItOwnsIsUnfinished() {
        val hostsLost = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            status = "partial",
            overrides = mapOf(
                "Z2_RB_FIREWALL_CLEAN" to "0",
                "Z2_RB_HOSTS_PRESERVED" to "0",
            ),
            serviceStatus = ipv6UnverifiedRollbackStatus(),
        )
        val processRetained = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            status = "partial",
            overrides = mapOf(
                "Z2_RB_FIREWALL_CLEAN" to "0",
                "Z2_RB_PROCESS_CLEAN" to "0",
            ),
            serviceStatus = ipv6UnverifiedRollbackStatus(),
        )
        // Every fact asserted, including a verified-clean firewall, yet still partial: the run was
        // interrupted before it could commit, so the recovery journal is what survived.
        val interruptedBeforeCommit = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            status = "partial",
            serviceStatus = ipv6UnverifiedRollbackStatus(),
        )
        // A receipt cannot be believed against an observation that disproves it: the module says
        // the process is clean while the status script watches a verified nfqws2 serve live rules.
        val serviceStillUp = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            status = "partial",
            overrides = mapOf("Z2_RB_FIREWALL_CLEAN" to "0"),
            serviceStatus = ServiceLifecycleController.parseStatusCommandResult(
                ServiceLifecycleController.CommandResult(
                    success = true,
                    stdout = healthyStatusLines(),
                    exitCode = 0,
                ),
            ),
        )
        val blockedBeforeAnything = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.BLOCKED,
            status = "blocked",
            overrides = mapOf("Z2_RB_FIREWALL_CLEAN" to "0"),
            serviceStatus = ipv6UnverifiedRollbackStatus(),
        )

        // Same contradiction from the other direction: the observer counted live module-owned
        // rules, so the receipt's teardown claim cannot be taken at face value either.
        val residualRulesObserved = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            status = "partial",
            overrides = mapOf("Z2_RB_FIREWALL_CLEAN" to "0"),
            serviceStatus = ServiceLifecycleController.parseStatusCommandResult(
                ServiceLifecycleController.CommandResult(
                    success = false,
                    stdout = ipv6UnverifiedRollbackStatusLines().map { line ->
                        when {
                            line.startsWith("Z2_IPV4=") -> "Z2_IPV4=1"
                            line.startsWith("Z2_RULES=") -> "Z2_RULES=2"
                            line.startsWith("Z2_EXPECTED_RULES=") -> "Z2_EXPECTED_RULES=2"
                            line.startsWith("Z2_IPV4_RULES=") -> "Z2_IPV4_RULES=2"
                            else -> line
                        }
                    },
                    exitCode = 2,
                ),
            ),
        )

        listOf(
            "hostsLost" to hostsLost,
            "processRetained" to processRetained,
            "interruptedBeforeCommit" to interruptedBeforeCommit,
            "serviceStillUp" to serviceStillUp,
            "residualRulesObserved" to residualRulesObserved,
            "blockedBeforeAnything" to blockedBeforeAnything,
        ).forEach { (name, result) ->
            assertFalse(name, result.rolledBack)
        }
        assertTrue(residualRulesObserved.serviceStatus?.metadataComplete == true)
    }

    @Test
    fun rollbackWithoutAReportOrStatusIsNeverRolledBack() {
        val crashed = ServiceLifecycleController.FullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.ERROR,
        )

        assertFalse(crashed.rolledBack)
    }

    /**
     * The reported defect.
     *
     * A rollback that hangs re-reading an unqueryable IPv6 family outlives the lifecycle budget,
     * so the bounded transport's `timeout 420` wrapper sends SIGTERM. `zapret-full-rollback.sh`
     * catches it: the `interrupted` trap finishes the durable fence, sets `RB_STATUS=partial` and
     * prints the full ten-field receipt with every completion flag set and the firewall assertion
     * withheld — the same payload, field for field, as the ordinary IPv6-unverified partial — then
     * exits 1 exactly like `partial()` does, while `timeout` reports 124.
     *
     * Nothing in the receipt or its exit status separates the two. What separates them is that the
     * interrupted run stopped mid-teardown: the recovery journal it names as retained is still on
     * disk, and it blocks every later start, stop, uninstall and purge. Reporting "rollback
     * complete" over that is the one verdict the user cannot recover from on their own.
     */
    @Test
    fun partialReceiptFromACommandThatWasCutShortIsNeverRolledBack() {
        val interruptedOverrides = mapOf(
            "Z2_RB_FIREWALL_CLEAN" to "0",
            "Z2_RB_DIAGNOSTIC" to
                "rollback interrupted; durable disable fence and recovery journal retained",
        )
        val interrupted = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            status = "partial",
            overrides = interruptedOverrides,
            serviceStatus = ipv6UnverifiedRollbackStatus(),
            command = commandKilledByTheTimeoutWrapper(),
        )
        // The honest receipt this one is indistinguishable from, differing only in the command.
        val ipv6Unverified = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            status = "partial",
            overrides = interruptedOverrides,
            serviceStatus = ipv6UnverifiedRollbackStatus(),
            command = rollbackCommandThatFinishedPartial(),
        )

        // Identical receipts, identical outcome, both from an unsuccessful command: the only
        // difference the app has to go on is that one command never reached its own exit.
        assertEquals(interrupted.report, ipv6Unverified.report)
        assertFalse(checkNotNull(interrupted.command).success)
        assertFalse(checkNotNull(ipv6Unverified.command).success)
        assertTrue(checkNotNull(interrupted.command).indeterminate)
        assertFalse(checkNotNull(ipv6Unverified.command).indeterminate)
        assertTrue(checkNotNull(interrupted.report).satisfiesRolledBackContract)
        assertFalse(checkNotNull(interrupted.report).firewallClean)
        assertFalse(interrupted.rolledBack)
        assertTrue(ipv6Unverified.rolledBack)
    }

    /**
     * The command axis is not the exit status. Every terminal the script has for a non-complete
     * receipt exits non-zero — `partial()` and `failed()` exit 1, `blocked()` exits 2 — so the
     * honoured partial always arrives from a command the transport calls unsuccessful. Grading it
     * by [ServiceLifecycleController.CommandResult.success], the way the purge commit is graded,
     * would reject the exact receipt this verdict exists for.
     */
    @Test
    fun rolledBackPartialSurvivesTheModulesOwnNonZeroExit() {
        val honoured = fullRollbackResult(
            outcome = ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            status = "partial",
            overrides = mapOf("Z2_RB_FIREWALL_CLEAN" to "0"),
            serviceStatus = ipv6UnverifiedRollbackStatus(),
            command = rollbackCommandThatFinishedPartial(),
        )

        assertFalse(checkNotNull(honoured.command).success)
        assertFalse(checkNotNull(honoured.command).indeterminate)
        assertTrue(honoured.rolledBack)
    }

    /** The classifier has to ask the command before it honours anything the receipt claims. */
    @Test
    fun receiptGradingRejectsAnIndeterminateCommandUnderEveryReportedStatus() {
        val cutShort = commandKilledByTheTimeoutWrapper()
        val shellDied = ServiceLifecycleController.CommandResult(
            success = false,
            exitCode = null,
            error = "Root shell disconnected",
            indeterminate = true,
        )

        listOf("complete", "partial", "blocked", "error").forEach { wireStatus ->
            val report = fullRollbackReport(wireStatus, mapOf("Z2_RB_FIREWALL_CLEAN" to "0"))
            listOf("timeout" to cutShort, "shellDied" to shellDied).forEach { (label, command) ->
                assertEquals(
                    "$wireStatus/$label",
                    ServiceLifecycleController.FullRollbackOutcome.COMMAND_FAILED,
                    ServiceLifecycleController.gradeFullRollbackReceipt(report, command),
                )
            }
        }
    }

    /** A command that ended on its own terms leaves the grading to the receipt it printed. */
    @Test
    fun receiptGradingKeepsTheReportedStatusWhenTheCommandEndedOnItsOwnTerms() {
        val succeeded = ServiceLifecycleController.CommandResult(success = true, exitCode = 0)

        assertNull(
            ServiceLifecycleController.gradeFullRollbackReceipt(
                fullRollbackReport("complete"),
                succeeded,
            ),
        )
        assertEquals(
            ServiceLifecycleController.FullRollbackOutcome.COMMAND_FAILED,
            ServiceLifecycleController.gradeFullRollbackReceipt(
                fullRollbackReport("complete"),
                rollbackCommandThatFinishedPartial(),
            ),
        )
        mapOf(
            "partial" to ServiceLifecycleController.FullRollbackOutcome.PARTIAL,
            "blocked" to ServiceLifecycleController.FullRollbackOutcome.BLOCKED,
            "error" to ServiceLifecycleController.FullRollbackOutcome.ERROR,
        ).forEach { (wireStatus, expected) ->
            assertEquals(
                wireStatus,
                expected,
                ServiceLifecycleController.gradeFullRollbackReceipt(
                    fullRollbackReport(wireStatus),
                    rollbackCommandThatFinishedPartial(),
                ),
            )
        }
    }

    /**
     * The command axis the receipt matrix never varied: outcome x receipt status x firewall proof
     * x how the command ended. No receipt, under any outcome, may claim a rollback out of a
     * command the transport could not see through to its own exit.
     */
    @Test
    fun rolledBackRequiresACommandThatRanToItsOwnEnd() {
        val commands = linkedMapOf(
            "absent" to null,
            "exit0" to ServiceLifecycleController.CommandResult(success = true, exitCode = 0),
            "exit1" to rollbackCommandThatFinishedPartial(),
            "sigterm" to commandKilledByTheTimeoutWrapper(),
            "shellDied" to ServiceLifecycleController.CommandResult(
                success = false,
                exitCode = null,
                error = "Root shell disconnected",
                indeterminate = true,
            ),
        )

        ServiceLifecycleController.FullRollbackOutcome.entries.forEach { outcome ->
            listOf("complete", "partial", "blocked", "error").forEach { wireStatus ->
                listOf(true, false).forEach { firewallClean ->
                    commands.forEach { (label, command) ->
                        val result = fullRollbackResult(
                            outcome = outcome,
                            status = wireStatus,
                            overrides = mapOf(
                                "Z2_RB_FIREWALL_CLEAN" to if (firewallClean) "1" else "0",
                            ),
                            serviceStatus = ipv6UnverifiedRollbackStatus(),
                            command = command,
                        )
                        val ranToItsOwnEnd = command?.indeterminate != true
                        val expected = ranToItsOwnEnd && when (outcome) {
                            ServiceLifecycleController.FullRollbackOutcome.COMPLETE -> true
                            ServiceLifecycleController.FullRollbackOutcome.PARTIAL ->
                                wireStatus == "partial" && !firewallClean
                            else -> false
                        }

                        assertEquals(
                            "$outcome/$wireStatus/firewall=$firewallClean/$label",
                            expected,
                            result.rolledBack,
                        )
                    }
                }
            }
        }
    }

    /** `timeout 420` reports 124 after SIGTERM, whatever exit status the trapped script chose. */
    private fun commandKilledByTheTimeoutWrapper() = ServiceLifecycleController.CommandResult(
        success = false,
        exitCode = 124,
        error = "Root command timed out",
        rootAccessState = ServiceLifecycleController.RootAccessState.TIMEOUT,
        indeterminate = true,
    )

    /** What `partial()` really leaves behind: a determinate, unsuccessful exit 1. */
    private fun rollbackCommandThatFinishedPartial() = ServiceLifecycleController.CommandResult(
        success = false,
        exitCode = 1,
        error = "Root command exited unsuccessfully",
    )

    private fun fullRollbackReport(
        status: String,
        overrides: Map<String, String> = emptyMap(),
    ): ServiceLifecycleController.FullRollbackReport {
        val parsed = ServiceLifecycleController.parseFullRollbackOutput(
            fullRollbackLines(status = status, overrides = overrides),
        ) as ServiceLifecycleController.FullRollbackParseResult.Valid
        return parsed.report
    }

    private fun fullRollbackResult(
        outcome: ServiceLifecycleController.FullRollbackOutcome,
        status: String = "complete",
        overrides: Map<String, String> = emptyMap(),
        serviceStatus: ServiceLifecycleController.ServiceStatus =
            ServiceLifecycleController.parseStatusCommandResult(
                ServiceLifecycleController.CommandResult(
                    success = false,
                    stdout = stoppedStatusLines(),
                    exitCode = 1,
                ),
            ),
        command: ServiceLifecycleController.CommandResult? = null,
    ): ServiceLifecycleController.FullRollbackResult {
        return ServiceLifecycleController.FullRollbackResult(
            outcome = outcome,
            serviceStatus = serviceStatus,
            report = fullRollbackReport(status, overrides),
            command = command,
        )
    }

    /**
     * The status observation the app really takes right after an IPv6-unverified full rollback.
     *
     * `zapret-full-rollback.sh` publishes `ruleset_verified=0` with `ipv6_active=1` because it
     * refuses to assert "verified clean" about a family it could not re-read. `zapret-status.sh`
     * therefore fails its stopped fast path, sets `IPV6_UNKNOWN=1`, which forces `Z2_OWNED=1`, and
     * grades the payload `degraded` (exit 2) with the `STATUS_DEGRADED` envelope. The lifecycle
     * lock is already released — the app takes this observation outside any lease — so the
     * lifecycle fields read `idle`/`none`, and the queue capabilities survive from the receipt.
     */
    private fun ipv6UnverifiedRollbackStatusLines(): List<String> = listOf(
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
        "Z2_ERROR_DETAIL=Service state is degraded; inspect the lifecycle log for full details",
        "Z2_COMPLETE=1",
    )

    private fun ipv6UnverifiedRollbackStatus(): ServiceLifecycleController.ServiceStatus =
        ServiceLifecycleController.parseStatusCommandResult(
            ServiceLifecycleController.CommandResult(
                success = false,
                stdout = ipv6UnverifiedRollbackStatusLines(),
                exitCode = 2,
            ),
        )

    private fun fullRollbackLines(
        status: String = "complete",
        overrides: Map<String, String> = emptyMap(),
    ): List<String> {
        val values = linkedMapOf(
            "Z2_RB_STATUS" to status,
            "Z2_RB_PROCESS_CLEAN" to "1",
            "Z2_RB_FIREWALL_CLEAN" to "1",
            "Z2_RB_ROLLBACK_ARMED" to "1",
            "Z2_RB_HOSTS_PRESERVED" to "1",
            "Z2_RB_REBOOT_REQUIRED" to "1",
            "Z2_RB_USER_DATA_PRESERVED" to "1",
            "Z2_RB_LEGACY_AMBIGUOUS" to "0",
            "Z2_RB_DIAGNOSTIC" to "full rollback complete; reboot required",
            "Z2_RB_COMPLETE" to "1",
        )
        overrides.forEach { (key, value) -> values[key] = value }
        return values.map { (key, value) -> "$key=$value" }
    }

    /** The exact contract an installed status script uses to reject a newer machine protocol. */
    private fun unsupportedProtocolResult() = ServiceLifecycleController.CommandResult(
        success = false,
        stderr = listOf("unsupported machine protocol"),
        exitCode = 2,
    )

    /** A stopped payload in the exact shape of the protocol [version] it claims to speak. */
    private fun stoppedPayload(version: Int) = ServiceLifecycleController.CommandResult(
        success = false,
        stdout = when (version) {
            6 -> versionSixStatusLines(
                stoppedStatusLines(),
                lifecycleState = "idle",
                chains = 0,
                anchors = 0,
            )
            5 -> versionFiveStatusLines(
                stoppedStatusLines(),
                lifecycleState = "idle",
                chains = 0,
                anchors = 0,
            )
            4 -> versionFourStatusLines(stoppedStatusLines(), lifecycleState = "idle")
            3 -> versionThreeStatusLines(stoppedStatusLines())
            1 -> stoppedStatusLines()
            else -> error("Unsupported machine status protocol $version")
        },
        exitCode = 1,
    )

    private fun healthyStatusLines(): List<String> = listOf(
        "Z2_STATUS=ok",
        "Z2_OWNED=1",
        "Z2_PROCESS=1",
        "Z2_ACTIVE=1",
        "Z2_PID=4242",
        "Z2_PID_VERIFIED=1",
        "Z2_PID_STARTTIME=98765",
        "Z2_OWNER_GENERATION=generation-1",
        "Z2_OWNER_METADATA_VERIFIED=1",
        "Z2_QNUM=200",
        "Z2_IPV4=1",
        "Z2_IPV6=1",
        "Z2_RULES=3",
        "Z2_EXPECTED_RULES=3",
        "Z2_IPV4_RULES=2",
        "Z2_IPV6_RULES=1",
        "Z2_RULESET_VERIFIED=1",
        "Z2_NFQUEUE=1",
        "Z2_QUEUE_BYPASS=1",
        "Z2_UPDATE_BLOCKED=0",
        "Z2_UNINSTALL_TOMBSTONE=0",
        "Z2_COMPLETE=1",
    )

    private fun stoppedStatusLines(): List<String> = listOf(
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
        "Z2_RULESET_VERIFIED=1",
        "Z2_NFQUEUE=0",
        "Z2_QUEUE_BYPASS=0",
        "Z2_UPDATE_BLOCKED=0",
        "Z2_UNINSTALL_TOMBSTONE=0",
        "Z2_COMPLETE=1",
    )

    private fun versionThreeStatusLines(base: List<String>): List<String> =
        base.toMutableList().apply {
            add(0, "Z2_PROTOCOL=3")
            add(lastIndex, "Z2_ERROR_SCHEMA=1")
            add(lastIndex, "Z2_ERROR_STATUS=OK")
            add(lastIndex, "Z2_ERROR_DOMAIN=NONE")
            add(lastIndex, "Z2_ERROR_STAGE=NONE")
            add(lastIndex, "Z2_ERROR_CODE=NONE")
            add(lastIndex, "Z2_ERROR_DETAIL=")
        }

    private fun versionFourStatusLines(
        base: List<String>,
        lifecycleState: String,
        ownerKind: String = "none",
    ): List<String> = versionThreeStatusLines(base)
        .map { if (it == "Z2_PROTOCOL=3") "Z2_PROTOCOL=4" else it }
        .toMutableList()
        .apply {
            add(lastIndex, "Z2_LIFECYCLE_STATE=$lifecycleState")
            add(lastIndex, "Z2_LIFECYCLE_OWNER_KIND=$ownerKind")
        }

    private fun versionFiveStatusLines(
        base: List<String>,
        lifecycleState: String,
        ownerKind: String = "none",
        chains: Int,
        anchors: Int,
    ): List<String> = versionFourStatusLines(base, lifecycleState, ownerKind)
        .map { if (it == "Z2_PROTOCOL=4") "Z2_PROTOCOL=5" else it }
        .toMutableList()
        .apply {
            add(lastIndex, "Z2_CHAINS=$chains")
            add(lastIndex, "Z2_ANCHORS=$anchors")
        }

    private fun versionSixStatusLines(
        base: List<String>,
        lifecycleState: String,
        ownerKind: String = "none",
        chains: Int,
        anchors: Int,
    ): List<String> = versionFiveStatusLines(
        base = base,
        lifecycleState = lifecycleState,
        ownerKind = ownerKind,
        chains = chains,
        anchors = anchors,
    ).map { if (it == "Z2_PROTOCOL=5") "Z2_PROTOCOL=6" else it }

    private fun lifecycleBarrierStatusLines(
        lifecycleState: String,
        ownerKind: String,
        errorCode: String,
    ) = listOf(
        "Z2_PROTOCOL=4",
        "Z2_STATUS=degraded",
        "Z2_OWNED=1",
        "Z2_PROCESS=0",
        "Z2_ACTIVE=0",
        "Z2_PID=",
        "Z2_PID_VERIFIED=0",
        "Z2_PID_STARTTIME=",
        "Z2_OWNER_GENERATION=",
        "Z2_OWNER_METADATA_VERIFIED=0",
        "Z2_QNUM=",
        "Z2_IPV4=0",
        "Z2_IPV6=0",
        "Z2_RULES=0",
        "Z2_EXPECTED_RULES=0",
        "Z2_IPV4_RULES=0",
        "Z2_IPV6_RULES=0",
        "Z2_RULESET_VERIFIED=0",
        "Z2_NFQUEUE=0",
        "Z2_QUEUE_BYPASS=0",
        "Z2_UPDATE_BLOCKED=1",
        "Z2_UNINSTALL_TOMBSTONE=0",
        "Z2_LIFECYCLE_STATE=$lifecycleState",
        "Z2_LIFECYCLE_OWNER_KIND=$ownerKind",
        "Z2_ERROR_SCHEMA=1",
        "Z2_ERROR_STATUS=ERROR",
        "Z2_ERROR_DOMAIN=LIFECYCLE",
        "Z2_ERROR_STAGE=LIFECYCLE_OBSERVE",
        "Z2_ERROR_CODE=$errorCode",
        "Z2_ERROR_DETAIL=Lifecycle observation is blocked",
        "Z2_COMPLETE=1",
    )
}

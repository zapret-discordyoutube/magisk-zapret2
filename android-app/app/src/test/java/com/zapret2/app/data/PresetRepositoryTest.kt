package com.zapret2.app.data

import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PresetRepositoryTest {

    @Test
    fun machineDiscoveryFixture_exposes20AndQuarantines49WithTypedCounts() {
        val lines = buildList {
            repeat(20) { index -> add("Z2_PRESET\tVALID\tOK\tvalid-$index.txt") }
            repeat(30) { index -> add("Z2_PRESET\tQUARANTINED\tDEPENDENCY_MISSING\tmissing-$index.txt") }
            repeat(19) { index -> add("Z2_PRESET\tQUARANTINED\tUNSAFE_DEPENDENCY_PATH\tunsafe-$index.txt") }
            add("Z2_PRESET_SUMMARY\t1\tvalid=20\tquarantined=49\ttotal=69")
        }

        val discovery = requireNotNull(PresetMachineProtocol.parseDiscovery(lines))

        assertEquals(20, discovery.available.size)
        assertEquals(49, discovery.quarantinedCount)
        assertEquals(30, discovery.issueCounts[PresetIssue.DEPENDENCY_MISSING])
        assertEquals(19, discovery.issueCounts[PresetIssue.UNSAFE_DEPENDENCY_PATH])
    }

    @Test
    fun runtimeDiscovery_acceptsReadyCatalogWithoutRequalifyingPublishedPresets() {
        val discovery = requireNotNull(
            PresetMachineProtocol.parseDiscovery(
                listOf(
                    "Z2_PRESET\tREADY\tOK\tone.txt",
                    "Z2_PRESET\tREADY\tOK\ttwo.txt",
                    "Z2_PRESET_SUMMARY\t2\tready=2\tquarantined=0\ttotal=2",
                ),
            ),
        )

        assertEquals(listOf("one.txt", "two.txt"), discovery.available.map(PresetEntry::fileName))
        assertEquals(0, discovery.quarantinedCount)
    }

    @Test
    fun machineProtocol_failsClosedOnCountMismatchDuplicateOrUnexpectedLine() {
        assertNull(
            PresetMachineProtocol.parseDiscovery(
                listOf(
                    "Z2_PRESET\tVALID\tOK\tone.txt",
                    "Z2_PRESET_SUMMARY\t1\tvalid=2\tquarantined=0\ttotal=2",
                ),
            ),
        )
        assertNull(
            PresetMachineProtocol.parseDiscovery(
                listOf(
                    "Z2_PRESET\tVALID\tOK\tone.txt",
                    "Z2_PRESET\tVALID\tOK\tone.txt",
                    "Z2_PRESET_SUMMARY\t1\tvalid=2\tquarantined=0\ttotal=2",
                ),
            ),
        )
        assertNull(PresetMachineProtocol.parseDiscovery(listOf("diagnostic noise")))
    }

    @Test
    fun validationProtocol_acceptsExactLogicalNameAndTypedReason() {
        assertEquals(
            PresetValidation.Compatible,
            PresetMachineProtocol.parseValidation(
                listOf("Z2_PRESET_VALIDATION\t1\tOK\tgood.txt"),
                "good.txt",
            ),
        )
        assertEquals(
            PresetValidation.Quarantined(PresetIssue.DEPENDENCY_SYMLINK),
            PresetMachineProtocol.parseValidation(
                listOf("Z2_PRESET_VALIDATION\t0\tDEPENDENCY_SYMLINK\tgood.txt"),
                "good.txt",
            ),
        )
        assertEquals(
            PresetValidation.Quarantined(PresetIssue.FORBIDDEN_IPCACHE_OPTION),
            PresetMachineProtocol.parseValidation(
                listOf("Z2_PRESET_VALIDATION\t0\tFORBIDDEN_IPCACHE_OPTION\tgood.txt"),
                "good.txt",
            ),
        )
        assertEquals(
            PresetValidation.ProtocolFailure,
            PresetMachineProtocol.parseValidation(
                listOf("Z2_PRESET_VALIDATION\t1\tOK\tother.txt"),
                "good.txt",
            ),
        )
    }

    @Test
    fun previewProtocol_preservesExactArgumentBoundariesAndPortUnion() {
        val outcome = PresetMachineProtocol.parsePreview(
            listOf(
                "Z2_COMMAND_PREVIEW\t1\tgood.txt\tTCP=80,443\tUDP=443,3478,5349,19302",
                "Z2_COMMAND_EXECUTABLE\t/data/adb/modules/zapret2/zapret2/nfqws2",
                "Z2_COMMAND_ARGUMENT\t--qnum=200",
                "Z2_COMMAND_ARGUMENT\t--fwmark=0x40000000",
                "Z2_COMMAND_ARGUMENT\t--uid=0:0",
                "Z2_COMMAND_ARGUMENT\t--name=profile with spaces",
                "Z2_COMMAND_SUMMARY\t1\tcount=4",
            ),
            "good.txt",
        )

        val preview = (outcome as PresetPreviewOutcome.Ready).preview
        assertEquals(listOf("--qnum=200", "--fwmark=0x40000000", "--uid=0:0", "--name=profile with spaces"), preview.arguments)
        assertEquals("80,443", preview.tcpPorts)
        assertEquals("443,3478,5349,19302", preview.udpPorts)
        assertTrue(preview.rendered.contains("'--name=profile with spaces'"))
    }

    @Test
    fun previewProtocol_failsClosedOnCountMismatchAndReturnsTypedRejection() {
        assertEquals(
            PresetPreviewOutcome.Failed,
            PresetMachineProtocol.parsePreview(
                listOf(
                    "Z2_COMMAND_PREVIEW\t1\tgood.txt\tTCP=443\tUDP=",
                    "Z2_COMMAND_EXECUTABLE\t/data/nfqws2",
                    "Z2_COMMAND_ARGUMENT\t--qnum=200",
                    "Z2_COMMAND_SUMMARY\t1\tcount=2",
                ),
                "good.txt",
            ),
        )
        assertEquals(
            PresetPreviewOutcome.Rejected(PresetIssue.FORBIDDEN_IPCACHE_OPTION),
            PresetMachineProtocol.parsePreview(
                listOf("Z2_COMMAND_PREVIEW\t0\tFORBIDDEN_IPCACHE_OPTION\tgood.txt"),
                "good.txt",
            ),
        )
    }

    @Test
    fun applyProtocol_projectsACommittedTransactionOntoItsExactOutcome() {
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.Applied),
            PresetMachineProtocol.parseApply(applyPayload(), "good.txt"),
        )
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.Saved),
            PresetMachineProtocol.parseApply(
                applyPayload(outcome = "SAVED", wasRunning = "0"),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Reported(
                PresetMutationOutcome.Rejected(PresetIssue.FORBIDDEN_IPCACHE_OPTION),
            ),
            PresetMachineProtocol.parseApply(
                applyPayload(
                    outcome = "REJECTED",
                    issue = "FORBIDDEN_IPCACHE_OPTION",
                    committed = "0",
                    wasRunning = "0",
                    error = failedApplyEnvelope("CONFIG", "FORBIDDEN_IPCACHE_OPTION", "APPLY_VALIDATE"),
                ),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.RestartFailedRolledBack),
            PresetMachineProtocol.parseApply(
                applyPayload(
                    outcome = "RESTART_FAILED_ROLLED_BACK",
                    committed = "0",
                    error = failedApplyEnvelope("PROCESS", "PROCESS_LAUNCH_FAILED", "START_LAUNCH"),
                ),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.RollbackFailed),
            PresetMachineProtocol.parseApply(
                applyPayload(
                    outcome = "ROLLBACK_FAILED",
                    error = failedApplyEnvelope("PROCESS", "PROCESS_LAUNCH_FAILED", "START_LAUNCH"),
                ),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.IoFailed),
            PresetMachineProtocol.parseApply(
                applyPayload(
                    outcome = "WRITE_FAILED",
                    committed = "0",
                    error = failedApplyEnvelope("CONFIG", "RUNTIME_COMMIT_FAILED", "RUNTIME_COMMIT"),
                ),
                "good.txt",
            ),
        )
    }

    @Test
    fun applyProtocol_reportsAnOlderModuleAsUnsupportedRatherThanAsAFailure() {
        assertEquals(
            PresetApplyTransaction.Unsupported,
            PresetMachineProtocol.parseApply(listOf("Z2_APPLY_UNSUPPORTED=1"), "good.txt"),
        )
        // The sentinel only counts alone: mixed with a payload it is not a missing entry point.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(
                listOf("Z2_APPLY_UNSUPPORTED=1") + applyPayload(),
                "good.txt",
            ),
        )
    }

    @Test
    fun applyProtocol_failsClosedOnTruncatedInconsistentOrForeignPayloads() {
        val truncated = applyPayload().dropLast(1)
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(truncated, "good.txt"),
        )
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(applyPayload(schema = "2"), "good.txt"),
        )
        // A committed outcome may never travel with a failure envelope.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(
                applyPayload(error = failedApplyEnvelope("LIFECYCLE", "LIFECYCLE_FAILED", "APPLY")),
                "good.txt",
            ),
        )
        // Nor may a refusal travel without one.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(
                applyPayload(outcome = "REJECTED", issue = "PRESET_MISSING", committed = "0"),
                "good.txt",
            ),
        )
        // An applied preset that the module says was never published is not applied.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(applyPayload(committed = "0"), "good.txt"),
        )
        // A committed apply on a service the module says was down is self-contradictory.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(applyPayload(wasRunning = "0"), "good.txt"),
        )
        // The answer must be about the preset that was requested.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(applyPayload(), "other.txt"),
        )
        // An outcome only a newer module knows is never guessed at.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(applyPayload(outcome = "PARTIALLY_APPLIED"), "good.txt"),
        )
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(applyPayload() + listOf("Z2_UNEXPECTED=1"), "good.txt"),
        )
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(emptyList(), "good.txt"),
        )
    }

    @Test
    fun applyProtocol_acceptsTheUnsafeNameRefusalWithoutEchoingTheRequest() {
        assertEquals(
            PresetApplyTransaction.Reported(
                PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME),
            ),
            PresetMachineProtocol.parseApply(
                applyPayload(
                    outcome = "REJECTED",
                    issue = "UNSAFE_PRESET_NAME",
                    preset = "",
                    previous = "",
                    committed = "0",
                    wasRunning = "0",
                    error = failedApplyEnvelope("CONFIG", "UNSAFE_PRESET_NAME", "APPLY_REQUEST"),
                ),
                "../escape.txt",
            ),
        )
        // Every other outcome must still name the preset it acted on.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseApply(applyPayload(preset = ""), "good.txt"),
        )
    }

    @Test
    fun saveProtocol_projectsEveryContentOutcomeOntoItsExactResult() {
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.Saved),
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SAVED", committed = "0", wasRunning = "1"),
                "good.txt",
            ),
        )
        // The same success also describes an apply-mode save on a service the user had stopped.
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.Saved),
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SAVED", committed = "1", wasRunning = "0"),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.Applied),
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "APPLIED", committed = "0", wasRunning = "1"),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.SavedAndApplied),
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SAVED_AND_APPLIED", committed = "1", wasRunning = "1"),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.SourceChanged),
            PresetMachineProtocol.parseSave(sourceChangedPayload(), "good.txt"),
        )
        assertEquals(
            PresetApplyTransaction.Reported(
                PresetMutationOutcome.Rejected(PresetIssue.NFQWS_DRY_RUN_FAILED),
            ),
            PresetMachineProtocol.parseSave(
                applyPayload(
                    outcome = "REJECTED",
                    issue = "NFQWS_DRY_RUN_FAILED",
                    committed = "0",
                    wasRunning = "0",
                    error = failedApplyEnvelope("CONFIG", "NFQWS_DRY_RUN_FAILED", "APPLY_VALIDATE"),
                ),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Reported(
                PresetMutationOutcome.Rejected(PresetIssue.PRESET_SYMLINK),
            ),
            PresetMachineProtocol.parseSave(
                applyPayload(
                    outcome = "REJECTED",
                    issue = "PRESET_SYMLINK",
                    committed = "0",
                    wasRunning = "0",
                    error = failedApplyEnvelope("CONFIG", "UNSAFE_PRESET_FILE", "APPLY_SAVE_TARGET"),
                ),
                "good.txt",
            ),
        )
        listOf(
            "WRITE_FAILED_ROLLED_BACK" to PresetMutationOutcome.WriteFailedRolledBack,
            "RESTART_FAILED_ROLLED_BACK" to PresetMutationOutcome.RestartFailedRolledBack,
            "ROLLBACK_FAILED" to PresetMutationOutcome.RollbackFailed,
            "IO_FAILED" to PresetMutationOutcome.IoFailed,
            "BLOCKED" to PresetMutationOutcome.Blocked,
        ).forEach { (wire, outcome) ->
            assertEquals(
                PresetApplyTransaction.Reported(outcome),
                PresetMachineProtocol.parseSave(
                    applyPayload(
                        outcome = wire,
                        committed = "0",
                        error = failedApplyEnvelope("LIFECYCLE", "LIFECYCLE_FAILED", "APPLY_SAVE"),
                    ),
                    "good.txt",
                ),
            )
        }
    }

    @Test
    fun saveProtocol_reportsAModuleWithoutTheSaveEntryPointAsUnsupported() {
        assertEquals(
            PresetApplyTransaction.Unsupported,
            PresetMachineProtocol.parseSave(listOf("Z2_APPLY_UNSUPPORTED=1"), "good.txt"),
        )
        // A generation that predates --save-content refuses the argument count with a complete,
        // valid envelope. The app proved the name before the round trip, so that refusal cannot be
        // about the name and can only mean the entry point is missing.
        assertEquals(
            PresetApplyTransaction.Unsupported,
            PresetMachineProtocol.parseSave(olderModuleRefusal(), "good.txt"),
        )
        // The same refusal from a stage this app does own is still a refusal, not a fallback.
        assertEquals(
            PresetApplyTransaction.Reported(
                PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME),
            ),
            PresetMachineProtocol.parseSave(
                applyPayload(
                    outcome = "REJECTED",
                    issue = "UNSAFE_PRESET_NAME",
                    preset = "good.txt",
                    committed = "0",
                    wasRunning = "0",
                    error = failedApplyEnvelope("CONFIG", "UNSAFE_PRESET_NAME", "APPLY_REQUEST"),
                ),
                "good.txt",
            ),
        )
    }

    @Test
    fun saveProtocol_failsClosedOnTruncatedInconsistentOrForeignPayloads() {
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SAVED", committed = "0").dropLast(1),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SAVED", schema = "2", committed = "0"),
                "good.txt",
            ),
        )
        // A saved-and-applied content change must have replaced a running daemon.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SAVED_AND_APPLIED", committed = "1", wasRunning = "0"),
                "good.txt",
            ),
        )
        // ... and must say the selection moved; an unchanged selection is a plain apply.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SAVED_AND_APPLIED", committed = "0", wasRunning = "1"),
                "good.txt",
            ),
        )
        // An applied content change never moved the selection.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "APPLIED", committed = "1", wasRunning = "1"),
                "good.txt",
            ),
        )
        // A success may never travel with a failure envelope.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(
                    outcome = "SAVED",
                    committed = "0",
                    error = failedApplyEnvelope("LIFECYCLE", "LIFECYCLE_FAILED", "APPLY_SAVE"),
                ),
                "good.txt",
            ),
        )
        // A refused source is a failure that committed nothing and carries no typed issue.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SOURCE_CHANGED", committed = "0", wasRunning = "0"),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(sourceChangedPayload(committed = "1"), "good.txt"),
        )
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                sourceChangedPayload(issue = "PRESET_SOURCE_CHANGED"),
                "good.txt",
            ),
        )
        // A refusal must still name why it refused.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(
                    outcome = "REJECTED",
                    committed = "0",
                    wasRunning = "0",
                    error = failedApplyEnvelope("CONFIG", "PRESET_UNREADABLE", "APPLY_VALIDATE"),
                ),
                "good.txt",
            ),
        )
        // The answer must be about the preset that was requested.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SAVED", committed = "0"),
                "other.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "SAVED", preset = "", committed = "0"),
                "good.txt",
            ),
        )
        // An outcome only a newer module knows is never guessed at.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(outcome = "PARTIALLY_SAVED", committed = "0"),
                "good.txt",
            ),
        )
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(emptyList(), "good.txt"),
        )
    }

    @Test
    fun saveProtocol_reportsItsOwnArgumentDefectWithoutRequiringTheEchoedName() {
        assertEquals(
            PresetApplyTransaction.Reported(PresetMutationOutcome.IoFailed),
            PresetMachineProtocol.parseSave(
                applyPayload(
                    outcome = "IO_FAILED",
                    preset = "",
                    previous = "",
                    committed = "0",
                    wasRunning = "0",
                    error = failedApplyEnvelope("CONFIG", "INVALID_ARGUMENTS", "APPLY_SAVE_REQUEST"),
                ),
                "good.txt",
            ),
        )
        // Every other failure must still name the preset it acted on.
        assertEquals(
            PresetApplyTransaction.Indeterminate,
            PresetMachineProtocol.parseSave(
                applyPayload(
                    outcome = "IO_FAILED",
                    preset = "",
                    previous = "",
                    committed = "0",
                    wasRunning = "0",
                    error = failedApplyEnvelope("STATE", "STATE_UNAVAILABLE", "APPLY_SAVE_BACKUP"),
                ),
                "good.txt",
            ),
        )
    }

    private fun sourceChangedPayload(
        issue: String = "NONE",
        committed: String = "0",
    ): List<String> = applyPayload(
        outcome = "SOURCE_CHANGED",
        issue = issue,
        committed = committed,
        wasRunning = "0",
        error = failedApplyEnvelope("CONFIG", "PRESET_SOURCE_CHANGED", "APPLY_SAVE_CAS"),
    )

    private fun olderModuleRefusal(): List<String> = applyPayload(
        outcome = "REJECTED",
        issue = "UNSAFE_PRESET_NAME",
        preset = "",
        previous = "",
        committed = "0",
        wasRunning = "0",
        error = failedApplyEnvelope("CONFIG", "INVALID_ARGUMENTS", "APPLY_REQUEST"),
    )

    private fun applyPayload(
        schema: String = "1",
        outcome: String = "APPLIED",
        issue: String = "NONE",
        preset: String = "good.txt",
        previous: String = "old.txt",
        committed: String = "1",
        wasRunning: String = "1",
        error: List<String> = cleanApplyEnvelope(),
    ): List<String> = listOf(
        "Z2_APPLY_SCHEMA=$schema",
        "Z2_APPLY_OUTCOME=$outcome",
        "Z2_APPLY_ISSUE=$issue",
        "Z2_APPLY_PRESET=$preset",
        "Z2_APPLY_PREVIOUS_PRESET=$previous",
        "Z2_APPLY_CONFIG_COMMITTED=$committed",
        "Z2_APPLY_SERVICE_WAS_RUNNING=$wasRunning",
    ) + error + listOf("Z2_APPLY_COMPLETE=1")

    private fun cleanApplyEnvelope(): List<String> = listOf(
        "Z2_ERROR_SCHEMA=1",
        "Z2_ERROR_STATUS=OK",
        "Z2_ERROR_DOMAIN=NONE",
        "Z2_ERROR_STAGE=NONE",
        "Z2_ERROR_CODE=NONE",
        "Z2_ERROR_DETAIL=",
    )

    private fun failedApplyEnvelope(domain: String, code: String, stage: String): List<String> =
        listOf(
            "Z2_ERROR_SCHEMA=1",
            "Z2_ERROR_STATUS=ERROR",
            "Z2_ERROR_DOMAIN=$domain",
            "Z2_ERROR_STAGE=$stage",
            "Z2_ERROR_CODE=$code",
            "Z2_ERROR_DETAIL=the module refused",
        )

    @Test
    fun preview_stagesDraftUnderMutationGateAndAlwaysRemovesIt() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Compatible)
        val gate = RecordingGate()
        val repository = testRepository(runner, gate)

        val outcome = repository.preview("custom.txt", "unsaved draft")

        assertTrue(outcome is PresetPreviewOutcome.Ready)
        assertEquals(1, gate.calls)
        assertEquals(listOf("write-candidate", "preview", "remove"), runner.events)
        assertFalse(runner.files.keys.any { it.startsWith("_") })
    }

    @Test
    fun applyTrustsAlreadyQualifiedPresetAndDoesNotRepeatDeepValidation() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Quarantined(PresetIssue.DEPENDENCY_MISSING))
        val gate = RecordingGate()
        val repository = testRepository(runner, gate)

        val result = repository.apply("published.txt")

        assertEquals(PresetMutationOutcome.Applied, result)
        assertEquals(1, gate.calls)
        assertEquals(0, runner.validationCalls)
        assertEquals(1, runner.configWrites)
        assertEquals(1, runner.restartCalls)
    }

    @Test
    fun repositoryPublishesRevisionOnlyAfterACommittedPresetMutation() = runBlocking {
        val revision = PresetStateRevision()
        val runner = FakePresetRunner(validation = PresetValidation.Compatible)
        val repository = testRepository(runner, RecordingGate(), revision)

        assertEquals(0L, revision.revision.value)
        assertEquals(PresetMutationOutcome.Applied, repository.apply("published.txt"))
        assertEquals(1L, revision.revision.value)

        assertEquals(
            PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME),
            repository.apply("../unsafe.txt"),
        )
        assertEquals(1L, revision.revision.value)

        runner.saveTransaction = PresetApplyTransaction.Reported(PresetMutationOutcome.Saved)
        assertEquals(
            PresetMutationOutcome.Saved,
            repository.save("inactive.txt", null, "content", applyAfterSave = false),
        )
        assertEquals(2L, revision.revision.value)
    }

    @Test
    fun save_rejectsCandidateBeforeAtomicReplaceAndLeavesTargetUntouched() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Quarantined(PresetIssue.NO_VALID_OPTIONS))
        runner.files["custom.txt"] = "old"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old", "invalid", applyAfterSave = true)

        assertEquals(PresetMutationOutcome.Rejected(PresetIssue.NO_VALID_OPTIONS), result)
        assertEquals("old", runner.files["custom.txt"])
        assertEquals(0, runner.replaceCalls)
        assertEquals(0, runner.configWrites)
        assertEquals(
            listOf(
                "write-candidate",
                "save-transaction",
                "remove",
                "snapshot-file",
                "snapshot-config",
                "write-candidate",
                "validate",
                "remove",
            ),
            runner.events,
        )
    }

    @Test
    fun save_rejectsOversizedContentBeforeSnapshotOrWrite() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Compatible)
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save(
            "custom.txt",
            expectedContent = null,
            content = "a".repeat(PresetContentPolicy.MAX_BYTES + 1),
            applyAfterSave = false,
        )

        assertEquals(PresetMutationOutcome.Rejected(PresetIssue.PRESET_TOO_LARGE), result)
        assertTrue(runner.events.isEmpty())
    }

    @Test
    fun saveAndApply_restartFailureRestoresConfigAndOldFileContent() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Compatible, restartSucceeds = false)
        runner.config = ActivePresetConfig("old.txt")
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = true)

        assertEquals(PresetMutationOutcome.RestartFailedRolledBack, result)
        assertEquals(ActivePresetConfig("old.txt"), runner.config)
        assertEquals("old content", runner.files["custom.txt"])
        assertEquals(2, runner.configWrites)
        assertEquals(1, runner.restartCalls)
        assertTrue(runner.events.indexOf("validate") < runner.events.indexOf("replace"))
    }

    @Test
    fun apply_restartExceptionRestoresPreviousConfig() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            restartFailure = IllegalStateException("restart failed"),
        )
        runner.config = ActivePresetConfig("old.txt")
        val repository = testRepository(runner, RecordingGate())

        val result = repository.apply("good.txt")

        assertEquals(PresetMutationOutcome.RestartFailedRolledBack, result)
        assertEquals(ActivePresetConfig("old.txt"), runner.config)
        assertEquals(2, runner.configWrites)
    }

    @Test
    fun saveAndApply_restartExceptionRestoresConfigAndOldFileContent() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            restartFailure = IllegalStateException("restart failed"),
        )
        runner.config = ActivePresetConfig("old.txt")
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = true)

        assertEquals(PresetMutationOutcome.RestartFailedRolledBack, result)
        assertEquals(ActivePresetConfig("old.txt"), runner.config)
        assertEquals("old content", runner.files["custom.txt"])
    }

    @Test
    fun saveAndApply_newFileRestartFailureRestoresNonExistence() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Compatible, restartSucceeds = false)
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("new.txt", null, "valid", applyAfterSave = true)

        assertEquals(PresetMutationOutcome.RestartFailedRolledBack, result)
        assertFalse("new file must be removed by rollback", runner.files.containsKey("new.txt"))
    }

    @Test
    fun ambiguousReplace_restoresPreviousPresetInsteadOfReportingPlainIoFailure() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            replaceReturns = false,
        )
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = false)

        assertEquals(PresetMutationOutcome.WriteFailedRolledBack, result)
        assertEquals("old content", runner.files["custom.txt"])
    }

    @Test
    fun ambiguousReplace_reportsRollbackFailureWhenPreviousPresetCannotBeRestored() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            replaceReturns = false,
            restoreSucceeds = false,
        )
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = false)

        assertEquals(PresetMutationOutcome.RollbackFailed, result)
        assertEquals("new content\n", runner.files["custom.txt"])
    }

    @Test
    fun candidateWriteException_removesAmbiguousCandidateAndPreservesTarget() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            writeCandidateFailure = IllegalStateException("write result lost"),
        )
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = false)

        assertEquals(PresetMutationOutcome.IoFailed, result)
        assertEquals("old content", runner.files["custom.txt"])
        assertFalse(runner.files.keys.any { it.startsWith("_") })
    }

    @Test
    fun candidateValidationException_removesCandidateAndPreservesTarget() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            validationFailure = IllegalStateException("validator unavailable"),
        )
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = false)

        assertEquals(PresetMutationOutcome.IoFailed, result)
        assertEquals("old content", runner.files["custom.txt"])
        assertFalse(runner.files.keys.any { it.startsWith("_") })
    }

    @Test
    fun replaceException_restoresPreviousPresetInsteadOfEscapingCleanup() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            replaceFailure = IllegalStateException("replace result lost"),
        )
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = false)

        assertEquals(PresetMutationOutcome.WriteFailedRolledBack, result)
        assertEquals("old content", runner.files["custom.txt"])
    }

    @Test
    fun postReplaceSnapshotException_restoresPreviousPreset() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            snapshotFileFailureOnCall = 2,
        )
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = false)

        assertEquals(PresetMutationOutcome.WriteFailedRolledBack, result)
        assertEquals("old content", runner.files["custom.txt"])
    }

    @Test
    fun activeConfigWriteException_restoresPreviousConfigAndPreset() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            configWriteFailureOnCall = 1,
        )
        runner.config = ActivePresetConfig("old.txt")
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = true)

        assertEquals(PresetMutationOutcome.WriteFailedRolledBack, result)
        assertEquals(ActivePresetConfig("old.txt"), runner.config)
        assertEquals("old content", runner.files["custom.txt"])
    }

    @Test
    fun configRollbackException_doesNotSkipPresetFileRestore() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            restartSucceeds = false,
            configWriteFailureOnCall = 2,
        )
        runner.config = ActivePresetConfig("old.txt")
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = true)

        assertEquals(PresetMutationOutcome.RollbackFailed, result)
        assertEquals("old content", runner.files["custom.txt"])
        assertTrue(runner.events.contains("restore-file"))
    }

    @Test
    fun save_rejectsChangedSourceBeforeCandidatePublication() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Compatible)
        runner.files["custom.txt"] = "changed externally"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save(
            fileName = "custom.txt",
            expectedContent = "editor baseline",
            content = "draft",
            applyAfterSave = false,
        )

        assertEquals(PresetMutationOutcome.SourceChanged, result)
        assertEquals("changed externally", runner.files["custom.txt"])
        assertEquals(0, runner.replaceCalls)
    }

    @Test
    fun olderModuleWithoutTheTransactionStillAppliesThroughTheStepwiseFallback() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Compatible, restartSucceeds = true)
        val repository = testRepository(runner, RecordingGate())

        val result = repository.apply("good.txt")

        assertEquals(PresetMutationOutcome.Applied, result)
        assertEquals(ActivePresetConfig("good.txt"), runner.config)
        assertEquals(
            listOf("apply-transaction", "snapshot-config", "write-config", "restart"),
            runner.events,
        )
    }

    @Test
    fun apply_usesOneModuleTransactionAndProjectsItsOutcomeWithoutRebuildingTheSteps() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            applyTransaction = PresetApplyTransaction.Reported(PresetMutationOutcome.Applied),
        )
        val gate = RecordingGate()
        val repository = testRepository(runner, gate)

        val result = repository.apply("good.txt")

        assertEquals(PresetMutationOutcome.Applied, result)
        assertEquals(1, gate.calls)
        assertEquals(listOf("apply-transaction"), runner.events)
        assertEquals(0, runner.configWrites)
        assertEquals(0, runner.restartCalls)
        assertEquals(0, runner.validationCalls)
    }

    @Test
    fun apply_projectsEveryRefusalAndRollbackOutcomeWithoutSofteningIt() = runBlocking {
        val projected = listOf(
            PresetMutationOutcome.Saved,
            PresetMutationOutcome.Rejected(PresetIssue.NFQWS_DRY_RUN_FAILED),
            PresetMutationOutcome.WriteFailedRolledBack,
            PresetMutationOutcome.RestartFailedRolledBack,
            PresetMutationOutcome.RollbackFailed,
            PresetMutationOutcome.Blocked,
            PresetMutationOutcome.IoFailed,
        )

        projected.forEach { outcome ->
            val runner = FakePresetRunner(
                validation = PresetValidation.Compatible,
                applyTransaction = PresetApplyTransaction.Reported(outcome),
            )
            val repository = testRepository(runner, RecordingGate())

            assertEquals(outcome, repository.apply("good.txt"))
            assertEquals(listOf("apply-transaction"), runner.events)
        }
    }

    @Test
    fun apply_resolvesAnUnprovenTransactionFromThePublishedSelection() = runBlocking {
        val committed = FakePresetRunner(
            validation = PresetValidation.Compatible,
            applyTransaction = PresetApplyTransaction.Indeterminate,
        )
        committed.config = ActivePresetConfig("good.txt")
        val untouched = FakePresetRunner(
            validation = PresetValidation.Compatible,
            applyTransaction = PresetApplyTransaction.Indeterminate,
        )
        untouched.config = ActivePresetConfig("old.txt")

        assertEquals(
            PresetMutationOutcome.RollbackFailed,
            testRepository(committed, RecordingGate()).apply("good.txt"),
        )
        assertEquals(0, committed.configWrites)
        assertEquals(0, committed.restartCalls)
        assertEquals(
            PresetMutationOutcome.IoFailed,
            testRepository(untouched, RecordingGate()).apply("good.txt"),
        )
        assertEquals(0, untouched.configWrites)
    }

    @Test
    fun apply_acceptsALostAnswerOnlyWhenTheLiveGenerationIsTheOneThisLeaseStamped() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            applyTransaction = PresetApplyTransaction.Indeterminate,
            applyIsProven = true,
        )
        runner.config = ActivePresetConfig("good.txt")
        val repository = testRepository(runner, RecordingGate())

        val result = repository.apply("good.txt")

        assertEquals(PresetMutationOutcome.Applied, result)
        assertEquals(listOf("apply-transaction", "snapshot-config", "prove-commit"), runner.events)
        assertEquals(0, runner.configWrites)
        assertEquals(0, runner.restartCalls)
    }

    @Test
    fun apply_neverReplaysALostTransactionAsAFreshAttempt() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            applyTransactionFailure = IllegalStateException("root transport died"),
        )
        runner.config = ActivePresetConfig("good.txt")
        val repository = testRepository(runner, RecordingGate())

        val result = repository.apply("good.txt")

        assertEquals(PresetMutationOutcome.RollbackFailed, result)
        assertEquals(1, runner.applyTransactionCalls)
        assertEquals(0, runner.configWrites)
        assertEquals(0, runner.restartCalls)
    }

    @Test
    fun apply_rejectsAnUnsafeNameBeforeReachingTheModule() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Compatible)
        val repository = testRepository(runner, RecordingGate())

        val result = repository.apply("../escape.txt")

        assertEquals(PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME), result)
        assertEquals(0, runner.applyTransactionCalls)
        assertTrue(runner.events.isEmpty())
    }

    @Test
    fun save_usesOneModuleTransactionAndProjectsItsOutcomeWithoutRebuildingTheSteps() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            saveTransaction = PresetApplyTransaction.Reported(PresetMutationOutcome.SavedAndApplied),
        )
        runner.files["custom.txt"] = "old content"
        val gate = RecordingGate()
        val repository = testRepository(runner, gate)

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = true)

        assertEquals(PresetMutationOutcome.SavedAndApplied, result)
        assertEquals(1, gate.calls)
        assertEquals(listOf("write-candidate", "save-transaction"), runner.events)
        assertEquals(0, runner.validationCalls)
        assertEquals(0, runner.replaceCalls)
        assertEquals(0, runner.configWrites)
        assertEquals(0, runner.restartCalls)
        val request = runner.saveTransactionRequests.single()
        assertEquals("custom.txt", request.fileName)
        assertTrue(request.candidateFileName.startsWith("_custom.candidate."))
        assertTrue(request.applyAfterSave)
        assertEquals(sha256Hex("old content"), request.expectedDigest)
    }

    @Test
    fun save_statesTheContentIdentityCanonicallyAndSignalsAnAbsentTargetAsMissing() = runBlocking {
        val digested = FakePresetRunner(
            validation = PresetValidation.Compatible,
            saveTransaction = PresetApplyTransaction.Reported(PresetMutationOutcome.Saved),
        )
        val created = FakePresetRunner(
            validation = PresetValidation.Compatible,
            saveTransaction = PresetApplyTransaction.Reported(PresetMutationOutcome.Saved),
        )

        testRepository(digested, RecordingGate())
            .save("custom.txt", "old content\r\n\r\n", "new content", applyAfterSave = false)
        testRepository(created, RecordingGate())
            .save("new.txt", null, "fresh content", applyAfterSave = false)

        // Trailing blank lines and CRLF are the same content generation on both sides of the wire.
        assertEquals(sha256Hex("old content"), digested.saveTransactionRequests.single().expectedDigest)
        assertNull(created.saveTransactionRequests.single().expectedDigest)
        assertFalse(created.saveTransactionRequests.single().applyAfterSave)
    }

    @Test
    fun save_projectsEveryRefusalAndRollbackOutcomeWithoutSofteningIt() = runBlocking {
        val projected = listOf(
            PresetMutationOutcome.Saved,
            PresetMutationOutcome.Applied,
            PresetMutationOutcome.SavedAndApplied,
            PresetMutationOutcome.SourceChanged,
            PresetMutationOutcome.Rejected(PresetIssue.PRESET_SYMLINK),
            PresetMutationOutcome.WriteFailedRolledBack,
            PresetMutationOutcome.RestartFailedRolledBack,
            PresetMutationOutcome.RollbackFailed,
            PresetMutationOutcome.Blocked,
            PresetMutationOutcome.IoFailed,
        )

        projected.forEach { outcome ->
            val runner = FakePresetRunner(
                validation = PresetValidation.Compatible,
                saveTransaction = PresetApplyTransaction.Reported(outcome),
            )
            runner.files["custom.txt"] = "old content"
            val repository = testRepository(runner, RecordingGate())

            val result = repository.save("custom.txt", "old content", "new", applyAfterSave = true)

            assertEquals(outcome, result)
            assertEquals(listOf("write-candidate", "save-transaction"), runner.events)
            assertEquals("old content", runner.files["custom.txt"])
        }
    }

    @Test
    fun olderModuleWithoutTheSaveTransactionStillSavesThroughTheStepwiseFallback() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Compatible)
        runner.config = ActivePresetConfig("old.txt")
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = false)

        assertEquals(PresetMutationOutcome.Saved, result)
        assertEquals("new content\n", runner.files["custom.txt"])
        assertEquals(1, runner.saveTransactionCalls)
        assertEquals(
            listOf(
                "write-candidate",
                "save-transaction",
                "remove",
                "snapshot-file",
                "snapshot-config",
                "write-candidate",
                "validate",
                "replace",
                "snapshot-file",
            ),
            runner.events,
        )
        assertFalse(runner.files.keys.any { it.startsWith("_") })
    }

    @Test
    fun save_resolvesAnUnprovenTransactionFromThePublishedContentAndSelection() = runBlocking {
        // The target still carries the generation the editor started from: nothing was published.
        val untouched = indeterminateSaveRunner(target = "old content")
        assertEquals(
            PresetMutationOutcome.IoFailed,
            testRepository(untouched, RecordingGate())
                .save("custom.txt", "old content", "new content", applyAfterSave = true),
        )
        assertEquals(0, untouched.configWrites)
        assertEquals(0, untouched.restartCalls)

        // The target carries content neither side asked for.
        val foreign = indeterminateSaveRunner(target = "somebody else's edit")
        assertEquals(
            PresetMutationOutcome.RollbackFailed,
            testRepository(foreign, RecordingGate())
                .save("custom.txt", "old content", "new content", applyAfterSave = true),
        )

        // The content landed on a preset that governs nothing, and auto mode owed nothing more.
        val unselected = indeterminateSaveRunner(target = "new content")
        assertEquals(
            PresetMutationOutcome.Saved,
            testRepository(unselected, RecordingGate())
                .save("custom.txt", "old content", "new content", applyAfterSave = false),
        )

        // The same state under an explicit apply is a selection commit that did not land.
        val uncommitted = indeterminateSaveRunner(target = "new content")
        assertEquals(
            PresetMutationOutcome.RollbackFailed,
            testRepository(uncommitted, RecordingGate())
                .save("custom.txt", "old content", "new content", applyAfterSave = true),
        )
        assertEquals(0, uncommitted.configWrites)
    }

    @Test
    fun save_acceptsALostAnswerOnlyWhenTheLiveGenerationIsTheOneThisLeaseStamped() = runBlocking {
        val unproven = indeterminateSaveRunner(target = "new content", selected = true)
        assertEquals(
            PresetMutationOutcome.RollbackFailed,
            testRepository(unproven, RecordingGate())
                .save("custom.txt", "old content", "new content", applyAfterSave = true),
        )

        val applied = indeterminateSaveRunner(target = "new content", selected = true, proven = true)
        assertEquals(
            PresetMutationOutcome.SavedAndApplied,
            testRepository(applied, RecordingGate())
                .save("custom.txt", "old content", "new content", applyAfterSave = true),
        )
        assertEquals(
            listOf(
                "write-candidate",
                "save-transaction",
                "remove",
                "snapshot-file",
                "snapshot-config",
                "prove-commit",
            ),
            applied.events,
        )
        assertEquals(0, applied.configWrites)
        assertEquals(0, applied.restartCalls)
        // A staging file from a lost attempt is never left behind in the privileged directory.
        assertFalse(applied.files.keys.any { it.startsWith("_") })

        // Auto mode never moves the selection, so the same proof describes a plain application.
        val autoApplied = indeterminateSaveRunner(target = "new content", selected = true, proven = true)
        assertEquals(
            PresetMutationOutcome.Applied,
            testRepository(autoApplied, RecordingGate())
                .save("custom.txt", "old content", "new content", applyAfterSave = false),
        )
    }

    @Test
    fun save_neverReplaysALostTransactionAsAFreshAttempt() = runBlocking {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            saveTransactionFailure = IllegalStateException("root transport died"),
        )
        runner.files["custom.txt"] = "old content"
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("custom.txt", "old content", "new content", applyAfterSave = true)

        assertEquals(PresetMutationOutcome.IoFailed, result)
        assertEquals(1, runner.saveTransactionCalls)
        assertEquals(0, runner.replaceCalls)
        assertEquals(0, runner.configWrites)
        assertEquals(0, runner.restartCalls)
        assertEquals(0, runner.validationCalls)
    }

    @Test
    fun save_rejectsAnUnsafeNameBeforeStagingAnythingForTheModule() = runBlocking {
        val runner = FakePresetRunner(validation = PresetValidation.Compatible)
        val repository = testRepository(runner, RecordingGate())

        val result = repository.save("../escape.txt", null, "content", applyAfterSave = false)

        assertEquals(PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME), result)
        assertEquals(0, runner.saveTransactionCalls)
        assertTrue(runner.events.isEmpty())
    }

    private fun indeterminateSaveRunner(
        target: String,
        selected: Boolean = false,
        proven: Boolean = false,
    ): FakePresetRunner {
        val runner = FakePresetRunner(
            validation = PresetValidation.Compatible,
            saveTransaction = PresetApplyTransaction.Indeterminate,
            applyIsProven = proven,
        )
        runner.config = ActivePresetConfig(if (selected) "custom.txt" else "old.txt")
        runner.files["custom.txt"] = target
        return runner
    }

    private fun sha256Hex(content: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(content.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private fun testRepository(
        runner: PresetRunner,
        gate: PresetMutationGate,
        revision: PresetStateRevision = PresetStateRevision(),
    ): TransactionalPresetRepository = TransactionalPresetRepository(runner, gate, revision)

    private data class SaveRequest(
        val fileName: String,
        val candidateFileName: String,
        val expectedDigest: String?,
        val applyAfterSave: Boolean,
    )

    private class RecordingGate : PresetMutationGate {
        var calls = 0
        override suspend fun <T> mutate(block: suspend () -> T): T {
            calls++
            return block()
        }
    }

    private class FakePresetRunner(
        var validation: PresetValidation,
        /**
         * Defaults to the module generation that predates the transaction, so every pre-existing
         * expectation in this file keeps exercising the stepwise fallback that generation needs.
         */
        var applyTransaction: PresetApplyTransaction = PresetApplyTransaction.Unsupported,
        var saveTransaction: PresetApplyTransaction = PresetApplyTransaction.Unsupported,
        private val applyTransactionFailure: Exception? = null,
        private val saveTransactionFailure: Exception? = null,
        private val applyIsProven: Boolean = false,
        private val restartSucceeds: Boolean = true,
        private val restartFailure: Exception? = null,
        private val replaceReturns: Boolean = true,
        private val restoreSucceeds: Boolean = true,
        private val validationFailure: Exception? = null,
        private val writeCandidateFailure: Exception? = null,
        private val replaceFailure: Exception? = null,
        private val snapshotFileFailureOnCall: Int? = null,
        private val configWriteFailureOnCall: Int? = null,
    ) : PresetRunner {
        var config = ActivePresetConfig("old.txt")
        val files = linkedMapOf<String, String>()
        val events = mutableListOf<String>()
        var validationCalls = 0
        var configWrites = 0
        var restartCalls = 0
        var replaceCalls = 0
        var snapshotFileCalls = 0
        var applyTransactionCalls = 0
        var saveTransactionCalls = 0
        val saveTransactionRequests = mutableListOf<SaveRequest>()

        override suspend fun listPresets(): List<String>? = null

        override suspend fun applyPresetTransaction(fileName: String): PresetApplyTransaction {
            events += "apply-transaction"
            applyTransactionCalls++
            applyTransactionFailure?.let { throw it }
            return applyTransaction
        }

        override suspend fun savePresetTransaction(
            fileName: String,
            candidateFileName: String,
            expectedDigest: String?,
            applyAfterSave: Boolean,
        ): PresetApplyTransaction {
            events += "save-transaction"
            saveTransactionCalls++
            saveTransactionRequests += SaveRequest(fileName, candidateFileName, expectedDigest, applyAfterSave)
            saveTransactionFailure?.let { throw it }
            return saveTransaction
        }

        override suspend fun validatePreset(candidateFileName: String, logicalFileName: String): PresetValidation {
            events += "validate"
            validationCalls++
            validationFailure?.let { throw it }
            return validation
        }

        override suspend fun previewPreset(
            candidateFileName: String,
            logicalFileName: String,
        ): PresetPreviewOutcome {
            events += "preview"
            return PresetPreviewOutcome.Ready(
                PresetCommandPreview("/data/nfqws2", listOf("--qnum=200", "--fwmark=1", "--uid=0:0", "--name=test"), "443", ""),
            )
        }

        override suspend fun loadSelection(): PresetSelection = PresetSelection(config.presetFile)

        override suspend fun isServiceRunning(): Boolean = true

        override suspend fun snapshotActiveConfig(): ActivePresetConfig {
            events += "snapshot-config"
            return config.copy()
        }

        override suspend fun writeActiveConfig(config: ActivePresetConfig): Boolean {
            events += "write-config"
            configWrites++
            this.config = config
            if (configWrites == configWriteFailureOnCall) {
                throw IllegalStateException("config write result lost")
            }
            return true
        }

        override suspend fun snapshotFile(fileName: String): PresetFileSnapshot {
            events += "snapshot-file"
            snapshotFileCalls++
            if (snapshotFileCalls == snapshotFileFailureOnCall) {
                throw IllegalStateException("snapshot unavailable")
            }
            return files[fileName]?.let(PresetFileSnapshot::Present) ?: PresetFileSnapshot.Missing
        }

        override suspend fun writeCandidate(fileName: String, content: String): Boolean {
            events += "write-candidate"
            files[fileName] = content
            writeCandidateFailure?.let { throw it }
            return true
        }

        override suspend fun replaceCandidate(candidateFileName: String, targetFileName: String): Boolean {
            events += "replace"
            replaceCalls++
            val content = files.remove(candidateFileName) ?: return false
            files[targetFileName] = content
            replaceFailure?.let { throw it }
            return replaceReturns
        }

        override suspend fun restoreFile(fileName: String, snapshot: PresetFileSnapshot): Boolean {
            events += "restore-file"
            if (!restoreSucceeds) return false
            when (snapshot) {
                PresetFileSnapshot.Missing -> files.remove(fileName)
                is PresetFileSnapshot.Present -> files[fileName] = snapshot.content
                PresetFileSnapshot.Unsafe -> return false
            }
            return true
        }

        override suspend fun removeFile(fileName: String): Boolean {
            events += "remove"
            files.remove(fileName)
            return true
        }

        override suspend fun restart(): Boolean {
            events += "restart"
            restartCalls++
            restartFailure?.let { throw it }
            return restartSucceeds
        }

        override suspend fun committedApplyIsProven(): Boolean {
            events += "prove-commit"
            return applyIsProven
        }
    }
}

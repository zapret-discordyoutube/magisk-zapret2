package com.zapret2.app.data

import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Bounded read surface for consumers that only project the selected preset.
 *
 * This path reads runtime.ini and one TXT file. It intentionally cannot enumerate or qualify the
 * preset catalog, invoke nfqws2 dry-run, or inspect immutable package contents.
 */
interface ActivePresetReader {
    suspend fun readActive(): ActivePresetSource?
}

interface PresetRepository : ActivePresetReader {
    suspend fun loadCatalog(): PresetCatalog?
    suspend fun readCompatible(fileName: String): String?
    suspend fun preview(fileName: String, content: String): PresetPreviewOutcome
    suspend fun apply(fileName: String): PresetMutationOutcome
    suspend fun save(
        fileName: String,
        expectedContent: String?,
        content: String,
        applyAfterSave: Boolean,
    ): PresetMutationOutcome
}

data class ActivePresetSource(
    val fileName: String,
    val content: String,
)

object PresetNamePolicy {
    fun isValid(fileName: String): Boolean =
        RootFileIo.isSimpleFileName(fileName) &&
            fileName.endsWith(".txt") &&
            !fileName.startsWith("_")
}

/**
 * Outcome of the module-owned preset application transaction.
 *
 * [Unsupported] and [Indeterminate] are deliberately distinct: the first says the installed
 * generation never ran the transaction at all, the second says it ran without proving what it left
 * behind. Collapsing them would let a lost answer be replayed as a fresh attempt.
 */
internal sealed interface PresetApplyTransaction {
    data object Unsupported : PresetApplyTransaction
    data object Indeterminate : PresetApplyTransaction
    data class Reported(val outcome: PresetMutationOutcome) : PresetApplyTransaction
}

internal object PresetMachineProtocol {
    private const val RECORD = "Z2_PRESET"
    private const val SUMMARY = "Z2_PRESET_SUMMARY"
    private const val VALIDATION = "Z2_PRESET_VALIDATION"
    private const val COMMAND_PREVIEW = "Z2_COMMAND_PREVIEW"
    private const val COMMAND_EXECUTABLE = "Z2_COMMAND_EXECUTABLE"
    private const val COMMAND_ARGUMENT = "Z2_COMMAND_ARGUMENT"
    private const val COMMAND_SUMMARY = "Z2_COMMAND_SUMMARY"

    const val APPLY_UNSUPPORTED = "Z2_APPLY_UNSUPPORTED=1"

    /** Wire sentinel for "the save target must not exist yet". */
    const val SAVE_MISSING_DIGEST = "missing"

    private const val APPLY_SCHEMA = "Z2_APPLY_SCHEMA"
    private const val APPLY_SCHEMA_VERSION = "1"
    private const val APPLY_OUTCOME = "Z2_APPLY_OUTCOME"
    private const val APPLY_ISSUE = "Z2_APPLY_ISSUE"
    private const val APPLY_PRESET = "Z2_APPLY_PRESET"
    private const val APPLY_PREVIOUS_PRESET = "Z2_APPLY_PREVIOUS_PRESET"
    private const val APPLY_CONFIG_COMMITTED = "Z2_APPLY_CONFIG_COMMITTED"
    private const val APPLY_SERVICE_WAS_RUNNING = "Z2_APPLY_SERVICE_WAS_RUNNING"
    private const val APPLY_COMPLETE = "Z2_APPLY_COMPLETE"
    private const val APPLY_ISSUE_NONE = "NONE"
    private const val INVALID_ARGUMENTS = "INVALID_ARGUMENTS"
    private const val STAGE_APPLY_REQUEST = "APPLY_REQUEST"
    private const val STAGE_SAVE_REQUEST = "APPLY_SAVE_REQUEST"
    private const val UNSAFE_PRESET_NAME = "UNSAFE_PRESET_NAME"
    private val PACKET_LIMIT = Regex("[1-9][0-9]{0,8}")

    private val applyOwnFields = setOf(
        APPLY_SCHEMA,
        APPLY_OUTCOME,
        APPLY_ISSUE,
        APPLY_PRESET,
        APPLY_PREVIOUS_PRESET,
        APPLY_CONFIG_COMMITTED,
        APPLY_SERVICE_WAS_RUNNING,
        APPLY_COMPLETE,
    )

    private val applyFields = applyOwnFields + LifecycleErrorContract.wireFields

    /**
     * Projects the module's single apply payload onto one existing mutation outcome.
     *
     * The payload is accepted only when it is complete, terminated by its own sentinel, and
     * internally consistent: a committed outcome must carry a clean error envelope, and a refusal
     * must carry both an error envelope and a typed issue. Anything else is [Indeterminate] — the
     * module may have mutated state this app cannot describe, so the caller resolves it from
     * published facts rather than assuming either direction.
     */
    fun parseApply(lines: List<String>, expectedFileName: String): PresetApplyTransaction {
        val records = lines.filter(String::isNotBlank)
        if (records.singleOrNull() == APPLY_UNSUPPORTED) return PresetApplyTransaction.Unsupported
        val payload = decodeApplyPayload(records) ?: return PresetApplyTransaction.Indeterminate
        val outcome = when (payload.outcome) {
            "APPLIED" -> PresetMutationOutcome.Applied
            "SAVED" -> PresetMutationOutcome.Saved
            "REJECTED" -> PresetMutationOutcome.Rejected(PresetIssue.fromWireCode(payload.issue))
            "WRITE_FAILED", "IO_FAILED" -> PresetMutationOutcome.IoFailed
            "WRITE_FAILED_ROLLED_BACK" -> PresetMutationOutcome.WriteFailedRolledBack
            "RESTART_FAILED_ROLLED_BACK" -> PresetMutationOutcome.RestartFailedRolledBack
            "ROLLBACK_FAILED" -> PresetMutationOutcome.RollbackFailed
            "BLOCKED" -> PresetMutationOutcome.Blocked
            else -> return PresetApplyTransaction.Indeterminate
        }
        // An unsafe request is never echoed back, so only that refusal may omit the name.
        val rejectedName = outcome is PresetMutationOutcome.Rejected &&
            PresetIssue.fromWireCode(payload.issue) == PresetIssue.UNSAFE_PRESET_NAME
        if (!payload.namesTheRequest(expectedFileName, mayOmitName = rejectedName)) {
            return PresetApplyTransaction.Indeterminate
        }
        val consistent = when (outcome) {
            PresetMutationOutcome.Applied ->
                payload.isClean && payload.committed && payload.wasRunning
            PresetMutationOutcome.Saved ->
                payload.isClean && payload.committed && !payload.wasRunning
            is PresetMutationOutcome.Rejected -> payload.isTypedRefusal
            else -> payload.isUntypedFailure
        }
        if (!consistent) return PresetApplyTransaction.Indeterminate
        return PresetApplyTransaction.Reported(outcome)
    }

    /**
     * Projects the module's single content-save payload onto one existing mutation outcome.
     *
     * It shares the apply envelope and its fail-closed decoding, and differs only in the wider
     * result set a content mutation can reach: the preset may be saved without governing the
     * daemon, saved and selected, or refused by the content compare-and-swap that proves the app
     * edited the generation still on disk.
     */
    fun parseSave(lines: List<String>, expectedFileName: String): PresetApplyTransaction {
        val records = lines.filter(String::isNotBlank)
        if (records.singleOrNull() == APPLY_UNSUPPORTED) return PresetApplyTransaction.Unsupported
        val payload = decodeApplyPayload(records) ?: return PresetApplyTransaction.Indeterminate
        // A generation without this entry point reads the flag as the one preset name it accepts
        // and refuses the argument count before touching anything. The app proves the name against
        // its own policy before the round trip, so this exact refusal can only mean the entry point
        // is missing — which is what lets the caller fall back instead of reporting a failure.
        if (payload.outcome == "REJECTED" && payload.issue == UNSAFE_PRESET_NAME &&
            payload.preset.isEmpty() && payload.error.code == INVALID_ARGUMENTS &&
            payload.error.stage == STAGE_APPLY_REQUEST
        ) {
            return PresetApplyTransaction.Unsupported
        }
        val outcome = when (payload.outcome) {
            "SAVED" -> PresetMutationOutcome.Saved
            "APPLIED" -> PresetMutationOutcome.Applied
            "SAVED_AND_APPLIED" -> PresetMutationOutcome.SavedAndApplied
            "SOURCE_CHANGED" -> PresetMutationOutcome.SourceChanged
            "REJECTED" -> PresetMutationOutcome.Rejected(PresetIssue.fromWireCode(payload.issue))
            "IO_FAILED" -> PresetMutationOutcome.IoFailed
            "WRITE_FAILED_ROLLED_BACK" -> PresetMutationOutcome.WriteFailedRolledBack
            "RESTART_FAILED_ROLLED_BACK" -> PresetMutationOutcome.RestartFailedRolledBack
            "ROLLBACK_FAILED" -> PresetMutationOutcome.RollbackFailed
            "BLOCKED" -> PresetMutationOutcome.Blocked
            else -> return PresetApplyTransaction.Indeterminate
        }
        // Save-mode argument refusals are emitted before the request is echoed back, exactly like
        // the unsafe-name refusal on the selection transaction. The app assembles those arguments
        // itself, so reaching this is a defect on this side, reported as the I/O failure it is.
        val unnamedRefusal = outcome == PresetMutationOutcome.IoFailed &&
            payload.error.code == INVALID_ARGUMENTS && payload.error.stage == STAGE_SAVE_REQUEST
        if (!payload.namesTheRequest(expectedFileName, mayOmitName = unnamedRefusal)) {
            return PresetApplyTransaction.Indeterminate
        }
        val consistent = when (outcome) {
            // A save that governs nothing commits nothing and replaces nothing, so neither flag is
            // pinned: the module reports it for a stopped service and for an unselected preset.
            PresetMutationOutcome.Saved -> payload.isClean
            PresetMutationOutcome.Applied ->
                payload.isClean && payload.wasRunning && !payload.committed
            PresetMutationOutcome.SavedAndApplied ->
                payload.isClean && payload.wasRunning && payload.committed
            PresetMutationOutcome.SourceChanged ->
                payload.isUntypedFailure && !payload.committed
            is PresetMutationOutcome.Rejected -> payload.isTypedRefusal
            else -> payload.isUntypedFailure
        }
        if (!consistent) return PresetApplyTransaction.Indeterminate
        return PresetApplyTransaction.Reported(outcome)
    }

    /**
     * Decodes the transaction envelope both entry points share, or nothing at all.
     *
     * Acceptance is structural only: the payload must be complete, terminated by its own sentinel,
     * carry each field exactly once at the schema this app knows, and name a previous preset this
     * app would itself consider safe.
     */
    private fun decodeApplyPayload(records: List<String>): ApplyPayload? {
        if (records.lastOrNull() != "$APPLY_COMPLETE=1") return null
        val pairs = records.map { record ->
            val separator = record.indexOf('=')
            if (separator <= 0) return null
            record.substring(0, separator) to record.substring(separator + 1)
        }
        val counts = pairs.groupingBy { it.first }.eachCount()
        if (counts.keys != applyFields || applyFields.any { counts[it] != 1 }) return null
        val values = pairs.toMap()
        if (values[APPLY_SCHEMA] != APPLY_SCHEMA_VERSION) return null
        val error = LifecycleErrorContract.parseValues(values) ?: return null
        val committed = values.getValue(APPLY_CONFIG_COMMITTED).toFlag() ?: return null
        val wasRunning = values.getValue(APPLY_SERVICE_WAS_RUNNING).toFlag() ?: return null
        val previous = values.getValue(APPLY_PREVIOUS_PRESET)
        if (previous.isNotEmpty() && !PresetNamePolicy.isValid(previous)) return null
        return ApplyPayload(
            outcome = values.getValue(APPLY_OUTCOME),
            issue = values.getValue(APPLY_ISSUE),
            preset = values.getValue(APPLY_PRESET),
            committed = committed,
            wasRunning = wasRunning,
            error = error,
        )
    }

    private fun String.toFlag(): Boolean? = when (this) {
        "0" -> false
        "1" -> true
        else -> null
    }

    private data class ApplyPayload(
        val outcome: String,
        val issue: String,
        val preset: String,
        val committed: Boolean,
        val wasRunning: Boolean,
        val error: LifecycleError,
    ) {
        /** A committed outcome may never travel with a failure envelope or a typed issue. */
        val isClean: Boolean get() = error.isNone && issue == APPLY_ISSUE_NONE

        /** A refusal must name why it refused and must have committed nothing. */
        val isTypedRefusal: Boolean get() = !error.isNone && !committed && issue != APPLY_ISSUE_NONE

        /** Every other failure is described by the error envelope alone. */
        val isUntypedFailure: Boolean get() = !error.isNone && issue == APPLY_ISSUE_NONE

        fun namesTheRequest(expected: String, mayOmitName: Boolean): Boolean =
            if (mayOmitName) preset.isEmpty() else preset == expected
    }

    fun parseDiscovery(lines: List<String>): PresetDiscovery? {
        val records = mutableListOf<ScanRecord>()
        var summary: ScanSummary? = null
        for (line in lines.filter(String::isNotBlank)) {
            val fields = line.split('\t')
            when (fields.firstOrNull()) {
                RECORD -> {
                    if (fields.size != 4 || summary != null) return null
                    val status = fields[1]
                    val reason = fields[2]
                    val fileName = fields[3]
                    if (!PresetNamePolicy.isValid(fileName)) return null
                    val record = when {
                        status in setOf("VALID", "READY") && reason == "OK" ->
                            ScanRecord(fileName, status, null)
                        status == "QUARANTINED" && reason != "OK" ->
                            ScanRecord(fileName, status, PresetIssue.fromWireCode(reason))
                        else -> return null
                    }
                    records += record
                }

                SUMMARY -> {
                    if (fields.size != 5 || fields[1] !in setOf("1", "2") || summary != null) return null
                    val values = fields.drop(2).mapNotNull { field ->
                        val separator = field.indexOf('=')
                        if (separator <= 0) null else field.substring(0, separator) to field.substring(separator + 1)
                    }.toMap()
                    val version = fields[1]
                    val availableKey = when (version) {
                        "1" -> "valid"
                        "2" -> "ready"
                        else -> return null
                    }
                    summary = ScanSummary(
                        version = version,
                        available = values[availableKey]?.toIntOrNull() ?: return null,
                        quarantined = values["quarantined"]?.toIntOrNull() ?: return null,
                        total = values["total"]?.toIntOrNull() ?: return null,
                    )
                }

                else -> return null
            }
        }

        val finalSummary = summary ?: return null
        if (records.map(ScanRecord::fileName).distinct().size != records.size) return null
        if (finalSummary.available < 0 || finalSummary.quarantined < 0 || finalSummary.total < 0) return null
        if (finalSummary.total != records.size) return null
        val expectedAvailableStatus = if (finalSummary.version == "1") "VALID" else "READY"
        if (records.any { it.issue == null && it.status != expectedAvailableStatus }) return null
        if (finalSummary.available != records.count { it.issue == null }) return null
        if (finalSummary.quarantined != records.count { it.issue != null }) return null

        val available = records
            .filter { it.issue == null }
            .map { PresetEntry(it.fileName) }
            .sortedBy { it.fileName.lowercase() }
        val issueCounts = records
            .mapNotNull(ScanRecord::issue)
            .groupingBy { it }
            .eachCount()
        return PresetDiscovery(available, finalSummary.quarantined, issueCounts)
    }

    fun parseValidation(lines: List<String>, expectedLogicalName: String): PresetValidation {
        val records = lines.filter(String::isNotBlank)
        if (records.size != 1) return PresetValidation.ProtocolFailure
        val fields = records.single().split('\t')
        if (fields.size != 4 || fields[0] != VALIDATION || fields[3] != expectedLogicalName) {
            return PresetValidation.ProtocolFailure
        }
        return when {
            fields[1] == "1" && fields[2] == "OK" -> PresetValidation.Compatible
            fields[1] == "0" && fields[2] != "OK" ->
                PresetValidation.Quarantined(PresetIssue.fromWireCode(fields[2]))
            else -> PresetValidation.ProtocolFailure
        }
    }

    fun parsePreview(lines: List<String>, expectedLogicalName: String): PresetPreviewOutcome {
        val records = lines.filter(String::isNotBlank)
        val first = records.firstOrNull()?.split('\t') ?: return PresetPreviewOutcome.Failed
        if (first.firstOrNull() != COMMAND_PREVIEW) return PresetPreviewOutcome.Failed
        if (first.getOrNull(1) == "0") {
            if (records.size != 1 || first.size != 4 || first[3] != expectedLogicalName || first[2] == "OK") {
                return PresetPreviewOutcome.Failed
            }
            return PresetPreviewOutcome.Rejected(PresetIssue.fromWireCode(first[2]))
        }
        if (first.getOrNull(2) != expectedLogicalName) {
            return PresetPreviewOutcome.Failed
        }
        val capturePolicy = when (first.getOrNull(1)) {
            "1" -> if (first.size == 5) null else return PresetPreviewOutcome.Failed
            "2" -> {
                if (first.size != 9) return PresetPreviewOutcome.Failed
                PresetCapturePolicy(
                    tcpPacketOut = first[5].parsePacketLimit("TCP_OUT=")
                        ?: return PresetPreviewOutcome.Failed,
                    tcpPacketIn = first[6].parsePacketLimit("TCP_IN=")
                        ?: return PresetPreviewOutcome.Failed,
                    udpPacketOut = first[7].parsePacketLimit("UDP_OUT=")
                        ?: return PresetPreviewOutcome.Failed,
                    udpPacketIn = first[8].parsePacketLimit("UDP_IN=")
                        ?: return PresetPreviewOutcome.Failed,
                )
            }
            else -> return PresetPreviewOutcome.Failed
        }
        val tcpPorts = first[3].takeIf { it.startsWith("TCP=") }?.removePrefix("TCP=")
            ?: return PresetPreviewOutcome.Failed
        val udpPorts = first[4].takeIf { it.startsWith("UDP=") }?.removePrefix("UDP=")
            ?: return PresetPreviewOutcome.Failed
        if (!isValidPortUnion(tcpPorts) || !isValidPortUnion(udpPorts) || tcpPorts + udpPorts == "") {
            return PresetPreviewOutcome.Failed
        }
        if (records.size < 4) return PresetPreviewOutcome.Failed
        val executable = records[1].split('\t').takeIf {
            it.size == 2 && it[0] == COMMAND_EXECUTABLE && it[1].startsWith('/') && !it[1].containsControl()
        }?.get(1) ?: return PresetPreviewOutcome.Failed
        val summary = records.last().split('\t')
        if (summary.size != 3 || summary[0] != COMMAND_SUMMARY || summary[1] != "1") {
            return PresetPreviewOutcome.Failed
        }
        val count = summary[2].takeIf { it.startsWith("count=") }
            ?.removePrefix("count=")?.toIntOrNull() ?: return PresetPreviewOutcome.Failed
        val arguments = records.subList(2, records.lastIndex).map { record ->
            val fields = record.split('\t')
            if (fields.size != 2 || fields[0] != COMMAND_ARGUMENT || !fields[1].startsWith("--") ||
                fields[1].containsControl()
            ) return PresetPreviewOutcome.Failed
            fields[1]
        }
        if (count != arguments.size || count <= 3) return PresetPreviewOutcome.Failed
        return PresetPreviewOutcome.Ready(
            PresetCommandPreview(executable, arguments, tcpPorts, udpPorts, capturePolicy),
        )
    }

    private fun String.parsePacketLimit(prefix: String): Int? {
        val value = takeIf { it.startsWith(prefix) }?.removePrefix(prefix) ?: return null
        if (!PACKET_LIMIT.matches(value)) return null
        return value.toIntOrNull()
    }

    private fun String.containsControl(): Boolean = any { it.code < 0x20 || it.code == 0x7f }

    private fun isValidPortUnion(value: String): Boolean {
        if (value.isEmpty()) return true
        return value.split(',').all { token ->
            val bounds = token.split(':')
            if (bounds.size !in 1..2) return@all false
            val first = bounds[0].toIntOrNull() ?: return@all false
            val last = bounds.getOrNull(1)?.toIntOrNull() ?: first
            first in 1..65535 && last in first..65535
        }
    }

    private data class ScanRecord(val fileName: String, val status: String, val issue: PresetIssue?)
    private data class ScanSummary(
        val version: String,
        val available: Int,
        val quarantined: Int,
        val total: Int,
    )
}

internal interface PresetMutationGate {
    suspend fun <T> mutate(block: suspend () -> T): T
}

internal interface PresetRunner {
    suspend fun listPresets(): List<String>?
    suspend fun applyPresetTransaction(fileName: String): PresetApplyTransaction
    suspend fun savePresetTransaction(
        fileName: String,
        candidateFileName: String,
        expectedDigest: String?,
        applyAfterSave: Boolean,
    ): PresetApplyTransaction
    suspend fun validatePreset(candidateFileName: String, logicalFileName: String): PresetValidation
    suspend fun previewPreset(candidateFileName: String, logicalFileName: String): PresetPreviewOutcome
    suspend fun loadSelection(): PresetSelection?
    suspend fun snapshotActiveConfig(): ActivePresetConfig?
    suspend fun writeActiveConfig(config: ActivePresetConfig): Boolean
    suspend fun snapshotFile(fileName: String): PresetFileSnapshot
    suspend fun writeCandidate(fileName: String, content: String): Boolean
    suspend fun replaceCandidate(candidateFileName: String, targetFileName: String): Boolean
    suspend fun restoreFile(fileName: String, snapshot: PresetFileSnapshot): Boolean
    suspend fun removeFile(fileName: String): Boolean
    suspend fun restart(): Boolean
    suspend fun isServiceRunning(): Boolean?
    suspend fun committedApplyIsProven(): Boolean
}

@Singleton
internal class ModulePresetMutationGate @Inject constructor() : PresetMutationGate {
    override suspend fun <T> mutate(block: suspend () -> T): T =
        ModuleMutationCoordinator.withNonCancellableMutation(block)
}

@Singleton
internal class RootPresetRunner @Inject constructor() : PresetRunner {
    private val moduleDir = RootModuleContract.ACTIVE_MODULE_DIR
    private val zapretDir = "$moduleDir/zapret2"
    private val presetsDir = "$zapretDir/presets"
    private val commandBuilder = "$zapretDir/scripts/command-builder.sh"
    private val applyPresetScript = "$moduleDir/${ModulePackageContract.APPLY_PRESET_SCRIPT_PATH}"

    override suspend fun listPresets(): List<String>? {
        val result = ServiceLifecycleController.executeRoot(
            "/system/bin/sh ${RootFileIo.shellQuote(commandBuilder)} --list-presets-machine " +
                RootFileIo.shellQuote(zapretDir),
        )
        result.throwIfProtectedAccessFailed()
        return result.stdout.takeIf { result.success }
    }

    /**
     * One privileged round trip for the whole preset application.
     *
     * The module validates, persists and replaces under a single transaction that inherits this
     * mutation's lifecycle lease, so nothing here reconstructs the steps or their rollback. A
     * generation installed before that entry point exists answers with the unsupported sentinel
     * from the same round trip, which is what lets the caller fall back instead of failing.
     */
    override suspend fun applyPresetTransaction(fileName: String): PresetApplyTransaction {
        if (!PresetNamePolicy.isValid(fileName)) {
            return PresetApplyTransaction.Reported(
                PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME),
            )
        }
        val script = RootFileIo.shellQuote(applyPresetScript)
        val invocation = ModuleMutationCoordinator.inheritLifecycleLock(
            "sh $script ${RootFileIo.shellQuote(fileName)}",
        )
        val command = """
            if [ -f $script ] && [ ! -L $script ]; then
                $invocation
            else
                echo ${PresetMachineProtocol.APPLY_UNSUPPORTED}
            fi
        """.trimIndent()
        val result = ServiceLifecycleController.executeRoot(command, RootCommandPolicy.LIFECYCLE)
        return PresetMachineProtocol.parseApply(result.stdout, fileName)
    }

    override suspend fun validatePreset(
        candidateFileName: String,
        logicalFileName: String,
    ): PresetValidation {
        if (!isSafeName(candidateFileName) || !PresetNamePolicy.isValid(logicalFileName)) {
            return PresetValidation.Quarantined(PresetIssue.UNSAFE_PRESET_NAME)
        }
        val candidatePath = "$presetsDir/$candidateFileName"
        val result = ServiceLifecycleController.executeRoot(
            "/system/bin/sh ${RootFileIo.shellQuote(commandBuilder)} --preflight-preset-machine " +
                "${RootFileIo.shellQuote(zapretDir)} ${RootFileIo.shellQuote(candidatePath)} " +
                RootFileIo.shellQuote(logicalFileName),
        )
        return PresetMachineProtocol.parseValidation(result.stdout, logicalFileName)
    }

    /**
     * One privileged round trip for the whole preset content mutation.
     *
     * The staged candidate is handed to the module by name, together with the content identity the
     * editor started from: the module owns the compare-and-swap against that identity, the
     * qualification, the publication, the selection commit and every rollback, and consumes or
     * discards the candidate itself. [expectedDigest] is null exactly when the target must not
     * exist yet, which travels as the module's own missing sentinel rather than as an absent
     * argument. A generation installed before this entry point exists answers from the same round
     * trip with either the unsupported sentinel or its argument-count refusal, both of which let
     * the caller fall back instead of failing.
     */
    override suspend fun savePresetTransaction(
        fileName: String,
        candidateFileName: String,
        expectedDigest: String?,
        applyAfterSave: Boolean,
    ): PresetApplyTransaction {
        if (!PresetNamePolicy.isValid(fileName) || !isSafeName(candidateFileName)) {
            return PresetApplyTransaction.Reported(
                PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME),
            )
        }
        val digest = expectedDigest ?: PresetMachineProtocol.SAVE_MISSING_DIGEST
        if (expectedDigest != null && !SHA256_HEX.matches(expectedDigest)) {
            return PresetApplyTransaction.Reported(PresetMutationOutcome.IoFailed)
        }
        val script = RootFileIo.shellQuote(applyPresetScript)
        val mode = if (applyAfterSave) SAVE_MODE_APPLY else SAVE_MODE_AUTO
        val invocation = ModuleMutationCoordinator.inheritLifecycleLock(
            "sh $script --save-content ${RootFileIo.shellQuote(candidateFileName)} " +
                "${RootFileIo.shellQuote(digest)} ${RootFileIo.shellQuote(fileName)} " +
                RootFileIo.shellQuote(mode),
        )
        val command = """
            if [ -f $script ] && [ ! -L $script ]; then
                $invocation
            else
                echo ${PresetMachineProtocol.APPLY_UNSUPPORTED}
            fi
        """.trimIndent()
        val result = ServiceLifecycleController.executeRoot(command, RootCommandPolicy.LIFECYCLE)
        return PresetMachineProtocol.parseSave(result.stdout, fileName)
    }

    override suspend fun previewPreset(
        candidateFileName: String,
        logicalFileName: String,
    ): PresetPreviewOutcome {
        if (!isSafeName(candidateFileName) || !PresetNamePolicy.isValid(logicalFileName)) {
            return PresetPreviewOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME)
        }
        val candidatePath = "$presetsDir/$candidateFileName"
        val result = ServiceLifecycleController.executeRoot(
            "/system/bin/sh ${RootFileIo.shellQuote(commandBuilder)} --preview-preset-machine " +
                "${RootFileIo.shellQuote(zapretDir)} ${RootFileIo.shellQuote(candidatePath)} " +
                RootFileIo.shellQuote(logicalFileName),
        )
        return PresetMachineProtocol.parsePreview(result.stdout, logicalFileName)
    }

    override suspend fun snapshotActiveConfig(): ActivePresetConfig? {
        val values = RuntimeConfigStore.readCore()
        if (values !is RuntimeConfigReadResult.Valid) return null
        val presetFile = values.values["active_preset"] ?: return null
        return ActivePresetConfig(presetFile)
    }

    override suspend fun loadSelection(): PresetSelection? {
        val result = RuntimeConfigStore.readCore()
        if (result !is RuntimeConfigReadResult.Valid) return null
        val values = result.values
        val activePresetFile = values["active_preset"] ?: return null
        return PresetSelection(activePresetFile = activePresetFile)
    }

    override suspend fun writeActiveConfig(config: ActivePresetConfig): Boolean {
        return RuntimeConfigStore.updateCoreSettings(
            RuntimeConfigStore.CoreSettingsUpdate(activePreset = config.presetFile),
        ).isSuccess
    }

    override suspend fun snapshotFile(fileName: String): PresetFileSnapshot {
        if (!isSafeName(fileName)) return PresetFileSnapshot.Unsafe
        val path = "$presetsDir/$fileName"
        return when (val snapshot = RootFileIo.readAtomicMutableText(path, MAX_PRESET_BYTES)) {
            AtomicTextSnapshot.Missing -> PresetFileSnapshot.Missing
            is AtomicTextSnapshot.Present ->
                snapshot.content
                    .takeIf(PresetContentPolicy::isPersistable)
                    ?.let(PresetFileSnapshot::Present)
                    ?: PresetFileSnapshot.Unsafe
            AtomicTextSnapshot.Unsafe,
            AtomicTextSnapshot.Failed,
            -> PresetFileSnapshot.Unsafe
        }
    }

    override suspend fun writeCandidate(fileName: String, content: String): Boolean {
        val normalized = PresetContentPolicy.normalizedForWrite(content)
        if (!isSafeName(fileName) || !PresetContentPolicy.isAllowed(normalized)) {
            return false
        }
        return RootFileIo.writeTextAtomically(
            "$presetsDir/$fileName",
            normalized,
            "__ZAPRET_PRESET_CANDIDATE_EOF__",
            durable = false,
        )
    }

    override suspend fun replaceCandidate(candidateFileName: String, targetFileName: String): Boolean {
        if (!isSafeName(candidateFileName) || !PresetNamePolicy.isValid(targetFileName)) return false
        val candidate = "$presetsDir/$candidateFileName"
        val target = "$presetsDir/$targetFileName"
        val quotedCandidate = RootFileIo.shellQuote(candidate)
        val quotedTarget = RootFileIo.shellQuote(target)
        val command = """
            [ -f $quotedCandidate ] && [ ! -L $quotedCandidate ] &&
                [ "${'$'}(stat -c %u $quotedCandidate 2>/dev/null)" = 0 ] &&
                [ "${'$'}(stat -c %a $quotedCandidate 2>/dev/null)" = 644 ] &&
                [ "${'$'}(stat -c %h $quotedCandidate 2>/dev/null)" = 1 ] || exit 1
            z2_size=${'$'}(stat -c %s $quotedCandidate 2>/dev/null) || exit 1
            case "${'$'}z2_size" in ''|*[!0-9]*) exit 1 ;; esac
            [ "${'$'}z2_size" -gt 0 ] && [ "${'$'}z2_size" -le $MAX_PRESET_BYTES ] || exit 1
            if [ -e $quotedTarget ] || [ -L $quotedTarget ]; then
                [ -f $quotedTarget ] && [ ! -L $quotedTarget ] &&
                    [ "${'$'}(stat -c %u $quotedTarget 2>/dev/null)" = 0 ] &&
                    [ "${'$'}(stat -c %h $quotedTarget 2>/dev/null)" = 1 ] || exit 1
                z2_target_mode=${'$'}(stat -c %a $quotedTarget 2>/dev/null) || exit 1
                case "${'$'}z2_target_mode" in 600|644) ;; *) exit 1 ;; esac
            fi
            mv $quotedCandidate $quotedTarget || exit 1
            [ -f $quotedTarget ] && [ ! -L $quotedTarget ] &&
                [ "${'$'}(stat -c %u $quotedTarget 2>/dev/null)" = 0 ] &&
                [ "${'$'}(stat -c %a $quotedTarget 2>/dev/null)" = 644 ] &&
                [ "${'$'}(stat -c %h $quotedTarget 2>/dev/null)" = 1 ] || exit 1
            sync
        """.trimIndent()
        return ServiceLifecycleController.executeRoot(
            command,
            RootCommandPolicy.MUTATION,
        ).success
    }

    override suspend fun restoreFile(fileName: String, snapshot: PresetFileSnapshot): Boolean {
        if (!PresetNamePolicy.isValid(fileName)) return false
        return when (snapshot) {
            PresetFileSnapshot.Missing -> removeFile(fileName)
            is PresetFileSnapshot.Present -> {
                val normalized = PresetContentPolicy.normalizedForWrite(snapshot.content)
                PresetContentPolicy.isAllowed(normalized) && RootFileIo.writeTextAtomically(
                    "$presetsDir/$fileName",
                    normalized,
                    "__ZAPRET_PRESET_ROLLBACK_EOF__",
                )
            }
            PresetFileSnapshot.Unsafe -> false
        }
    }

    override suspend fun removeFile(fileName: String): Boolean {
        if (!isSafeName(fileName)) return false
        return RootFileIo.removeFile("$presetsDir/$fileName")
    }

    override suspend fun restart(): Boolean = ServiceLifecycleController.restart().success

    override suspend fun isServiceRunning(): Boolean? =
        ServiceLifecycleController.getStatus().takeIf { it.rootGranted }?.processRunning

    /**
     * Proves an application whose answer was lost, on the exact terms the restart path already
     * owns: the published generation is the one this mutation's lease stamped, and the service it
     * describes is healthy. The module writes that generation from `ZAPRET2_LIFECYCLE_TOKEN`, so
     * only a replacement run under this lease can match it.
     */
    override suspend fun committedApplyIsProven(): Boolean {
        val expectedGeneration = ModuleMutationCoordinator.currentLifecycleToken()
        if (expectedGeneration.isNullOrEmpty()) return false
        val status = ServiceLifecycleController.getStatus()
        return status.rootGranted && status.healthy && status.ownerGeneration == expectedGeneration
    }

    private fun isSafeName(fileName: String): Boolean =
        RootFileIo.isSimpleFileName(fileName, ".txt")

    private companion object {
        const val MAX_PRESET_BYTES = PresetContentPolicy.MAX_BYTES
        const val SAVE_MODE_APPLY = "apply"
        const val SAVE_MODE_AUTO = "auto"
        val SHA256_HEX = Regex("[0-9a-f]{64}")
    }
}

@Singleton
internal class TransactionalPresetRepository @Inject constructor(
    private val runner: PresetRunner,
    private val mutationGate: PresetMutationGate,
    private val presetStateRevision: PresetStateRevision,
) : PresetRepository {

    override suspend fun loadCatalog(): PresetCatalog? = withContext(Dispatchers.IO) {
        val discovery = runner.listPresets()?.let(PresetMachineProtocol::parseDiscovery)
            ?: return@withContext null
        val selection = runner.loadSelection() ?: return@withContext null
        PresetCatalog(
            discovery = discovery,
            selection = selection,
        )
    }

    override suspend fun readActive(): ActivePresetSource? = withContext(Dispatchers.IO) {
        val selection = runner.loadSelection() ?: return@withContext null
        val fileName = selection.activePresetFile
        if (!PresetNamePolicy.isValid(fileName)) return@withContext null
        val content = (runner.snapshotFile(fileName) as? PresetFileSnapshot.Present)?.content
            ?: return@withContext null
        ActivePresetSource(fileName, content)
    }

    override suspend fun readCompatible(fileName: String): String? = withContext(Dispatchers.IO) {
        if (!PresetNamePolicy.isValid(fileName)) return@withContext null
        (runner.snapshotFile(fileName) as? PresetFileSnapshot.Present)?.content
    }

    override suspend fun preview(fileName: String, content: String): PresetPreviewOutcome {
        if (!PresetNamePolicy.isValid(fileName)) {
            return PresetPreviewOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME)
        }
        val normalized = PresetContentPolicy.normalizedForWrite(content)
        if (!PresetContentPolicy.isAllowed(normalized)) {
            return PresetPreviewOutcome.Rejected(PresetIssue.PRESET_TOO_LARGE)
        }
        return try {
            withContext(Dispatchers.IO) {
                mutationGate.mutate {
                    val candidate = previewCandidateName(fileName)
                    val written = booleanResult { runner.writeCandidate(candidate, normalized) }
                    if (!written) {
                        removeOrFalse(candidate)
                        return@mutate PresetPreviewOutcome.Failed
                    }
                    val outcome = try {
                        runner.previewPreset(candidate, fileName)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        PresetPreviewOutcome.Failed
                    }
                    if (removeOrFalse(candidate)) outcome else PresetPreviewOutcome.Failed
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: ModuleMutationCoordinator.MutationBlockedException) {
            PresetPreviewOutcome.Blocked
        } catch (_: Exception) {
            PresetPreviewOutcome.Failed
        }
    }

    /**
     * One logical mutation, one module transaction.
     *
     * The module owns validation, the runtime.ini commit, the replacement and every rollback
     * decision, and answers with one typed payload this repository only projects. The stepwise
     * flow below survives for one reason: a module generation installed before that entry point
     * existed cannot grow it, and a preset must still be applicable on it.
     */
    override suspend fun apply(fileName: String): PresetMutationOutcome =
        publishCommittedMutation(
            safelyMutate {
                if (!PresetNamePolicy.isValid(fileName)) {
                    return@safelyMutate PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME)
                }
                when (val transaction = applyTransaction(fileName)) {
                    PresetApplyTransaction.Unsupported -> applyStepwise(fileName)
                    PresetApplyTransaction.Indeterminate -> resolveIndeterminateApply(fileName)
                    is PresetApplyTransaction.Reported -> transaction.outcome
                }
            },
        )

    private suspend fun applyTransaction(fileName: String): PresetApplyTransaction = try {
        runner.applyPresetTransaction(fileName)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        PresetApplyTransaction.Indeterminate
    }

    /**
     * The module ran but did not prove what it left behind. Read published facts instead of
     * guessing: an unchanged selection means nothing was committed, and a committed selection is
     * an application only when the live generation is the one this lease stamped. Everything else
     * stays unproven, which is the direction that cannot invent a success. Re-applying a selection
     * that was already active also resolves to the unproven side, because the two cases are
     * indistinguishable from the published state alone.
     */
    private suspend fun resolveIndeterminateApply(fileName: String): PresetMutationOutcome {
        val published = try {
            runner.snapshotActiveConfig()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        } ?: return PresetMutationOutcome.RollbackFailed
        if (published.presetFile != fileName) return PresetMutationOutcome.IoFailed
        return if (booleanResult { runner.committedApplyIsProven() }) {
            PresetMutationOutcome.Applied
        } else {
            PresetMutationOutcome.RollbackFailed
        }
    }

    /** Preserved only for module generations without the transactional entry point. */
    private suspend fun applyStepwise(fileName: String): PresetMutationOutcome {
        val oldConfig = runner.snapshotActiveConfig() ?: return PresetMutationOutcome.IoFailed
        val wasRunning = runner.isServiceRunning() ?: return PresetMutationOutcome.IoFailed
        when (writeConfigResult(ActivePresetConfig(fileName))) {
            true -> Unit
            false -> return PresetMutationOutcome.IoFailed
            null -> return if (writeConfigOrFalse(oldConfig)) {
                PresetMutationOutcome.WriteFailedRolledBack
            } else {
                PresetMutationOutcome.RollbackFailed
            }
        }
        return if (!wasRunning) PresetMutationOutcome.Saved
        else if (restartOrFalse()) PresetMutationOutcome.Applied
        else if (writeConfigOrFalse(oldConfig)) PresetMutationOutcome.RestartFailedRolledBack
        else PresetMutationOutcome.RollbackFailed
    }

    /**
     * One logical content mutation, one module transaction.
     *
     * The app stages the candidate and states the content identity the editor started from; the
     * module owns the compare-and-swap against that identity, the qualification, the publication,
     * the selection commit, the replacement and every rollback, and answers with one typed payload
     * this repository only projects. The stepwise flow below survives for the same reason the
     * selection transaction keeps one: a module generation installed before that entry point
     * existed cannot grow it, and an edit must still be savable on it.
     */
    override suspend fun save(
        fileName: String,
        expectedContent: String?,
        content: String,
        applyAfterSave: Boolean,
    ): PresetMutationOutcome = publishCommittedMutation(
        safelyMutate {
            if (!PresetNamePolicy.isValid(fileName)) {
                return@safelyMutate PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME)
            }
            val normalized = PresetContentPolicy.normalizedForWrite(content)
            if (!PresetContentPolicy.isAllowed(normalized)) {
                return@safelyMutate PresetMutationOutcome.Rejected(PresetIssue.PRESET_TOO_LARGE)
            }
            val candidate = candidateName(fileName)
            if (!booleanResult { runner.writeCandidate(candidate, normalized) }) {
                return@safelyMutate cleanupCandidate(candidate, PresetMutationOutcome.IoFailed)
            }
            val transaction = saveTransaction(
                fileName = fileName,
                candidateFileName = candidate,
                expectedDigest = expectedContent?.let(::canonicalContentDigest),
                applyAfterSave = applyAfterSave,
            )
            when (transaction) {
                // The module consumed or discarded the candidate itself; nothing here may clean up
                // after a transaction that already reported what it left behind.
                is PresetApplyTransaction.Reported -> transaction.outcome
                PresetApplyTransaction.Unsupported -> if (removeOrFalse(candidate)) {
                    saveStepwise(fileName, expectedContent, normalized, applyAfterSave)
                } else {
                    PresetMutationOutcome.RollbackFailed
                }
                PresetApplyTransaction.Indeterminate -> {
                    // The candidate name belongs to this attempt alone, so discarding it can never
                    // touch what the module published. Whether it is still there says nothing about
                    // the transaction, so the resolution below is read from the target instead.
                    removeOrFalse(candidate)
                    resolveIndeterminateSave(fileName, expectedContent, normalized, applyAfterSave)
                }
            }
        },
    )

    private fun publishCommittedMutation(outcome: PresetMutationOutcome): PresetMutationOutcome {
        if (outcome.durable in COMMITTED_PRESET_OUTCOMES) {
            presetStateRevision.publishCommittedMutation()
        }
        return outcome
    }

    private suspend fun saveTransaction(
        fileName: String,
        candidateFileName: String,
        expectedDigest: String?,
        applyAfterSave: Boolean,
    ): PresetApplyTransaction = try {
        runner.savePresetTransaction(fileName, candidateFileName, expectedDigest, applyAfterSave)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        PresetApplyTransaction.Indeterminate
    }

    /**
     * The module ran but did not prove what it left behind. Read published facts instead of
     * guessing.
     *
     * The target still carrying the content the editor started from means nothing was published,
     * which is the one direction that cannot have mutated anything. The target carrying the new
     * content is a completed save only where the module owed nothing further — an unselected
     * preset in auto mode — or where the selection now names it and the live generation is the one
     * this lease stamped. Everything else stays unproven, because a half-finished replacement and
     * a finished one are indistinguishable from the published state alone.
     */
    private suspend fun resolveIndeterminateSave(
        fileName: String,
        expectedContent: String?,
        normalized: String,
        applyAfterSave: Boolean,
    ): PresetMutationOutcome {
        val published = snapshotFileOrNull(fileName) ?: return PresetMutationOutcome.RollbackFailed
        val publishedContent = (published as? PresetFileSnapshot.Present)?.content
        if (publishedContent != null &&
            canonicalProtectedText(publishedContent) == canonicalProtectedText(normalized)
        ) {
            val selection = try {
                runner.snapshotActiveConfig()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            } ?: return PresetMutationOutcome.RollbackFailed
            if (selection.presetFile != fileName) {
                // A preset that governs nothing is never selected or replaced in auto mode, so the
                // published content is the entire transaction. Under an explicit apply the missing
                // selection is instead a commit that demonstrably did not land.
                return if (applyAfterSave) {
                    PresetMutationOutcome.RollbackFailed
                } else {
                    PresetMutationOutcome.Saved
                }
            }
            if (!booleanResult { runner.committedApplyIsProven() }) {
                return PresetMutationOutcome.RollbackFailed
            }
            // Whether the selection moved cannot be recovered once the answer is lost, so the
            // request decides: only an explicit apply could have committed one.
            return if (applyAfterSave) {
                PresetMutationOutcome.SavedAndApplied
            } else {
                PresetMutationOutcome.Applied
            }
        }
        val sourceUnchanged = when (published) {
            PresetFileSnapshot.Missing -> expectedContent == null
            is PresetFileSnapshot.Present -> expectedContent != null &&
                canonicalProtectedText(published.content) == canonicalProtectedText(expectedContent)
            PresetFileSnapshot.Unsafe -> false
        }
        return if (sourceUnchanged) PresetMutationOutcome.IoFailed else PresetMutationOutcome.RollbackFailed
    }

    /** Preserved only for module generations without the transactional entry point. */
    private suspend fun saveStepwise(
        fileName: String,
        expectedContent: String?,
        normalized: String,
        applyAfterSave: Boolean,
    ): PresetMutationOutcome {
        val oldFile = runner.snapshotFile(fileName)
        if (oldFile == PresetFileSnapshot.Unsafe) {
            return PresetMutationOutcome.Rejected(PresetIssue.PRESET_SYMLINK)
        }
        val sourceMatches = when (oldFile) {
            PresetFileSnapshot.Missing -> expectedContent == null
            is PresetFileSnapshot.Present -> expectedContent != null &&
                canonicalProtectedText(oldFile.content) == canonicalProtectedText(expectedContent)
            PresetFileSnapshot.Unsafe -> false
        }
        if (!sourceMatches) return PresetMutationOutcome.SourceChanged
        val oldConfig = runner.snapshotActiveConfig() ?: return PresetMutationOutcome.IoFailed
        val shouldApply = applyAfterSave || oldConfig.presetFile == fileName
        val wasRunning = if (shouldApply) runner.isServiceRunning() ?: return PresetMutationOutcome.IoFailed else false

        val candidate = candidateName(fileName)
        if (!booleanResult { runner.writeCandidate(candidate, normalized) }) {
            return cleanupCandidate(candidate, PresetMutationOutcome.IoFailed)
        }
        val candidateValidation = try {
            runner.validatePreset(candidate, fileName)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return cleanupCandidate(candidate, PresetMutationOutcome.IoFailed)
        }
        when (candidateValidation) {
            PresetValidation.Compatible -> Unit
            is PresetValidation.Quarantined -> {
                return cleanupCandidate(
                    candidate,
                    PresetMutationOutcome.Rejected(candidateValidation.issue),
                )
            }
            PresetValidation.ProtocolFailure -> {
                return cleanupCandidate(candidate, PresetMutationOutcome.IoFailed)
            }
        }
        if (!booleanResult { runner.replaceCandidate(candidate, fileName) }) {
            val candidateRemoved = removeOrFalse(candidate)
            val targetUnchanged = snapshotFileOrNull(fileName) == oldFile
            return when {
                targetUnchanged && candidateRemoved -> PresetMutationOutcome.IoFailed
                restoreFileOrFalse(fileName, oldFile) && candidateRemoved ->
                    PresetMutationOutcome.WriteFailedRolledBack
                else -> PresetMutationOutcome.RollbackFailed
            }
        }
        val persistedFile = snapshotFileOrNull(fileName)
        val persistedMatches = persistedFile is PresetFileSnapshot.Present &&
            canonicalProtectedText(persistedFile.content) == canonicalProtectedText(normalized)
        if (!persistedMatches) {
            return if (restoreFileOrFalse(fileName, oldFile)) {
                PresetMutationOutcome.WriteFailedRolledBack
            } else {
                PresetMutationOutcome.RollbackFailed
            }
        }
        if (!shouldApply) return PresetMutationOutcome.Saved

        val requestedConfig = ActivePresetConfig(fileName)
        when (writeConfigResult(requestedConfig)) {
            true -> Unit
            false -> return if (restoreFileOrFalse(fileName, oldFile)) {
                PresetMutationOutcome.WriteFailedRolledBack
            } else {
                PresetMutationOutcome.RollbackFailed
            }
            null -> {
                val configRestored = writeConfigOrFalse(oldConfig)
                val fileRestored = restoreFileOrFalse(fileName, oldFile)
                return if (configRestored && fileRestored) {
                    PresetMutationOutcome.WriteFailedRolledBack
                } else {
                    PresetMutationOutcome.RollbackFailed
                }
            }
        }
        if (!wasRunning) return PresetMutationOutcome.Saved
        if (restartOrFalse()) return PresetMutationOutcome.SavedAndApplied

        val configRestored = writeConfigOrFalse(oldConfig)
        val fileRestored = restoreFileOrFalse(fileName, oldFile)
        return if (configRestored && fileRestored) {
            PresetMutationOutcome.RestartFailedRolledBack
        } else {
            PresetMutationOutcome.RollbackFailed
        }
    }

    private suspend fun cleanupCandidate(
        candidate: String,
        cleanOutcome: PresetMutationOutcome,
    ): PresetMutationOutcome = if (removeOrFalse(candidate)) {
        cleanOutcome
    } else {
        PresetMutationOutcome.RollbackFailed
    }

    private suspend fun snapshotFileOrNull(fileName: String): PresetFileSnapshot? = try {
        runner.snapshotFile(fileName)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    private suspend fun restoreFileOrFalse(
        fileName: String,
        snapshot: PresetFileSnapshot,
    ): Boolean = booleanResult { runner.restoreFile(fileName, snapshot) }

    private suspend fun removeOrFalse(fileName: String): Boolean =
        booleanResult { runner.removeFile(fileName) }

    private suspend fun writeConfigOrFalse(config: ActivePresetConfig): Boolean =
        writeConfigResult(config) == true

    private suspend fun writeConfigResult(config: ActivePresetConfig): Boolean? = try {
        runner.writeActiveConfig(config)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    private suspend fun booleanResult(block: suspend () -> Boolean): Boolean = try {
        block()
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        false
    }

    private suspend fun restartOrFalse(): Boolean = try {
        runner.restart()
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        false
    }

    private suspend fun safelyMutate(
        block: suspend () -> PresetMutationOutcome,
    ): PresetMutationOutcome = try {
        withContext(Dispatchers.IO) { mutationGate.mutate(block) }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: ModuleMutationCoordinator.MutationBlockedException) {
        PresetMutationOutcome.Blocked
    } catch (_: Exception) {
        PresetMutationOutcome.IoFailed
    }

    /**
     * The content identity the module compares its save target against.
     *
     * It is taken over the same canonical projection both sides already agree on for equality, so
     * a trailing-newline or line-ending difference can never read as somebody else's edit.
     */
    private fun canonicalContentDigest(content: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(canonicalProtectedText(content).toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private fun candidateName(fileName: String): String =
        "_${fileName.removeSuffix(".txt").take(180)}.candidate.${System.nanoTime()}.txt"

    private fun previewCandidateName(fileName: String): String =
        "_${fileName.removeSuffix(".txt").take(180)}.preview.${System.nanoTime()}.txt"

    private companion object {
        val COMMITTED_PRESET_OUTCOMES = setOf(
            PresetDurableOutcome.APPLIED,
            PresetDurableOutcome.SAVED,
            PresetDurableOutcome.SAVED_AND_APPLIED,
        )
    }
}

@Module
@InstallIn(SingletonComponent::class)
internal abstract class PresetRepositoryModule {
    @Binds
    abstract fun bindPresetRepository(implementation: TransactionalPresetRepository): PresetRepository

    @Binds
    abstract fun bindActivePresetReader(implementation: TransactionalPresetRepository): ActivePresetReader

    @Binds
    abstract fun bindPresetRunner(implementation: RootPresetRunner): PresetRunner

    @Binds
    abstract fun bindPresetMutationGate(implementation: ModulePresetMutationGate): PresetMutationGate
}

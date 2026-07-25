package com.zapret2.app.data

import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

interface PresetRepository {
    suspend fun loadCatalog(): PresetCatalog?
    suspend fun readActive(): ActivePresetSource?
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
        if (records.lastOrNull() != "$APPLY_COMPLETE=1") return PresetApplyTransaction.Indeterminate
        val pairs = records.map { record ->
            val separator = record.indexOf('=')
            if (separator <= 0) return PresetApplyTransaction.Indeterminate
            record.substring(0, separator) to record.substring(separator + 1)
        }
        val counts = pairs.groupingBy { it.first }.eachCount()
        if (counts.keys != applyFields || applyFields.any { counts[it] != 1 }) {
            return PresetApplyTransaction.Indeterminate
        }
        val values = pairs.toMap()
        if (values[APPLY_SCHEMA] != APPLY_SCHEMA_VERSION) return PresetApplyTransaction.Indeterminate
        val error = LifecycleErrorContract.parseValues(values) ?: return PresetApplyTransaction.Indeterminate
        val committed = values.getValue(APPLY_CONFIG_COMMITTED).takeIf { it == "0" || it == "1" }
            ?: return PresetApplyTransaction.Indeterminate
        val wasRunning = values.getValue(APPLY_SERVICE_WAS_RUNNING).takeIf { it == "0" || it == "1" }
            ?: return PresetApplyTransaction.Indeterminate
        val issueCode = values.getValue(APPLY_ISSUE)
        val outcome = when (values.getValue(APPLY_OUTCOME)) {
            "APPLIED" -> PresetMutationOutcome.Applied
            "SAVED" -> PresetMutationOutcome.Saved
            "REJECTED" -> PresetMutationOutcome.Rejected(PresetIssue.fromWireCode(issueCode))
            "WRITE_FAILED", "IO_FAILED" -> PresetMutationOutcome.IoFailed
            "WRITE_FAILED_ROLLED_BACK" -> PresetMutationOutcome.WriteFailedRolledBack
            "RESTART_FAILED_ROLLED_BACK" -> PresetMutationOutcome.RestartFailedRolledBack
            "ROLLBACK_FAILED" -> PresetMutationOutcome.RollbackFailed
            "BLOCKED" -> PresetMutationOutcome.Blocked
            else -> return PresetApplyTransaction.Indeterminate
        }
        val rejectedName = outcome is PresetMutationOutcome.Rejected &&
            PresetIssue.fromWireCode(issueCode) == PresetIssue.UNSAFE_PRESET_NAME
        // An unsafe request is never echoed back, so only that refusal may omit the name.
        if (!rejectedName && values.getValue(APPLY_PRESET) != expectedFileName) {
            return PresetApplyTransaction.Indeterminate
        }
        if (rejectedName && values.getValue(APPLY_PRESET).isNotEmpty()) {
            return PresetApplyTransaction.Indeterminate
        }
        if (values.getValue(APPLY_PREVIOUS_PRESET).let { it.isNotEmpty() && !PresetNamePolicy.isValid(it) }) {
            return PresetApplyTransaction.Indeterminate
        }
        val consistent = when (outcome) {
            PresetMutationOutcome.Applied ->
                error.isNone && committed == "1" && wasRunning == "1" && issueCode == APPLY_ISSUE_NONE
            PresetMutationOutcome.Saved ->
                error.isNone && committed == "1" && wasRunning == "0" && issueCode == APPLY_ISSUE_NONE
            is PresetMutationOutcome.Rejected ->
                !error.isNone && committed == "0" && issueCode != APPLY_ISSUE_NONE
            else -> !error.isNone && issueCode == APPLY_ISSUE_NONE
        }
        if (!consistent) return PresetApplyTransaction.Indeterminate
        return PresetApplyTransaction.Reported(outcome)
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
        if (first.size != 5 || first[1] != "1" || first[2] != expectedLogicalName) {
            return PresetPreviewOutcome.Failed
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
            PresetCommandPreview(executable, arguments, tcpPorts, udpPorts),
        )
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
    }
}

@Singleton
internal class TransactionalPresetRepository @Inject constructor(
    private val runner: PresetRunner,
    private val mutationGate: PresetMutationGate,
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
    override suspend fun apply(fileName: String): PresetMutationOutcome = safelyMutate {
        if (!PresetNamePolicy.isValid(fileName)) {
            return@safelyMutate PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME)
        }
        when (val transaction = applyTransaction(fileName)) {
            PresetApplyTransaction.Unsupported -> applyStepwise(fileName)
            PresetApplyTransaction.Indeterminate -> resolveIndeterminateApply(fileName)
            is PresetApplyTransaction.Reported -> transaction.outcome
        }
    }

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

    override suspend fun save(
        fileName: String,
        expectedContent: String?,
        content: String,
        applyAfterSave: Boolean,
    ): PresetMutationOutcome = safelyMutate {
        if (!PresetNamePolicy.isValid(fileName)) {
            return@safelyMutate PresetMutationOutcome.Rejected(PresetIssue.UNSAFE_PRESET_NAME)
        }
        val normalized = PresetContentPolicy.normalizedForWrite(content)
        if (!PresetContentPolicy.isAllowed(normalized)) {
            return@safelyMutate PresetMutationOutcome.Rejected(PresetIssue.PRESET_TOO_LARGE)
        }
        val oldFile = runner.snapshotFile(fileName)
        if (oldFile == PresetFileSnapshot.Unsafe) {
            return@safelyMutate PresetMutationOutcome.Rejected(PresetIssue.PRESET_SYMLINK)
        }
        val sourceMatches = when (oldFile) {
            PresetFileSnapshot.Missing -> expectedContent == null
            is PresetFileSnapshot.Present -> expectedContent != null &&
                canonicalProtectedText(oldFile.content) == canonicalProtectedText(expectedContent)
            PresetFileSnapshot.Unsafe -> false
        }
        if (!sourceMatches) return@safelyMutate PresetMutationOutcome.SourceChanged
        val oldConfig = runner.snapshotActiveConfig() ?: return@safelyMutate PresetMutationOutcome.IoFailed
        val shouldApply = applyAfterSave || oldConfig.presetFile == fileName
        val wasRunning = if (shouldApply) runner.isServiceRunning() ?: return@safelyMutate PresetMutationOutcome.IoFailed else false

        val candidate = candidateName(fileName)
        if (!booleanResult { runner.writeCandidate(candidate, normalized) }) {
            return@safelyMutate cleanupCandidate(candidate, PresetMutationOutcome.IoFailed)
        }
        val candidateValidation = try {
            runner.validatePreset(candidate, fileName)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return@safelyMutate cleanupCandidate(candidate, PresetMutationOutcome.IoFailed)
        }
        when (candidateValidation) {
            PresetValidation.Compatible -> Unit
            is PresetValidation.Quarantined -> {
                return@safelyMutate cleanupCandidate(
                    candidate,
                    PresetMutationOutcome.Rejected(candidateValidation.issue),
                )
            }
            PresetValidation.ProtocolFailure -> {
                return@safelyMutate cleanupCandidate(candidate, PresetMutationOutcome.IoFailed)
            }
        }
        if (!booleanResult { runner.replaceCandidate(candidate, fileName) }) {
            val candidateRemoved = removeOrFalse(candidate)
            val targetUnchanged = snapshotFileOrNull(fileName) == oldFile
            return@safelyMutate when {
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
            return@safelyMutate if (restoreFileOrFalse(fileName, oldFile)) {
                PresetMutationOutcome.WriteFailedRolledBack
            } else {
                PresetMutationOutcome.RollbackFailed
            }
        }
        if (!shouldApply) return@safelyMutate PresetMutationOutcome.Saved

        val requestedConfig = ActivePresetConfig(fileName)
        when (writeConfigResult(requestedConfig)) {
            true -> Unit
            false -> return@safelyMutate if (restoreFileOrFalse(fileName, oldFile)) {
                PresetMutationOutcome.WriteFailedRolledBack
            } else {
                PresetMutationOutcome.RollbackFailed
            }
            null -> {
                val configRestored = writeConfigOrFalse(oldConfig)
                val fileRestored = restoreFileOrFalse(fileName, oldFile)
                return@safelyMutate if (configRestored && fileRestored) {
                    PresetMutationOutcome.WriteFailedRolledBack
                } else {
                    PresetMutationOutcome.RollbackFailed
                }
            }
        }
        if (!wasRunning) return@safelyMutate PresetMutationOutcome.Saved
        if (restartOrFalse()) return@safelyMutate PresetMutationOutcome.SavedAndApplied

        val configRestored = writeConfigOrFalse(oldConfig)
        val fileRestored = restoreFileOrFalse(fileName, oldFile)
        if (configRestored && fileRestored) PresetMutationOutcome.RestartFailedRolledBack
        else PresetMutationOutcome.RollbackFailed
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

    private fun candidateName(fileName: String): String =
        "_${fileName.removeSuffix(".txt").take(180)}.candidate.${System.nanoTime()}.txt"

    private fun previewCandidateName(fileName: String): String =
        "_${fileName.removeSuffix(".txt").take(180)}.preview.${System.nanoTime()}.txt"
}

@Module
@InstallIn(SingletonComponent::class)
internal abstract class PresetRepositoryModule {
    @Binds
    abstract fun bindPresetRepository(implementation: TransactionalPresetRepository): PresetRepository

    @Binds
    abstract fun bindPresetRunner(implementation: RootPresetRunner): PresetRunner

    @Binds
    abstract fun bindPresetMutationGate(implementation: ModulePresetMutationGate): PresetMutationGate
}

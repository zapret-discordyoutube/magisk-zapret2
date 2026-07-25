package com.zapret2.app.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

/** Canonical APK boundary for the same one-shot purge protocol used by module Action. */
object ModulePurgeController {

    private const val PURGE_SCRIPT =
        "${RootModuleContract.ACTIVE_MODULE_DIR}/${ModulePackageContract.PURGE_SCRIPT_PATH}"
    private val purgeInProgress = AtomicBoolean(false)

    enum class Status(val wireValue: String) {
        COMPLETE("complete"),
        PARTIAL("partial"),
        BLOCKED("blocked"),
        ERROR("error");

        companion object {
            fun fromWireValue(value: String): Status? = entries.firstOrNull { it.wireValue == value }
        }
    }

    data class PrepareReport(
        val token: String,
        val diagnostic: String,
    )

    data class Report(
        val status: Status,
        val processClean: Boolean,
        val firewallClean: Boolean,
        val moduleRemoved: Boolean,
        val stateRemoved: Boolean,
        val externalRemoved: Boolean,
        val apkTouched: Boolean,
        val rebootRequired: Boolean,
        val diagnostic: String,
    ) {
        /**
         * Every effect the purge itself owns: the service is down, the module directory, its
         * state tree and every external workspace are gone, the installed APK was never touched,
         * and the receipt demands the reboot that retires the module for good. A verified-clean
         * firewall is deliberately not part of it — the module tears the ruleset down either way
         * and withholds the assertion only when it could not re-read one family afterwards, which
         * the reboot this same receipt demands clears regardless.
         */
        val satisfiesRemovedContract: Boolean
            get() = processClean && moduleRemoved && stateRemoved && externalRemoved &&
                !apkTouched && rebootRequired

        val satisfiesCompleteContract: Boolean
            get() = status == Status.COMPLETE && satisfiesRemovedContract && firewallClean
    }

    sealed interface ParseResult<out T> {
        data class Valid<T>(val value: T) : ParseResult<T>
        data class Invalid(val error: String) : ParseResult<Nothing>
    }

    enum class Outcome {
        COMPLETE,
        PARTIAL,
        BLOCKED,
        ERROR,
        INVALID_PROTOCOL,
        COMMAND_FAILED,
    }

    data class Result(
        val outcome: Outcome,
        val report: Report? = null,
        val command: ServiceLifecycleController.CommandResult? = null,
        val error: String? = null,
        /** False only when the module receipt was honoured but APK-private state survived it. */
        val appDataCleared: Boolean = true,
    ) {
        val rebootRequired: Boolean get() = report?.rebootRequired == true

        /**
         * Whether the module itself is gone.
         *
         * A receipt never proves that alone. [outcome] is where everything the receipt cannot see
         * about itself is folded in — the exit status of the command that printed it, a protocol
         * the parser rejected, a mutation that was refused before it ran — so the two have to
         * agree before either is honoured. A module that printed a flawless `complete` record and
         * then had its command fail is classified [Outcome.INVALID_PROTOCOL] precisely because
         * that receipt cannot be trusted; honouring it anyway would erase APK-private state on the
         * word of a verdict the app had already rejected. For the same reason a receipt whose
         * command failed proves nothing under any outcome.
         *
         * `complete` is therefore honoured only under [Outcome.COMPLETE] and only with its whole
         * contract, verified-clean firewall included. `partial` is honoured only under
         * [Outcome.PARTIAL], and only for the single case the module reserves it for: everything
         * the purge owns was removed and the one fact left unproven is the firewall family the
         * pending reboot clears anyway. APK-private data belongs to a module that no longer exists
         * in that case too, so clearing it must not wait for a full receipt — but a `partial` that
         * claims a verified-clean firewall contradicts its own status and proves nothing, exactly
         * like one that admits touching the APK. Every other outcome proves nothing either.
         *
         * This is also the fact the screen resets on, and it is deliberately not [erased]: once
         * the module directory is gone the app cannot reach it again — the purge script went with
         * it — so a screen that kept describing an installed module would offer controls that
         * resolve to nothing, and only a process restart would rediscover that. Whether
         * APK-private state survived is a separate question with a separate answer,
         * [appDataCleared], and it never brings the module back.
         */
        val moduleFullyRemoved: Boolean
            get() = command?.success != false && when (outcome) {
                Outcome.COMPLETE -> report?.satisfiesCompleteContract == true
                Outcome.PARTIAL -> report?.let {
                    it.status == Status.PARTIAL && it.satisfiesRemovedContract && !it.firewallClean
                } == true
                else -> false
            }

        /**
         * The user-visible verdict: the module is gone and the APK-private state that belonged to
         * it went with it. Nothing is left to retry — the purge script was removed along with the
         * module — so an erase that only failed to prove one reboot-cleared fact must be reported
         * as done, with the reservation named beside it, and never as a failure the user could
         * act on. Because [moduleFullyRemoved] admits a non-[Outcome.COMPLETE] receipt only when
         * that receipt withheld [Report.firewallClean], the reservation shown beside an erased
         * result always names the fact the module actually left unproven.
         */
        val erased: Boolean get() = moduleFullyRemoved && appDataCleared

        /**
         * Records the one failure that happens after the module verdict is already in: the app's
         * own `pm clear` could not wipe APK-private state.
         *
         * [outcome] grades the module receipt, and this is not about the module — its directory,
         * its state tree and its purge script are gone, which is the only reason this step ran at
         * all. Rewriting the outcome here would put it at odds with the receipt it grades and, by
         * way of [moduleFullyRemoved], silently take back the fact the screen must obey. The
         * failure belongs to [appDataCleared] alone, and [erased] already demands both.
         */
        fun withAppDataRetained(): Result = copy(
            error = "Module data was removed, but APK-private state could not be cleared",
            appDataCleared = false,
        )

        fun diagnosticText(): String = listOfNotNull(
            error?.takeIf(String::isNotBlank),
            report?.diagnostic?.takeIf(String::isNotBlank),
            command?.diagnosticText()?.takeIf(String::isNotBlank),
        ).distinct().joinToString("\n")
    }

    fun isInProgress(): Boolean = purgeInProgress.get()

    suspend fun purge(appDataCleaner: ModulePurgeAppDataCleaner): Result {
        if (ServiceLifecycleController.isAppUpdateInProgress() ||
            ServiceLifecycleController.isFullRollbackInProgress() ||
            !purgeInProgress.compareAndSet(false, true)
        ) {
            return Result(Outcome.BLOCKED, error = "Another module mutation is already in progress")
        }
        if (ServiceLifecycleController.isAppUpdateInProgress() ||
            ServiceLifecycleController.isFullRollbackInProgress()
        ) {
            purgeInProgress.set(false)
            return Result(Outcome.BLOCKED, error = "Another module mutation is already in progress")
        }

        return try {
            ModuleMutationCoordinator.withLifecycleScript {
                ServiceLifecycleController.runExclusiveLifecycleTask {
                    withContext(NonCancellable) {
                        val moduleResult = purgeInsideExclusiveTask()
                        if (moduleResult.moduleFullyRemoved && !appDataCleaner.clear()) {
                            moduleResult.withAppDataRetained()
                        } else {
                            moduleResult
                        }
                    }
                }
            }
        } catch (blocked: ModuleMutationCoordinator.MutationBlockedException) {
            Result(Outcome.BLOCKED, error = blocked.message ?: "Module purge is blocked")
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Result(Outcome.ERROR, error = error.message ?: error.javaClass.simpleName)
        } finally {
            purgeInProgress.set(false)
        }
    }

    private suspend fun purgeInsideExclusiveTask(): Result {
        val prepareCommand = ServiceLifecycleController.executeRoot(
            "/system/bin/sh ${RootFileIo.shellQuote(PURGE_SCRIPT)} --prepare app --machine",
            RootCommandPolicy.LIFECYCLE,
        )
        val prepared = parsePrepareOutput(prepareCommand.stdout)
        if (prepared is ParseResult.Invalid) {
            return Result(
                outcome = if (prepareCommand.success) Outcome.INVALID_PROTOCOL else Outcome.COMMAND_FAILED,
                command = prepareCommand,
                error = prepared.error,
            )
        }
        val token = (prepared as ParseResult.Valid).value.token
        val commitCommand = ServiceLifecycleController.executeRoot(
            "/system/bin/sh ${RootFileIo.shellQuote(PURGE_SCRIPT)} --commit app " +
                "${RootFileIo.shellQuote(token)} --machine",
            RootCommandPolicy.LIFECYCLE,
        )
        val parsed = parseReportOutput(commitCommand.stdout)
        if (parsed is ParseResult.Invalid) {
            return Result(
                outcome = if (commitCommand.success) Outcome.INVALID_PROTOCOL else Outcome.COMMAND_FAILED,
                command = commitCommand,
                error = parsed.error,
            )
        }
        val report = (parsed as ParseResult.Valid).value
        return Result(
            outcome = classifyReport(report, commitCommand.success),
            report = report,
            command = commitCommand,
        )
    }

    /**
     * Grades a parsed receipt against the command that printed it.
     *
     * A `complete` record is honoured only when it satisfies its whole contract and its command
     * agreed; anything else claiming `complete` is a protocol violation. Every other status is
     * carried through as itself, so [Outcome.PARTIAL] means exactly "the module printed a `partial`
     * receipt" — which the module reserves for states reached after the removal fence is published.
     */
    internal fun classifyReport(report: Report, commandSucceeded: Boolean): Outcome = when {
        report.status == Status.COMPLETE && report.satisfiesCompleteContract && commandSucceeded ->
            Outcome.COMPLETE
        report.status == Status.COMPLETE -> Outcome.INVALID_PROTOCOL
        report.status == Status.PARTIAL -> Outcome.PARTIAL
        report.status == Status.BLOCKED -> Outcome.BLOCKED
        else -> Outcome.ERROR
    }

    internal fun parsePrepareOutput(lines: List<String>): ParseResult<PrepareReport> {
        val values = parseExactRecord(
            lines = lines,
            expectedKeys = setOf(
                "Z2_PURGE_PREPARE_VERSION",
                "Z2_PURGE_PREPARE_STATUS",
                "Z2_PURGE_PREPARE_TOKEN",
                "Z2_PURGE_PREPARE_DIAGNOSTIC",
                "Z2_PURGE_PREPARE_COMPLETE",
            ),
            terminal = "Z2_PURGE_PREPARE_COMPLETE=1",
        ) ?: return ParseResult.Invalid("Purge prepare protocol is incomplete or malformed")
        val token = values.getValue("Z2_PURGE_PREPARE_TOKEN")
        if (values["Z2_PURGE_PREPARE_VERSION"] != "1" ||
            values["Z2_PURGE_PREPARE_STATUS"] != "armed" ||
            !token.matches(Regex("[A-Za-z0-9._-]{1,128}"))
        ) {
            return ParseResult.Invalid("Purge prepare protocol rejected the one-time confirmation")
        }
        return ParseResult.Valid(PrepareReport(token, values.getValue("Z2_PURGE_PREPARE_DIAGNOSTIC")))
    }

    internal fun parseReportOutput(lines: List<String>): ParseResult<Report> {
        val booleanKeys = setOf(
            "Z2_PURGE_PROCESS_CLEAN",
            "Z2_PURGE_FIREWALL_CLEAN",
            "Z2_PURGE_MODULE_REMOVED",
            "Z2_PURGE_STATE_REMOVED",
            "Z2_PURGE_EXTERNAL_REMOVED",
            "Z2_PURGE_APK_TOUCHED",
            "Z2_PURGE_REBOOT_REQUIRED",
        )
        val expected = booleanKeys + setOf(
            "Z2_PURGE_VERSION",
            "Z2_PURGE_STATUS",
            "Z2_PURGE_DIAGNOSTIC",
            "Z2_PURGE_COMPLETE",
        )
        val values = parseExactRecord(lines, expected, "Z2_PURGE_COMPLETE=1")
            ?: return ParseResult.Invalid("Purge result protocol is incomplete or malformed")
        if (values["Z2_PURGE_VERSION"] != "1" || booleanKeys.any { values[it] !in setOf("0", "1") }) {
            return ParseResult.Invalid("Purge result protocol contains invalid values")
        }
        val status = Status.fromWireValue(values.getValue("Z2_PURGE_STATUS"))
            ?: return ParseResult.Invalid("Purge result protocol contains an unknown status")
        fun flag(key: String) = values.getValue(key) == "1"
        return ParseResult.Valid(
            Report(
                status = status,
                processClean = flag("Z2_PURGE_PROCESS_CLEAN"),
                firewallClean = flag("Z2_PURGE_FIREWALL_CLEAN"),
                moduleRemoved = flag("Z2_PURGE_MODULE_REMOVED"),
                stateRemoved = flag("Z2_PURGE_STATE_REMOVED"),
                externalRemoved = flag("Z2_PURGE_EXTERNAL_REMOVED"),
                apkTouched = flag("Z2_PURGE_APK_TOUCHED"),
                rebootRequired = flag("Z2_PURGE_REBOOT_REQUIRED"),
                diagnostic = values.getValue("Z2_PURGE_DIAGNOSTIC"),
            ),
        )
    }

    private fun parseExactRecord(
        lines: List<String>,
        expectedKeys: Set<String>,
        terminal: String,
    ): Map<String, String>? {
        if (lines.size != expectedKeys.size || lines.lastOrNull() != terminal) return null
        val pairs = lines.map { line ->
            val separator = line.indexOf('=')
            if (separator <= 0) return null
            line.substring(0, separator) to line.substring(separator + 1)
        }
        val counts = pairs.groupingBy { it.first }.eachCount()
        if (counts.keys != expectedKeys || expectedKeys.any { counts[it] != 1 }) return null
        return pairs.toMap()
    }
}

package com.zapret2.app.data

/**
 * Cross-process ownership protocol for ordinary Android-side module writes.
 *
 * The record intentionally remains readable by common.sh (pid/starttime/token), while the
 * additional exact fields let Android distinguish its own stale records from foreign lifecycle
 * owners. Unknown or malformed lifecycle locks are never removed by this protocol.
 */
internal object LifecycleMutationLockProtocol {
    private const val ABSENT_OUTPUT = "Z2_MUTATION_LOCK_ABSENT=1"

    private const val LEASE_SCRIPT =
        "${RootModuleContract.SCRIPTS_DIR}/lifecycle-lease.sh"
    private val safeToken = Regex("[A-Za-z0-9._-]+")
    private val bootId = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

    data class Lease(
        val pid: String,
        val starttime: String,
        val bootId: String,
        val token: String,
    )

    fun buildAcquireCommand(pid: Int, token: String): String? {
        if (pid <= 0 || !token.matches(safeToken) || token.length > 128) return null
        // The whole ownership ceremony lives in the packaged entry script,
        // where the module's interpreter shim applies; inlining it here would
        // run every fork under the app shell's interpreter instead.
        return "sh ${RootFileIo.shellQuote(LEASE_SCRIPT)} acquire " +
            "${RootFileIo.shellQuote(pid.toString())} ${RootFileIo.shellQuote(token)}"
    }

    fun parseAcquireOutput(lines: List<String>, pid: Int, token: String): Lease? {
        if (pid <= 0 || !token.matches(safeToken) || token.length > 128) return null
        val protocol = lines.map(String::trim)
        if (protocol.size != 5 || protocol.lastOrNull() != "Z2_MUTATION_LOCK_COMPLETE=1") return null
        val pairs = protocol.map { line ->
            val separator = line.indexOf('=')
            if (separator <= 0) return null
            line.substring(0, separator) to line.substring(separator + 1)
        }
        val keys = setOf(
            "Z2_MUTATION_LOCK_PID",
            "Z2_MUTATION_LOCK_START",
            "Z2_MUTATION_LOCK_BOOT",
            "Z2_MUTATION_LOCK_TOKEN",
            "Z2_MUTATION_LOCK_COMPLETE",
        )
        val counts = pairs.groupingBy { it.first }.eachCount()
        val values = pairs.toMap()
        if (counts.keys != keys || keys.any { counts[it] != 1 } ||
            values["Z2_MUTATION_LOCK_COMPLETE"] != "1" ||
            values["Z2_MUTATION_LOCK_PID"] != pid.toString() ||
            values["Z2_MUTATION_LOCK_TOKEN"] != token ||
            !ProtocolDecimal.isCanonicalNonNegativeLong(values["Z2_MUTATION_LOCK_START"].orEmpty()) ||
            !values["Z2_MUTATION_LOCK_BOOT"].orEmpty().matches(bootId)
        ) return null
        return Lease(
            pid = pid.toString(),
            starttime = values.getValue("Z2_MUTATION_LOCK_START"),
            bootId = values.getValue("Z2_MUTATION_LOCK_BOOT"),
            token = token,
        )
    }

    /** Probes only the exact record this app may have published after an ambiguous command result. */
    fun buildOwnedLeaseProbeCommand(pid: Int, token: String): String? {
        if (pid <= 0 || !token.matches(safeToken) || token.length > 128) return null
        return "sh ${RootFileIo.shellQuote(LEASE_SCRIPT)} probe " +
            "${RootFileIo.shellQuote(pid.toString())} ${RootFileIo.shellQuote(token)}"
    }

    fun isOwnedLeaseAbsentOutput(lines: List<String>): Boolean =
        lines.map(String::trim) == listOf(ABSENT_OUTPUT)

    fun buildReleaseCommand(lease: Lease, releaseToken: String): String? {
        if (!isValid(lease) || !releaseToken.matches(safeToken) || releaseToken.length > 128) return null
        return "sh ${RootFileIo.shellQuote(LEASE_SCRIPT)} release " +
            "${RootFileIo.shellQuote(lease.pid)} ${RootFileIo.shellQuote(lease.starttime)} " +
            "${RootFileIo.shellQuote(lease.bootId)} ${RootFileIo.shellQuote(lease.token)} " +
            RootFileIo.shellQuote(releaseToken)
    }

    fun parseReleaseOutput(lines: List<String>): Boolean {
        if (lines.size != 1) return false
        return lines.single().trim() == "Z2_MUTATION_LOCK_RELEASED=1"
    }

    private fun isValid(lease: Lease): Boolean {
        return lease.pid.matches(Regex("[1-9][0-9]*")) &&
            ProtocolDecimal.isCanonicalNonNegativeLong(lease.starttime) &&
            lease.bootId.matches(bootId) &&
            lease.token.matches(safeToken) && lease.token.length <= 128
    }
}

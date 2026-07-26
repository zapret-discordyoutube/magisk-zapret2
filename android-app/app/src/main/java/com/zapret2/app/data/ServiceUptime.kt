package com.zapret2.app.data

import android.system.Os
import android.system.OsConstants

private const val MILLIS_PER_SECOND = 1_000L

/**
 * The default USER_HZ every Linux ABI exports `/proc/<pid>/stat` field 22 in.
 *
 * The kernel converts its internal tick rate to USER_HZ before printing, so this is a property of
 * the ABI and not of the running kernel. It is only a fallback: the real value is whatever this
 * process' libc reports for `_SC_CLK_TCK`.
 */
private const val DEFAULT_TICKS_PER_SECOND = 100L

/**
 * The boot-clock instant at which the module's verified process started.
 *
 * Uptime is a *derived* quantity here, never a sampled one. The lifecycle boundary already proves
 * the identity of the process it owns with the pair (pid, starttime) — field 22 of
 * `/proc/<pid>/stat`, published on the status payload as `Z2_PID_STARTTIME` — and that anchor does
 * not move for as long as the process lives. Projecting it once onto the app's own boot clock is
 * therefore enough for the screen to render a live counter with no further privileged call, and it
 * cannot drift: two status reads of the same process compute the identical anchor.
 *
 * The design this replaced sampled `ps -o etime=` inside the privileged process-metrics probe and
 * published the formatted string it printed. Nothing ever re-sampled it — the app deliberately runs
 * no status polling loop — so the screen showed whatever wall time the process happened to have
 * accumulated at the instant of the last status read, which for the read that immediately follows
 * `zapret-start.sh` is zero, and it stayed frozen there until the next unrelated refresh. It also
 * spent a privileged fork per status read on a `ps` field that is not part of any toybox contract.
 */
data class ServiceUptimeAnchor(val startElapsedRealtimeMillis: Long) {

    /** Whole seconds the process has been alive as of [nowElapsedRealtimeMillis]. */
    fun elapsedSecondsAt(nowElapsedRealtimeMillis: Long): Long =
        elapsedMillisAt(nowElapsedRealtimeMillis) / MILLIS_PER_SECOND

    /**
     * Milliseconds until [elapsedSecondsAt] changes.
     *
     * A ticker that sleeps a flat second accumulates the cost of every wake-up as visible drift and
     * eventually skips a displayed second. Sleeping to the next boundary of *this* anchor keeps the
     * label aligned with the process it describes however late a wake-up is delivered.
     */
    fun millisUntilNextSecondAt(nowElapsedRealtimeMillis: Long): Long =
        MILLIS_PER_SECOND - elapsedMillisAt(nowElapsedRealtimeMillis) % MILLIS_PER_SECOND

    /**
     * A process cannot have started after the observation that found it running. Clamping keeps a
     * clock disagreement — a starttime the kernel measured on a clock this device does not report
     * through `elapsedRealtime()` — showing a fresh process instead of a negative age.
     */
    private fun elapsedMillisAt(nowElapsedRealtimeMillis: Long): Long =
        (nowElapsedRealtimeMillis - startElapsedRealtimeMillis).coerceAtLeast(0L)
}

/**
 * Converts a `/proc/<pid>/stat` start time into the boot-clock milliseconds
 * [android.os.SystemClock.elapsedRealtime] counts.
 *
 * Both quantities are measured from the same origin — the kernel stamps a process' start time from
 * the boot clock, which advances across suspend exactly as `elapsedRealtime()` does — so the
 * conversion is a unit change and nothing else.
 */
internal fun processStartElapsedRealtimeMillis(startTicks: Long, ticksPerSecond: Long): Long =
    startTicks * MILLIS_PER_SECOND / ticksPerSecond

/**
 * The single place the platform's tick rate enters the projection.
 *
 * Everything else about the uptime — which payloads prove one, and how ticks become boot-clock
 * milliseconds — is pure and covered by unit tests; this object holds only the constant that has to
 * come from libc.
 */
internal object ServiceUptimeClock {

    private val ticksPerSecond: Long by lazy {
        Os.sysconf(OsConstants._SC_CLK_TCK).takeIf { it > 0 } ?: DEFAULT_TICKS_PER_SECOND
    }

    fun anchorFor(startTicks: Long): ServiceUptimeAnchor =
        ServiceUptimeAnchor(processStartElapsedRealtimeMillis(startTicks, ticksPerSecond))
}

/**
 * The process start time a status payload proves, or `null` when it proves no live process.
 *
 * The proof required is exactly the one the process card already rests on: the module reports a
 * running process *and* certified its (pid, starttime) identity. An unverified pid carries no
 * starttime worth projecting, and a payload that describes no process must retire the counter
 * rather than let the previous one keep running against a process that is gone.
 */
internal fun ServiceLifecycleController.ServiceStatus.provenProcessStartTicks(): Long? {
    if (!processRunning || !pidVerified) return null
    if (!ProtocolDecimal.isCanonicalNonNegativeLong(pidStarttime)) return null
    return pidStarttime.toLongOrNull()
}

/** The uptime anchor a status payload proves, projected onto this device's boot clock. */
internal fun ServiceLifecycleController.ServiceStatus.serviceUptimeAnchor(): ServiceUptimeAnchor? =
    provenProcessStartTicks()?.let(ServiceUptimeClock::anchorFor)

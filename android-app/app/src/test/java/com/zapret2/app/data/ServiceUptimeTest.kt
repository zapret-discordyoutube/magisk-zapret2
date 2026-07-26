package com.zapret2.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The uptime contract: a fixed anchor the screen counts from, derived from the same (pid,
 * starttime) identity the lifecycle boundary already proves.
 *
 * The regression these tests pin is the one the previous design could not avoid. Uptime used to be
 * a string sampled from `ps -o etime=` during the privileged process-metrics probe, published into
 * the UI state as-is. The app runs no status polling loop by design, so the only reads that ever
 * refreshed it were the ones bracketing an explicit user action — and the read that follows
 * `zapret-start.sh` sees a process that is zero or one second old. The screen therefore showed
 * "0:00", froze there for the whole session, and appeared to come alive only when the next action
 * (a stop) triggered another read. An anchor cannot behave that way: it does not carry a duration
 * at all, so the instant it was sampled is irrelevant to what the screen displays.
 */
class ServiceUptimeTest {

    private val ticksPerSecond = 100L

    @Test
    fun startTicksBecomeBootClockMilliseconds() {
        assertEquals(0L, processStartElapsedRealtimeMillis(0L, ticksPerSecond))
        assertEquals(10L, processStartElapsedRealtimeMillis(1L, ticksPerSecond))
        assertEquals(12_340L, processStartElapsedRealtimeMillis(1_234L, ticksPerSecond))
        // A kernel exporting a different USER_HZ changes the unit, not the instant.
        assertEquals(12_340L, processStartElapsedRealtimeMillis(2_468L, 200L))
    }

    /**
     * The regression itself: what the screen shows is a function of the current clock, not of when
     * the status was read. A read taken one second into the process' life and a read taken three
     * hours later both describe the same instant and both render the same live age.
     */
    @Test
    fun theDisplayedAgeFollowsTheClockAndNotTheSamplingInstant() {
        val startedAt = 60_000L
        val anchor = ServiceUptimeAnchor(startElapsedRealtimeMillis = startedAt)

        assertEquals(1L, anchor.elapsedSecondsAt(startedAt + 1_000L))
        assertEquals(3_600L, anchor.elapsedSecondsAt(startedAt + 3_600_000L))
        assertEquals(86_400L, anchor.elapsedSecondsAt(startedAt + 86_400_000L))
    }

    /** Two reads of one process must re-derive the identical anchor, or the counter would jump. */
    @Test
    fun repeatedReadsOfTheSameProcessAnchorIdentically() {
        val first = runningStatus(startTicks = "512345").provenProcessStartTicks()
        val second = runningStatus(startTicks = "512345").provenProcessStartTicks()

        assertEquals(512_345L, first)
        assertEquals(first, second)
    }

    /** A partial second must never be rounded up into a second the process has not lived yet. */
    @Test
    fun secondsAreTruncatedNotRounded() {
        val anchor = ServiceUptimeAnchor(startElapsedRealtimeMillis = 0L)

        assertEquals(0L, anchor.elapsedSecondsAt(999L))
        assertEquals(1L, anchor.elapsedSecondsAt(1_000L))
        assertEquals(1L, anchor.elapsedSecondsAt(1_999L))
    }

    /**
     * The ticker sleeps to the anchor's own boundary, so a late wake-up shortens the next sleep
     * instead of pushing every later tick back by the same amount.
     */
    @Test
    fun theNextTickIsScheduledOnTheAnchorsSecondBoundary() {
        val anchor = ServiceUptimeAnchor(startElapsedRealtimeMillis = 250L)

        assertEquals(1_000L, anchor.millisUntilNextSecondAt(250L))
        assertEquals(750L, anchor.millisUntilNextSecondAt(500L))
        assertEquals(1L, anchor.millisUntilNextSecondAt(1_249L))
        assertEquals(1_000L, anchor.millisUntilNextSecondAt(1_250L))
    }

    /**
     * A process cannot predate the observation that found it. A clock disagreement must degrade to
     * a fresh process, never to a negative age or a modulo that walks backwards.
     */
    @Test
    fun anObservationOlderThanTheStartReadsAsAFreshProcess() {
        val anchor = ServiceUptimeAnchor(startElapsedRealtimeMillis = 10_000L)

        assertEquals(0L, anchor.elapsedSecondsAt(0L))
        assertEquals(1_000L, anchor.millisUntilNextSecondAt(0L))
    }

    /**
     * The counter rests on the module's own identity proof. Anything weaker describes a process
     * whose (pid, starttime) pair the module refused to certify, and there is nothing to count.
     */
    @Test
    fun onlyACertifiedLiveProcessAnchorsACounter() {
        assertEquals(4_242L, runningStatus(startTicks = "4242").provenProcessStartTicks())
        assertNull(runningStatus(startTicks = "4242", pidVerified = false).provenProcessStartTicks())
        assertNull(
            runningStatus(startTicks = "4242", processRunning = false).provenProcessStartTicks(),
        )
        assertNull(runningStatus(startTicks = "").provenProcessStartTicks())
    }

    /**
     * Payload values are consumed exactly as strictly as the rest of the status contract: the wire
     * carries canonical decimals, and anything else is a payload the app must not interpret.
     */
    @Test
    fun nonCanonicalStartTimesAreRefusedRatherThanCoerced() {
        listOf("04242", "-1", "42.0", " 42", "42 ", "0x2a", "٤٢").forEach { value ->
            assertNull(
                "start time \"$value\" must not be accepted",
                runningStatus(startTicks = value).provenProcessStartTicks(),
            )
        }
        // Zero is legal on the wire: the kernel reports it for a process started at boot.
        assertEquals(0L, runningStatus(startTicks = "0").provenProcessStartTicks())
    }

    private fun runningStatus(
        startTicks: String,
        processRunning: Boolean = true,
        pidVerified: Boolean = true,
    ) = ServiceLifecycleController.ServiceStatus(
        rootGranted = true,
        processRunning = processRunning,
        pid = "4242",
        pidVerified = pidVerified,
        pidStarttime = startTicks,
        declaredStatus = "ok",
        metadataComplete = true,
    )
}

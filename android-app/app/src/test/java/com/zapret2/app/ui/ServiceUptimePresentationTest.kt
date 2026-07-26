package com.zapret2.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * How a whole-second uptime is rendered.
 *
 * The clock part is fixed-width in every shipped locale, so it is produced here; only the day count
 * needs a localized unit and is left to the caller's string resource.
 */
class ServiceUptimePresentationTest {

    @Test
    fun secondsBelowADayRenderAsAFixedWidthClock() {
        assertEquals("00:00:00", serviceUptimeDisplay(0L).clock)
        assertEquals("00:00:09", serviceUptimeDisplay(9L).clock)
        assertEquals("00:01:00", serviceUptimeDisplay(60L).clock)
        assertEquals("01:00:00", serviceUptimeDisplay(3_600L).clock)
        assertEquals("23:59:59", serviceUptimeDisplay(86_399L).clock)
    }

    /** Hours must roll into days rather than growing without bound. */
    @Test
    fun wholeDaysAreCarriedOutOfTheClock() {
        val oneDay = serviceUptimeDisplay(86_400L)
        assertEquals(1L, oneDay.days)
        assertEquals("00:00:00", oneDay.clock)

        val longRun = serviceUptimeDisplay(3L * 86_400L + 11_464L)
        assertEquals(3L, longRun.days)
        assertEquals("03:11:04", longRun.clock)
    }

    @Test
    fun shortUptimesCarryNoDayCount() {
        assertEquals(0L, serviceUptimeDisplay(86_399L).days)
    }

    /**
     * The formatter is total: a caller that somehow computes a negative age gets the zero the
     * anchor's own clamp would have produced, never a malformed or negative clock.
     */
    @Test
    fun negativeInputRendersAsAFreshProcess() {
        val display = serviceUptimeDisplay(-1L)
        assertEquals(0L, display.days)
        assertEquals("00:00:00", display.clock)
    }
}

package com.zapret2.app.ui

import android.os.SystemClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.zapret2.app.R
import com.zapret2.app.data.ServiceUptimeAnchor
import java.util.Locale
import kotlinx.coroutines.delay

private const val SECONDS_PER_MINUTE = 60L
private const val SECONDS_PER_HOUR = 60L * SECONDS_PER_MINUTE
private const val SECONDS_PER_DAY = 24L * SECONDS_PER_HOUR

/**
 * A whole-second uptime split into the part that needs a localized unit and the part that does not.
 *
 * Hours, minutes and seconds are a fixed-width clock in every locale the app ships; only the day
 * count carries a word, so only it is resolved from resources.
 */
internal data class ServiceUptimeDisplay(val days: Long, val clock: String)

internal fun serviceUptimeDisplay(totalSeconds: Long): ServiceUptimeDisplay {
    val seconds = totalSeconds.coerceAtLeast(0L)
    val withinDay = seconds % SECONDS_PER_DAY
    return ServiceUptimeDisplay(
        days = seconds / SECONDS_PER_DAY,
        clock = String.format(
            Locale.ROOT,
            "%02d:%02d:%02d",
            withinDay / SECONDS_PER_HOUR,
            withinDay % SECONDS_PER_HOUR / SECONDS_PER_MINUTE,
            withinDay % SECONDS_PER_MINUTE,
        ),
    )
}

/**
 * A live uptime label for [anchor], or `null` when no status read proved a running process.
 *
 * The counter is advanced by the screen, not by the status boundary: the anchor is a fixed instant,
 * so every tick is a pure recomputation against the boot clock and costs no privileged call. It is
 * self-correcting for the same reason — a tick delivered late, or the first tick after the screen
 * comes back from STOPPED, reads the current clock and lands on the right second rather than
 * continuing a count of its own wake-ups.
 *
 * The loop is bound to the STARTED lifecycle, so a backgrounded screen holds no timer, and it
 * sleeps to the anchor's own second boundary instead of a flat second so the label never drifts.
 */
@Composable
internal fun rememberServiceUptimeLabel(anchor: ServiceUptimeAnchor?): String? {
    if (anchor == null) return null
    val lifecycleOwner = LocalLifecycleOwner.current
    val elapsedSeconds by produceState(
        anchor.elapsedSecondsAt(SystemClock.elapsedRealtime()),
        anchor,
        lifecycleOwner,
    ) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                val now = SystemClock.elapsedRealtime()
                value = anchor.elapsedSecondsAt(now)
                delay(anchor.millisUntilNextSecondAt(now))
            }
        }
    }
    val display = serviceUptimeDisplay(elapsedSeconds)
    return if (display.days > 0) {
        stringResource(R.string.control_uptime_days, display.days, display.clock)
    } else {
        display.clock
    }
}

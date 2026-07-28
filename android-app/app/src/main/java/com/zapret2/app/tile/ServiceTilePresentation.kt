package com.zapret2.app.tile

import android.service.quicksettings.Tile
import androidx.annotation.StringRes
import com.zapret2.app.R
import com.zapret2.app.data.ServiceLifecycleController
import com.zapret2.app.viewmodel.confirmedRunning

/**
 * What the Quick Settings tile shows, derived from one status read.
 *
 * Kept apart from the [android.service.quicksettings.TileService] itself because this is the
 * whole decision the tile makes: the service around it only reads a status and hands the verdict
 * to the platform.
 */
internal enum class ServiceTileState(
    val tileState: Int,
    @param:StringRes val subtitle: Int,
    val actionable: Boolean,
) {
    /** Verified running: the process is owned and its ruleset is published. */
    RUNNING(Tile.STATE_ACTIVE, R.string.tile_subtitle_running, actionable = true),

    /** Root works and the module answers, but nothing of ours is running. */
    STOPPED(Tile.STATE_INACTIVE, R.string.tile_subtitle_stopped, actionable = true),

    /**
     * A lifecycle transition, module update or full rollback owns the module right now.
     *
     * Deliberately not actionable: those operations serialize against the same lock this tile
     * would take, so accepting the tap would only queue a request behind work the user cannot
     * see from the shade.
     */
    BUSY(Tile.STATE_UNAVAILABLE, R.string.tile_subtitle_busy, actionable = false),

    /** No root, or the module is absent, disabled or unreadable. */
    UNAVAILABLE(Tile.STATE_UNAVAILABLE, R.string.tile_subtitle_unavailable, actionable = false),
}

/**
 * Projects a status read into the tile.
 *
 * [status] is null when the read itself failed, which is not the same as a stopped service and
 * must never be offered as one: tapping it would try to start a service on a device whose root
 * or module state could not be established at all.
 */
internal fun serviceTileState(
    status: ServiceLifecycleController.ServiceStatus?,
    transitionInFlight: Boolean,
    moduleMutationInFlight: Boolean,
): ServiceTileState = when {
    transitionInFlight || moduleMutationInFlight -> ServiceTileState.BUSY
    status == null -> ServiceTileState.UNAVAILABLE
    !status.rootGranted -> ServiceTileState.UNAVAILABLE
    status.lifecycleState == ServiceLifecycleController.LifecycleState.OWNED ||
        status.lifecycleState == ServiceLifecycleController.LifecycleState.ACTIVE ->
        ServiceTileState.BUSY
    confirmedRunning(status) -> ServiceTileState.RUNNING
    else -> ServiceTileState.STOPPED
}

/** The action a tap performs, or null when the tile is not offering one. */
internal fun serviceTileAction(state: ServiceTileState): ServiceTileAction? = when (state) {
    ServiceTileState.RUNNING -> ServiceTileAction.STOP
    ServiceTileState.STOPPED -> ServiceTileAction.START
    ServiceTileState.BUSY, ServiceTileState.UNAVAILABLE -> null
}

/**
 * What an accepted tap should do, decided without the tap's own transition flag.
 *
 * A tap marks itself in flight before it can read the status it needs, so asking the ordinary
 * projection at that point would answer BUSY on account of the very tap being decided and the
 * tile would do nothing at all. Work owned by anyone else still refuses the tap.
 */
internal fun serviceTileTapAction(
    status: ServiceLifecycleController.ServiceStatus?,
    moduleMutationInFlight: Boolean,
): ServiceTileAction? = serviceTileAction(
    serviceTileState(
        status = status,
        transitionInFlight = false,
        moduleMutationInFlight = moduleMutationInFlight,
    ),
)

internal enum class ServiceTileAction { START, STOP }

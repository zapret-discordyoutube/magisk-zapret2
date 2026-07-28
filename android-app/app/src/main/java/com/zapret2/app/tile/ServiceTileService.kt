package com.zapret2.app.tile

import android.os.Build
import android.service.quicksettings.TileService
import com.zapret2.app.R
import com.zapret2.app.data.ServiceLifecycleController
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Starts and stops the service from the notification shade.
 *
 * A tile is a short-lived binding: the platform tears the service down as soon as the shade
 * closes, while a lifecycle transition holds a root shell for as long as the module needs.
 * The work therefore runs in a process-scoped scope rather than in this instance's, and the
 * tile is refreshed from whatever binding is listening when the transition ends — possibly a
 * later one, possibly none, which is why [onStartListening] always re-reads instead of trusting
 * what it last drew.
 */
class ServiceTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    override fun onClick() {
        super.onClick()
        // Lifecycle transitions need root and change how the device reaches the network, so
        // they are not something to accept from a locked screen.
        if (isLocked) {
            unlockAndRun { toggle() }
        } else {
            toggle()
        }
    }

    private fun toggle() {
        // The controller serializes transitions internally; this only keeps repeated taps from
        // queueing a second one behind the first, where the user would see nothing happen.
        if (!transitionInFlight.compareAndSet(false, true)) return
        render(ServiceTileState.BUSY)
        scope.launch {
            try {
                val status = readStatusOrNull()
                when (serviceTileTapAction(status, moduleMutationInFlight())) {
                    ServiceTileAction.START -> ServiceLifecycleController.start()
                    ServiceTileAction.STOP -> ServiceLifecycleController.stop()
                    null -> Unit
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // The next read is authoritative; a failed transition needs no tile of its own.
            } finally {
                transitionInFlight.set(false)
                refreshFromWorker()
            }
        }
    }

    private fun refresh() {
        scope.launch {
            val state = currentState(readStatusOrNull())
            withContext(Dispatchers.Main) { render(state) }
        }
    }

    private suspend fun refreshFromWorker() {
        val state = currentState(readStatusOrNull())
        withContext(Dispatchers.Main) { render(state) }
    }

    private suspend fun readStatusOrNull(): ServiceLifecycleController.ServiceStatus? = try {
        ServiceLifecycleController.getStatus()
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    private fun currentState(
        status: ServiceLifecycleController.ServiceStatus?,
    ): ServiceTileState = serviceTileState(
        status = status,
        transitionInFlight = transitionInFlight.get(),
        moduleMutationInFlight = moduleMutationInFlight(),
    )

    private fun moduleMutationInFlight(): Boolean =
        ServiceLifecycleController.isAppUpdateInProgress() ||
            ServiceLifecycleController.isFullRollbackInProgress()

    /** No-op when nothing is listening: the platform hands out [qsTile] only while bound. */
    private fun render(state: ServiceTileState) {
        val tile = qsTile ?: return
        tile.state = state.tileState
        tile.label = getString(R.string.tile_label)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = getString(state.subtitle)
        }
        tile.contentDescription = getString(R.string.tile_label) +
            ": " + getString(state.subtitle)
        tile.updateTile()
    }

    private companion object {
        /**
         * Deliberately outlives any single tile binding, and nothing else.
         *
         * The platform destroys this service the moment the shade closes, while a transition
         * started from it holds a root shell for as long as the module needs. Scoping the work
         * to the binding would abandon it half-way; scoping it here ties it to the process,
         * which is the only thing that outlives every binding and still dies with the app.
         * It launches exactly one job per tap and never polls — see ComposeLifecyclePolicyTest.
         */
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private val transitionInFlight = AtomicBoolean(false)
    }
}

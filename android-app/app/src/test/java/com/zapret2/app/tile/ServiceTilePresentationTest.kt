package com.zapret2.app.tile

import android.service.quicksettings.Tile
import com.zapret2.app.data.ServiceLifecycleController
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The tile acts on one tap with no screen to explain itself on, so the only protection against
 * acting on a state it misread is that the projection is exact about which reads are actionable.
 */
class ServiceTilePresentationTest {

    /** Everything the controller requires before it calls a service verified-running. */
    private fun healthyStatus() = ServiceLifecycleController.ServiceStatus(
        rootGranted = true,
        processRunning = true,
        pid = "1234",
        nfqueueRulesCount = 4,
        iptablesActive = true,
        declaredStatus = "ok",
        pidVerified = true,
        pidStarttime = "100",
        ownerGeneration = "generation-1",
        qnum = 200,
        ipv4Active = true,
        expectedRulesCount = 4,
        ipv4RulesCount = 4,
        nfqueueSupported = true,
        queueBypassSupported = true,
        rulesetVerified = true,
        ownerMetadataVerified = true,
        lifecycleState = ServiceLifecycleController.LifecycleState.IDLE,
        metadataComplete = true,
    ).also { check(it.healthy) { "fixture must satisfy the controller's own health contract" } }

    @Test
    fun aVerifiedServiceIsTheOnlyThingShownAsRunning() {
        val running = serviceTileState(
            status = healthyStatus(),
            transitionInFlight = false,
            moduleMutationInFlight = false,
        )

        assertEquals(ServiceTileState.RUNNING, running)
        assertEquals(Tile.STATE_ACTIVE, running.tileState)
        assertEquals(ServiceTileAction.STOP, serviceTileAction(running))
    }

    @Test
    fun aStoppedServiceOffersToStart() {
        val stopped = serviceTileState(
            status = ServiceLifecycleController.ServiceStatus(
                rootGranted = true,
                processRunning = false,
            ),
            transitionInFlight = false,
            moduleMutationInFlight = false,
        )

        assertEquals(ServiceTileState.STOPPED, stopped)
        assertEquals(Tile.STATE_INACTIVE, stopped.tileState)
        assertEquals(ServiceTileAction.START, serviceTileAction(stopped))
    }

    /**
     * A read that failed says nothing about the service. Rendering it as stopped would put a
     * start action under a device whose root or module state was never established.
     */
    @Test
    fun anUnreadableStatusIsNeverOfferedAsStopped() {
        val unknown = serviceTileState(
            status = null,
            transitionInFlight = false,
            moduleMutationInFlight = false,
        )

        assertEquals(ServiceTileState.UNAVAILABLE, unknown)
        assertEquals(Tile.STATE_UNAVAILABLE, unknown.tileState)
        assertNull(serviceTileAction(unknown))
    }

    @Test
    fun withoutRootThereIsNothingToToggle() {
        val noRoot = serviceTileState(
            status = ServiceLifecycleController.ServiceStatus(
                rootGranted = false,
                processRunning = false,
            ),
            transitionInFlight = false,
            moduleMutationInFlight = false,
        )

        assertEquals(ServiceTileState.UNAVAILABLE, noRoot)
        assertNull(serviceTileAction(noRoot))
    }

    /**
     * Every one of these serializes against the lock a tap would take, so the tap is refused
     * rather than queued behind work the shade cannot show.
     */
    @Test
    fun workAlreadyHoldingTheModuleRefusesTheTap() {
        val ownedByAnother = serviceTileState(
            status = ServiceLifecycleController.ServiceStatus(
                rootGranted = true,
                processRunning = false,
                lifecycleState = ServiceLifecycleController.LifecycleState.ACTIVE,
            ),
            transitionInFlight = false,
            moduleMutationInFlight = false,
        )
        assertEquals(ServiceTileState.BUSY, ownedByAnother)
        assertNull(serviceTileAction(ownedByAnother))

        assertEquals(
            ServiceTileState.BUSY,
            serviceTileState(
                status = healthyStatus(),
                transitionInFlight = true,
                moduleMutationInFlight = false,
            ),
        )
        assertEquals(
            ServiceTileState.BUSY,
            serviceTileState(
                status = healthyStatus(),
                transitionInFlight = false,
                moduleMutationInFlight = true,
            ),
        )
    }

    /**
     * A tap marks itself in flight before it can read the status it is about to act on. Asking
     * the ordinary projection at that moment answers BUSY because of that very tap, and the tile
     * silently does nothing — which is exactly how the first build of this tile behaved.
     */
    @Test
    fun aTapIsNotRefusedByItsOwnTransition() {
        val running = healthyStatus()

        assertEquals(
            ServiceTileState.BUSY,
            serviceTileState(
                status = running,
                transitionInFlight = true,
                moduleMutationInFlight = false,
            ),
        )
        assertEquals(
            ServiceTileAction.STOP,
            serviceTileTapAction(running, moduleMutationInFlight = false),
        )
        assertEquals(
            ServiceTileAction.START,
            serviceTileTapAction(
                ServiceLifecycleController.ServiceStatus(
                    rootGranted = true,
                    processRunning = false,
                ),
                moduleMutationInFlight = false,
            ),
        )
    }

    /** Work owned by anything other than this tap still refuses it. */
    @Test
    fun aTapIsStillRefusedByWorkItDoesNotOwn() {
        assertNull(serviceTileTapAction(healthyStatus(), moduleMutationInFlight = true))
        assertNull(serviceTileTapAction(null, moduleMutationInFlight = false))
        assertNull(
            serviceTileTapAction(
                ServiceLifecycleController.ServiceStatus(
                    rootGranted = true,
                    processRunning = false,
                    lifecycleState = ServiceLifecycleController.LifecycleState.ACTIVE,
                ),
                moduleMutationInFlight = false,
            ),
        )
    }

    /** A tile the platform draws as unavailable must never carry an action behind it. */
    @Test
    fun everyUnavailableStateIsInert() {
        ServiceTileState.entries.forEach { state ->
            if (state.tileState == Tile.STATE_UNAVAILABLE) {
                assertNull("$state must not be actionable", serviceTileAction(state))
                assertEquals("$state must not be actionable", false, state.actionable)
            } else {
                assertEquals("$state must be actionable", true, state.actionable)
            }
        }
    }
}

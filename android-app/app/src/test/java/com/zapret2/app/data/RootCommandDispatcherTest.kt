package com.zapret2.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class RootCommandDispatcherTest {

    @Test
    fun observationRunsWhilePrivilegedLaneIsOccupied() {
        val privilegedEntered = CountDownLatch(1)
        val privilegedRelease = CountDownLatch(1)
        val privilegedSession = object : RootCommandSession {
            override fun submit(command: String): Future<RootCommandResult> {
                val future = CompletableFuture<RootCommandResult>()
                privilegedEntered.countDown()
                CompletableFuture.runAsync {
                    privilegedRelease.await()
                    future.complete(RootCommandResult(code = 0))
                }
                return future
            }

            override fun close() = Unit
        }
        val observationSession = CountingSession(RootCommandResult(code = 0, out = listOf("observed")))
        val dispatcher = RootCommandDispatcher(
            mapOf(
                RootTransportLane.PRIVILEGED to BoundedRootCommandExecutor(
                    sessionFactory = RootCommandSessionFactory { privilegedSession },
                    queueTimeoutMillis = 20,
                    closeDrainTimeoutMillis = 20,
                ),
                RootTransportLane.OBSERVATION to BoundedRootCommandExecutor(
                    sessionFactory = RootCommandSessionFactory { observationSession },
                    queueTimeoutMillis = 20,
                    closeDrainTimeoutMillis = 20,
                ),
            ),
        )
        val holderPool = Executors.newSingleThreadExecutor()
        val privileged = holderPool.submit<RootCommandResult> {
            dispatcher.execute("long transaction", RootCommandPolicy.MUTATION)
        }
        assertTrue(privilegedEntered.await(1, TimeUnit.SECONDS))

        val observed = dispatcher.execute("screen read", RootCommandPolicy.OBSERVATION)

        assertTrue(observed.isSuccess)
        assertEquals(listOf("observed"), observed.out)

        privilegedRelease.countDown()
        assertTrue(privileged.get(1, TimeUnit.SECONDS).isSuccess)
        holderPool.shutdownNow()
    }

    @Test
    fun policiesRouteToTheirLaneTransports() {
        val privilegedSession = CountingSession(RootCommandResult(code = 0))
        val observationSession = CountingSession(RootCommandResult(code = 0))
        val dispatcher = RootCommandDispatcher(
            mapOf(
                RootTransportLane.PRIVILEGED to BoundedRootCommandExecutor(
                    sessionFactory = RootCommandSessionFactory { privilegedSession },
                    queueTimeoutMillis = 20,
                    closeDrainTimeoutMillis = 20,
                ),
                RootTransportLane.OBSERVATION to BoundedRootCommandExecutor(
                    sessionFactory = RootCommandSessionFactory { observationSession },
                    queueTimeoutMillis = 20,
                    closeDrainTimeoutMillis = 20,
                ),
            ),
        )

        dispatcher.execute("read", RootCommandPolicy.OBSERVATION)
        dispatcher.execute("write", RootCommandPolicy.MUTATION)
        dispatcher.execute("start", RootCommandPolicy.LIFECYCLE)
        dispatcher.execute("install", RootCommandPolicy.PACKAGE_INSTALL)

        assertEquals(1, observationSession.submissions.get())
        assertEquals(3, privilegedSession.submissions.get())
    }

    @Test
    fun dispatcherRefusesAnIncompleteLaneMap() {
        assertThrows(IllegalArgumentException::class.java) {
            RootCommandDispatcher(
                mapOf(
                    RootTransportLane.PRIVILEGED to BoundedRootCommandExecutor(
                        sessionFactory = RootCommandSessionFactory {
                            CountingSession(RootCommandResult(code = 0))
                        },
                    ),
                ),
            )
        }
    }

    @Test
    fun everyPolicyTransportBudgetOutlivesItsInShellTimeout() {
        RootCommandPolicy.entries.forEach { policy ->
            assertTrue(
                "${policy.name} transport budget must cover its in-shell timeout",
                policy.budget.transportTimeoutMillis > policy.budget.commandTimeoutSeconds * 1_000,
            )
        }
    }

    private class CountingSession(private val result: RootCommandResult) : RootCommandSession {
        val submissions = AtomicInteger()

        override fun submit(command: String): Future<RootCommandResult> {
            submissions.incrementAndGet()
            return CompletableFuture.completedFuture(result)
        }

        override fun close() = Unit
    }
}

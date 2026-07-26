package com.zapret2.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class LifecycleMutationLockProtocolTest {

    private val pid = 7331
    private val token = "app.0123456789abcdef"
    private val boot = "01234567-89ab-4def-8abc-0123456789ab"

    private val leaseScript = "sh '${RootModuleContract.SCRIPTS_DIR}/lifecycle-lease.sh'"

    /**
     * The ceremony itself lives in the packaged entry script so the module's
     * interpreter shim applies to it; these commands only select a mode and
     * bind the caller's exact identity as positional arguments.
     */
    @Test
    fun commandsInvokeThePackagedLeaseScriptWithExactIdentity() {
        assertEquals(
            "$leaseScript acquire '$pid' '$token'",
            LifecycleMutationLockProtocol.buildAcquireCommand(pid, token),
        )
        assertEquals(
            "$leaseScript probe '$pid' '$token'",
            LifecycleMutationLockProtocol.buildOwnedLeaseProbeCommand(pid, token),
        )
        val lease = LifecycleMutationLockProtocol.Lease(pid.toString(), "987654321", boot, token)
        assertEquals(
            "$leaseScript release '$pid' '987654321' '$boot' '$token' 'release0123456789'",
            LifecycleMutationLockProtocol.buildReleaseCommand(lease, "release0123456789"),
        )
    }

    /**
     * The protocol invariants formerly pinned on the inline command text are
     * pinned on the packaged script: shared gate, exact-owner-only reaping,
     * boot binding, read-only probe, and no recursive removal anywhere.
     */
    @Test
    fun packagedLeaseScriptKeepsTheOwnershipInvariants() {
        val script = File("../../zapret2/scripts/lifecycle-lease.sh")
        assertTrue("Missing packaged lease script: ${script.absolutePath}", script.isFile)
        val text = script.readText()

        assertTrue(text.contains("claim_lifecycle_gate"))
        assertTrue(text.contains("Z2_LEASE_KIND=android-mutation"))
        assertTrue(text.contains("z2_owner_state=ambiguous"))
        assertTrue(text.contains("[ \"\$z2_owner_state\" = stale ]"))
        assertTrue(text.contains("sleep 1"))
        assertTrue(text.contains("foreign, malformed, or unknown lifecycle owner was preserved"))
        assertTrue(text.contains("entries=\$(find \"\$LIFECYCLE_LOCK\" -mindepth 1 -maxdepth 1"))
        assertTrue(text.contains("[ \"\$pid\" = \"\$expected_pid\" ]"))
        assertTrue(text.contains("[ \"\$start\" = \"\$expected_start\" ]"))
        assertTrue(text.contains("[ \"\$boot\" = \"\$expected_boot\" ]"))
        assertTrue(text.contains("[ \"\$token\" = \"\$expected_token\" ]"))
        assertTrue(text.contains("rm -f \"\$quarantine/owner\""))
        assertTrue(text.contains("rmdir \"\$quarantine\""))
        assertTrue(text.contains("[ \"\$current_boot\" = \"\$boot\" ]"))
        assertTrue(text.contains("[ \"\$after\" = \"\$before\" ]"))
        assertTrue(text.contains("Z2_MUTATION_LOCK_ABSENT=1"))
        assertFalse(text.contains("rm -rf"))

        // The lease script is a packaged executable, so the shim can re-exec it.
        val manifest = File("../../zapret2/runtime-manifest.tsv").readText()
        assertTrue(manifest.contains("immutable-exec|0755|zapret2/scripts/lifecycle-lease.sh"))
    }

    @Test
    fun acquireProtocol_isExactUniqueAndBoundToRequestedOwner() {
        val valid = listOf(
            "Z2_MUTATION_LOCK_PID=$pid",
            "Z2_MUTATION_LOCK_START=987654321",
            "Z2_MUTATION_LOCK_BOOT=$boot",
            "Z2_MUTATION_LOCK_TOKEN=$token",
            "Z2_MUTATION_LOCK_COMPLETE=1",
        )
        val lease = LifecycleMutationLockProtocol.parseAcquireOutput(valid, pid, token)
        assertNotNull(lease)
        assertEquals("987654321", lease?.starttime)

        assertNull(LifecycleMutationLockProtocol.parseAcquireOutput(valid.dropLast(1), pid, token))
        assertNull(LifecycleMutationLockProtocol.parseAcquireOutput(valid + valid.last(), pid, token))
        assertNull(LifecycleMutationLockProtocol.parseAcquireOutput(valid.map {
            if (it.startsWith("Z2_MUTATION_LOCK_TOKEN=")) "Z2_MUTATION_LOCK_TOKEN=foreign" else it
        }, pid, token))
        assertNull(LifecycleMutationLockProtocol.parseAcquireOutput(valid.map {
            if (it.startsWith("Z2_MUTATION_LOCK_BOOT=")) "Z2_MUTATION_LOCK_BOOT=UNKNOWN" else it
        }, pid, token))
    }

    @Test
    fun releaseAndProbeOutputsAreExact() {
        assertTrue(LifecycleMutationLockProtocol.parseReleaseOutput(listOf("Z2_MUTATION_LOCK_RELEASED=1")))
        assertFalse(LifecycleMutationLockProtocol.parseReleaseOutput(listOf("noise", "Z2_MUTATION_LOCK_RELEASED=1")))
        assertTrue(
            LifecycleMutationLockProtocol.isOwnedLeaseAbsentOutput(
                listOf("Z2_MUTATION_LOCK_ABSENT=1"),
            ),
        )
        assertFalse(
            LifecycleMutationLockProtocol.isOwnedLeaseAbsentOutput(
                listOf("noise", "Z2_MUTATION_LOCK_ABSENT=1"),
            ),
        )
    }

    @Test
    fun invalidMetadataNeverBuildsMutationCommands() {
        assertNull(LifecycleMutationLockProtocol.buildAcquireCommand(0, token))
        assertNull(LifecycleMutationLockProtocol.buildAcquireCommand(pid, "bad token"))
        assertNull(LifecycleMutationLockProtocol.buildReleaseCommand(
            LifecycleMutationLockProtocol.Lease(pid.toString(), "01", boot, token),
            "release",
        ))
    }
}

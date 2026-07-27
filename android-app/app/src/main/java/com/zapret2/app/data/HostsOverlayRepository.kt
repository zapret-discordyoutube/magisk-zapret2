package com.zapret2.app.data

import kotlinx.coroutines.CancellationException
import javax.inject.Inject

internal sealed interface HostsOverlaySnapshot {
    data class Present(val content: String) : HostsOverlaySnapshot
    data object Missing : HostsOverlaySnapshot
    data object Unsafe : HostsOverlaySnapshot
}

internal sealed interface HostsOverlayMutationOutcome {
    data class Applied(val effectiveContent: String) : HostsOverlayMutationOutcome
    data object SourceChanged : HostsOverlayMutationOutcome
    data object Failed : HostsOverlayMutationOutcome
}

/** What the module reported after it was asked to publish the written file. */
internal sealed interface HostsPublicationOutcome {
    /** The file is bind-mounted over /system/etc/hosts and is in effect now. */
    data object Mounted : HostsPublicationOutcome

    /** Another enabled module owns /system/etc/hosts; the selection was saved but is not live. */
    data class Conflict(val moduleId: String) : HostsPublicationOutcome

    /** The installed module predates hosts publication and cannot mount anything. */
    data object ModuleTooOld : HostsPublicationOutcome

    /** Written and durable, but the module could not put it in effect without a reboot. */
    data object PendingReboot : HostsPublicationOutcome
}

/**
 * Owns the systemless hosts publication and its exact rollback snapshot.
 *
 * The published file lives in /data and the module bind-mounts it over /system/etc/hosts. The
 * app deliberately does not write into the live module tree: a root manager assembles /system
 * from module directories while it builds its mount, so a file added afterwards is inert until
 * the next boot, a module upgrade discards it, and a second hosts module publishing the same
 * path turns into a silent race. Going through the module's own mount also means an edit takes
 * effect immediately instead of at the next boot.
 */
class HostsOverlayRepository @Inject constructor() {

    internal fun readEffective(): String? = readEffective(snapshotOverlay())

    internal fun readEffective(overlay: HostsOverlaySnapshot): String? = when (overlay) {
        is HostsOverlaySnapshot.Present -> overlay.content
        // The base is the system file as it was before this module covered it, captured at boot
        // while the real file was still visible. Without it — a module that has not booted since
        // the upgrade — /system/etc/hosts is still the untouched original.
        HostsOverlaySnapshot.Missing ->
            (
                RootFileIo.readSecureRegularText(BASE_HOSTS, MAX_HOSTS_BYTES)
                    ?: RootFileIo.readSecureRegularText(SYSTEM_HOSTS, MAX_HOSTS_BYTES)
                )?.takeIf(::isContentSizeAllowed)
        HostsOverlaySnapshot.Unsafe -> null
    }

    /**
     * Asks the module to put the written file in effect.
     *
     * Publication is an atomic rename, which leaves any existing bind mount pointing at the
     * replaced inode, so the mount has to be republished for the edit to be live.
     */
    internal fun publish(): HostsPublicationOutcome = runOverlayScript("--apply")

    /** Releases the mount and removes the published file. */
    internal fun clearPublication(): HostsPublicationOutcome = runOverlayScript("--clear")

    private fun runOverlayScript(mode: String): HostsPublicationOutcome {
        ModuleMutationCoordinator.requirePrivilegedMutationContext()
        val script = RootFileIo.shellQuote(OVERLAY_SCRIPT)
        val command = "[ -f $script ] && [ ! -L $script ] || exit 3\n" +
            "/system/bin/sh $script $mode"
        val result = RootCommandExecutor.execute(command, RootCommandPolicy.MUTATION)
        if (result.code == MODULE_TOO_OLD_EXIT) return HostsPublicationOutcome.ModuleTooOld
        val fields = result.out
            .mapNotNull { line ->
                val separator = line.indexOf('\t')
                if (separator <= 0) null else line.substring(0, separator) to line.substring(separator + 1)
            }
            .toMap()
        if (fields["Z2_HOSTS_SCHEMA"] != HOSTS_MACHINE_SCHEMA) return HostsPublicationOutcome.PendingReboot
        return when (fields["Z2_HOSTS_STATE"]) {
            "mounted" -> HostsPublicationOutcome.Mounted
            "absent" -> if (mode == "--clear") {
                HostsPublicationOutcome.Mounted
            } else {
                HostsPublicationOutcome.PendingReboot
            }
            "conflict" -> HostsPublicationOutcome.Conflict(
                fields["Z2_HOSTS_CONFLICT"]?.takeIf { it.isNotBlank() && it != "none" }
                    ?.let(::sanitizedConflictName)
                    ?: UNKNOWN_CONFLICT,
            )
            else -> HostsPublicationOutcome.PendingReboot
        }
    }

    /** A module id reaches the UI, so it is bounded and stripped of anything unprintable. */
    private fun sanitizedConflictName(value: String): String = value
        .filter { it.code in 0x21..0x7E }
        .take(MAX_CONFLICT_NAME_LENGTH)
        .ifEmpty { UNKNOWN_CONFLICT }

    internal fun snapshotOverlay(): HostsOverlaySnapshot {
        val quoted = RootFileIo.shellQuote(OVERLAY_HOSTS)
        val probe = RootCommandExecutor.execute(
            "if [ ! -e $quoted ] && [ ! -L $quoted ]; then echo MISSING; else echo PRESENT; fi",
        )
        return when (probe.out.singleOrNull().takeIf { probe.isSuccess }) {
            "MISSING" -> HostsOverlaySnapshot.Missing
            "PRESENT" -> RootFileIo.readSecureRegularText(OVERLAY_HOSTS, MAX_HOSTS_BYTES)
                ?.takeIf(::isContentSizeAllowed)
                ?.let(HostsOverlaySnapshot::Present) ?: HostsOverlaySnapshot.Unsafe
            else -> HostsOverlaySnapshot.Unsafe
        }
    }

    internal fun writeIfUnchanged(
        expectedOverlay: HostsOverlaySnapshot,
        expectedEffectiveContent: String,
        content: String,
        delimiterPrefix: String = "__ZAPRET_HOSTS_EOF__",
    ): HostsOverlayMutationOutcome {
        val liveOverlay = snapshotOverlay()
        if (liveOverlay == HostsOverlaySnapshot.Unsafe) return HostsOverlayMutationOutcome.Failed
        if (liveOverlay != expectedOverlay) return HostsOverlayMutationOutcome.SourceChanged
        val liveEffective = readEffective(liveOverlay) ?: return HostsOverlayMutationOutcome.Failed
        if (liveEffective != expectedEffectiveContent) return HostsOverlayMutationOutcome.SourceChanged
        val written = try {
            write(content, delimiterPrefix)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            false
        }
        if (!written) return HostsOverlayMutationOutcome.Failed
        val persisted = try {
            snapshotOverlay()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            HostsOverlaySnapshot.Unsafe
        }
        return if (persisted is HostsOverlaySnapshot.Present &&
            canonicalProtectedText(persisted.content) == canonicalProtectedText(content)
        ) {
            HostsOverlayMutationOutcome.Applied(persisted.content)
        } else {
            HostsOverlayMutationOutcome.Failed
        }
    }

    internal fun removeIfUnchanged(
        expectedOverlay: HostsOverlaySnapshot,
        expectedEffectiveContent: String,
    ): HostsOverlayMutationOutcome {
        val liveOverlay = snapshotOverlay()
        if (liveOverlay == HostsOverlaySnapshot.Unsafe) return HostsOverlayMutationOutcome.Failed
        if (liveOverlay != expectedOverlay) return HostsOverlayMutationOutcome.SourceChanged
        val liveEffective = readEffective(liveOverlay) ?: return HostsOverlayMutationOutcome.Failed
        if (liveEffective != expectedEffectiveContent) return HostsOverlayMutationOutcome.SourceChanged
        val removed = try {
            remove()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            false
        }
        if (!removed) return HostsOverlayMutationOutcome.Failed
        val overlayAfterRemove = try {
            snapshotOverlay()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            HostsOverlaySnapshot.Unsafe
        }
        if (overlayAfterRemove != HostsOverlaySnapshot.Missing) return HostsOverlayMutationOutcome.Failed
        val effectiveAfterRemove = try {
            readEffective(overlayAfterRemove)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        } ?: return HostsOverlayMutationOutcome.Failed
        return HostsOverlayMutationOutcome.Applied(effectiveAfterRemove)
    }

    private fun write(content: String, delimiterPrefix: String): Boolean {
        val normalized = normalizedForWrite(content)
        if (!isContentSizeAllowed(normalized) || !isValidContent(normalized)) return false
        return writeNormalized(normalized, delimiterPrefix)
    }

    private fun writeNormalized(content: String, delimiterPrefix: String): Boolean {
        return RootFileIo.ensureDirectory(OVERLAY_HOSTS.substringBeforeLast('/')) &&
            RootFileIo.writeTextAtomically(OVERLAY_HOSTS, content, delimiterPrefix, fileMode = "0644")
    }

    private fun remove(): Boolean = RootFileIo.removeFile(OVERLAY_HOSTS)

    internal fun isContentSizeAllowed(content: String): Boolean =
        normalizedForWrite(content).toByteArray(Charsets.UTF_8).size <= MAX_HOSTS_BYTES

    internal fun isValidContent(content: String): Boolean = HostsFileSyntax.isValidFile(content)

    private fun normalizedForWrite(content: String): String = canonicalProtectedText(content) + "\n"

    internal fun restore(snapshot: HostsOverlaySnapshot): Boolean = when (snapshot) {
        is HostsOverlaySnapshot.Present -> {
            val normalized = normalizedForWrite(snapshot.content)
            isContentSizeAllowed(normalized) &&
                writeNormalized(normalized, "__ZAPRET_HOSTS_ROLLBACK_EOF__")
        }
        HostsOverlaySnapshot.Missing -> remove()
        HostsOverlaySnapshot.Unsafe -> false
    }

    internal companion object {
        const val SYSTEM_HOSTS = "/system/etc/hosts"
        const val OVERLAY_DIR = "${RootModuleContract.MODULE_STORAGE_DIR}/zapret2-hosts"
        const val OVERLAY_HOSTS = "$OVERLAY_DIR/hosts"
        const val BASE_HOSTS = "$OVERLAY_DIR/system-hosts.base"
        const val OVERLAY_SCRIPT =
            "${RootModuleContract.ACTIVE_MODULE_DIR}/${ModulePackageContract.HOSTS_OVERLAY_SCRIPT_PATH}"
        const val MAX_HOSTS_BYTES = 1024 * 1024
        private const val HOSTS_MACHINE_SCHEMA = "1"
        private const val MODULE_TOO_OLD_EXIT = 3
        private const val MAX_CONFLICT_NAME_LENGTH = 64
        private const val UNKNOWN_CONFLICT = "unknown"
    }
}

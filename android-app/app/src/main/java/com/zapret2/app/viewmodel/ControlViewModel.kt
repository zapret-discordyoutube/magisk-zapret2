package com.zapret2.app.viewmodel

import android.content.SharedPreferences
import androidx.annotation.StringRes
import androidx.core.content.edit
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.zapret2.app.R
import com.zapret2.app.data.ArtifactValidationReason
import com.zapret2.app.data.DownloadFailureReason
import com.zapret2.app.data.LifecycleErrorContract
import com.zapret2.app.data.ModuleInstallState
import com.zapret2.app.data.ModuleEnvironmentSnapshot
import com.zapret2.app.data.ModuleMutationState
import com.zapret2.app.data.ModuleMutationCoordinator
import com.zapret2.app.data.ModulePurgeAppDataCleaner
import com.zapret2.app.data.ModulePurgeController
import com.zapret2.app.data.ModuleServiceAccess
import com.zapret2.app.data.NetworkStatsManager
import com.zapret2.app.data.PendingModuleState
import com.zapret2.app.data.ProtectedTextRead
import com.zapret2.app.data.RuntimeConfigReadResult
import com.zapret2.app.data.RuntimeConfigMutationResult
import com.zapret2.app.data.RuntimeConfigStore
import com.zapret2.app.data.diagnosticText
import com.zapret2.app.data.diagnosticTextOrNull
import com.zapret2.app.data.projectModuleVersionCode
import com.zapret2.app.data.RuntimeLogRepository
import com.zapret2.app.data.ServiceEventBus
import com.zapret2.app.data.ServiceEventSource
import com.zapret2.app.data.ServiceLifecycleController
import com.zapret2.app.data.ServiceUptimeAnchor
import com.zapret2.app.data.serviceUptimeAnchor
import com.zapret2.app.data.UpdateFailure
import com.zapret2.app.data.UpdateManager
import com.zapret2.app.data.UpdateProgress
import com.zapret2.app.data.UpdateStage
import com.zapret2.app.data.UpdateTerminalOutcome
import com.zapret2.app.data.Zapret2ModuleRepository
import com.zapret2.app.data.toTerminalOutcome
import com.zapret2.app.ui.UiText
import com.zapret2.app.ui.labelRes
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject

enum class ControlStatus(@param:StringRes val labelRes: Int) {
    CHECKING(R.string.control_service_checking),
    LIFECYCLE_BUSY(R.string.control_service_lifecycle_busy),
    RUNNING(R.string.control_service_running),
    STOPPED(R.string.control_service_stopped),
    DEGRADED(R.string.control_status_degraded),
    ROOT_DENIED(R.string.control_status_root_denied),
    ROOT_MANAGER_UNAVAILABLE(R.string.control_status_root_manager_unavailable),
    ROOT_SHELL_FAILED(R.string.control_status_root_shell_failed),
    ROOT_TIMEOUT(R.string.control_status_root_timeout),
    ROOT_OPERATION_BUSY(R.string.control_status_root_operation_busy),
    NOT_INSTALLED(R.string.control_status_not_installed),
    REBOOT_REQUIRED(R.string.control_status_reboot_required),
    MODULE_NOT_READY(R.string.control_status_module_not_ready),
    UNAVAILABLE(R.string.control_status_unavailable),
}

internal fun confirmedRunning(
    serviceStatus: ServiceLifecycleController.ServiceStatus,
): Boolean = serviceStatus.healthy

internal fun projectedControlStatus(
    serviceStatus: ServiceLifecycleController.ServiceStatus,
    canStopService: Boolean,
): ControlStatus = when {
    !serviceStatus.rootGranted -> serviceStatus.rootAccessState.toControlStatus()
    serviceStatus.lifecycleState == ServiceLifecycleController.LifecycleState.OWNED ->
        ControlStatus.LIFECYCLE_BUSY
    serviceStatus.lifecycleState == ServiceLifecycleController.LifecycleState.ACTIVE ->
        ControlStatus.LIFECYCLE_BUSY
    serviceStatus.lifecycleState in setOf(
        ServiceLifecycleController.LifecycleState.AMBIGUOUS,
        ServiceLifecycleController.LifecycleState.RECOVERY_FAILED,
    ) -> ControlStatus.UNAVAILABLE
    serviceStatus.error != null -> ControlStatus.UNAVAILABLE
    confirmedRunning(serviceStatus) -> ControlStatus.RUNNING
    canStopService -> ControlStatus.DEGRADED
    else -> ControlStatus.STOPPED
}

internal fun ServiceLifecycleController.RootAccessState.toControlStatus(): ControlStatus = when (this) {
    ServiceLifecycleController.RootAccessState.GRANTED -> ControlStatus.UNAVAILABLE
    ServiceLifecycleController.RootAccessState.DENIED -> ControlStatus.ROOT_DENIED
    ServiceLifecycleController.RootAccessState.MANAGER_UNAVAILABLE ->
        ControlStatus.ROOT_MANAGER_UNAVAILABLE
    ServiceLifecycleController.RootAccessState.SHELL_FAILURE -> ControlStatus.ROOT_SHELL_FAILED
    ServiceLifecycleController.RootAccessState.TIMEOUT -> ControlStatus.ROOT_TIMEOUT
    ServiceLifecycleController.RootAccessState.BUSY -> ControlStatus.ROOT_OPERATION_BUSY
}

internal val ModuleInstallState.labelRes: Int
    @StringRes get() = when (this) {
        ModuleInstallState.UNKNOWN -> R.string.control_module_state_unknown
        ModuleInstallState.MISSING -> R.string.control_module_state_missing
        ModuleInstallState.READY -> R.string.control_module_state_ready
        ModuleInstallState.DISABLED -> R.string.control_module_state_disabled
        ModuleInstallState.REMOVAL_PENDING -> R.string.control_module_state_removal_pending
        ModuleInstallState.PARTIAL -> R.string.control_module_state_partial
        ModuleInstallState.UNSUPPORTED_ABI -> R.string.control_module_state_unsupported_abi
        ModuleInstallState.UNREADABLE -> R.string.control_module_state_unreadable
    }

/**
 * What the environment card prints for the module row.
 *
 * [ControlUiState.moduleRemovalPending] outranks every installation fact below it because it is
 * the only one that describes the *next* boot: the module directory carries a removal mark, or the
 * uninstall tombstone is up, and either way the root manager deletes the module. A `READY` label
 * over that state is not merely incomplete, it is the opposite of what happens next, and the
 * module refuses every write the label implies is available. It ranks below the two mutation
 * states only because those describe a transaction running *right now*, which the user has to wait
 * out before the removal matters at all.
 */
@get:StringRes
internal val ControlUiState.moduleStateLabelRes: Int
    get() = when {
        moduleMutationState == ModuleMutationState.IN_PROGRESS ->
            R.string.control_service_lifecycle_busy
        moduleMutationState == ModuleMutationState.BLOCKED ->
            R.string.control_module_state_lifecycle_blocked
        moduleRemovalPending -> R.string.control_module_state_removal_pending
        pendingModuleState == PendingModuleState.READY &&
            moduleInstallState == ModuleInstallState.MISSING ->
            R.string.control_module_state_installed_reboot
        pendingModuleState == PendingModuleState.READY ->
            R.string.control_module_state_update_reboot
        pendingModuleState == PendingModuleState.PARTIAL ->
            R.string.control_module_state_pending_partial
        pendingModuleState == PendingModuleState.UNSUPPORTED_ABI ->
            R.string.control_module_state_pending_unsupported_abi
        pendingModuleState == PendingModuleState.UNREADABLE ->
            R.string.control_module_state_pending_unreadable
        else -> moduleInstallState.labelRes
    }

internal fun ModuleServiceAccess.statusWithoutQuery(): ControlStatus? = when (this) {
    ModuleServiceAccess.QUERY_ACTIVE -> null
    ModuleServiceAccess.NOT_INSTALLED -> ControlStatus.NOT_INSTALLED
    ModuleServiceAccess.REBOOT_REQUIRED -> ControlStatus.REBOOT_REQUIRED
    ModuleServiceAccess.NOT_READY -> ControlStatus.MODULE_NOT_READY
    ModuleServiceAccess.UNKNOWN -> ControlStatus.UNAVAILABLE
}

internal fun ServiceLifecycleController.LifecycleState.toModuleMutationState(): ModuleMutationState =
    when (this) {
        ServiceLifecycleController.LifecycleState.OWNED,
        ServiceLifecycleController.LifecycleState.ACTIVE,
        -> ModuleMutationState.IN_PROGRESS
        ServiceLifecycleController.LifecycleState.AMBIGUOUS,
        ServiceLifecycleController.LifecycleState.RECOVERY_FAILED,
        -> ModuleMutationState.BLOCKED
        ServiceLifecycleController.LifecycleState.IDLE,
        ServiceLifecycleController.LifecycleState.RECOVERED,
        ServiceLifecycleController.LifecycleState.UNKNOWN,
        -> ModuleMutationState.IDLE
    }

internal fun projectedLifecycleDiagnostic(
    serviceStatus: ServiceLifecycleController.ServiceStatus,
): String? = serviceStatus.lifecycleError
    ?.takeUnless { error ->
        error.isNone ||
            serviceStatus.lifecycleState in setOf(
                ServiceLifecycleController.LifecycleState.OWNED,
                ServiceLifecycleController.LifecycleState.ACTIVE,
            )
    }
    ?.diagnosticText()

enum class ControlDialogKind {
    UPDATE,
    ERROR,
    FULL_ROLLBACK_CONFIRM,
    FULL_ROLLBACK_RESULT,
    MODULE_PURGE_CONFIRM,
    MODULE_PURGE_RESULT,
}

enum class ControlErrorKind(@param:StringRes val titleRes: Int) {
    INITIALIZATION(R.string.control_initialization_failed),
    START_SERVICE(R.string.control_service_start_failed),
    STOP_SERVICE(R.string.control_service_stop_failed),
    SERVICE_OPERATION(R.string.control_service_operation_failed),
    UPDATE(R.string.control_update_failed),
}

enum class ControlLastResult(@param:StringRes val messageRes: Int) {
    SERVICE_STARTED(R.string.control_service_started),
    SERVICE_STOPPED(R.string.control_service_stopped_result),
    SERVICE_STOPPED_IPV6_UNVERIFIED(R.string.control_service_stopped_ipv6_unverified),
    SERVICE_FAILED(R.string.control_service_operation_failed),
    ROLLBACK_COMPLETED(R.string.control_full_rollback_success_title),
    ROLLBACK_FAILED(R.string.control_full_rollback_failure_title),
    PURGE_COMPLETED(R.string.control_purge_success_title),
    PURGE_FAILED(R.string.control_purge_failure_title),
    UPDATE_COMPLETED(R.string.control_update_completed),
    UPDATE_REBOOT_REQUIRED(R.string.control_update_installed_reboot),
    UPDATE_APK_PENDING(R.string.control_update_apk_pending),
    UPDATE_APK_PENDING_REBOOT(R.string.control_update_apk_pending_reboot),
    UPDATE_PARTIAL(R.string.control_update_partial),
    UPDATE_PARTIAL_REBOOT(R.string.control_update_partial_reboot),
    UPDATE_FAILED(R.string.control_update_failed),
}

/**
 * The verdict a stop that the module reported as complete publishes to the screen.
 *
 * A teardown removes both families and counts zero rules in both, but it can only certify the
 * families it could read back. On a device whose IPv6 mangle table is unreadable the module
 * withholds that certification alone ([ServiceLifecycleController.ServiceStatus.rulesetVerified]
 * is false) while every measurable fact is still zero. The stop happened, so it is reported as
 * done; the one check that could not be repeated is named beside it rather than replacing it,
 * and the reboot the rules would not survive is what clears them.
 */
internal fun stoppedServiceResult(rulesetVerified: Boolean): ControlLastResult =
    if (rulesetVerified) {
        ControlLastResult.SERVICE_STOPPED
    } else {
        ControlLastResult.SERVICE_STOPPED_IPV6_UNVERIFIED
    }

internal fun UpdateProgress.toUiText(): UiText = when (stage) {
    UpdateStage.DOWNLOADING_MODULE -> normalizedPercent?.let {
        UiText.resource(R.string.update_stage_downloading_module_percent, it)
    } ?: UiText.Resource(R.string.update_stage_downloading_module)
    UpdateStage.INSTALLING_MODULE -> UiText.Resource(R.string.update_stage_installing_module)
    UpdateStage.MODULE_INSTALLED -> UiText.Resource(R.string.update_stage_module_installed)
    UpdateStage.DOWNLOADING_APK -> normalizedPercent?.let {
        UiText.resource(R.string.update_stage_downloading_apk_percent, it)
    } ?: UiText.Resource(R.string.update_stage_downloading_apk)
    UpdateStage.VALIDATING_ARTIFACTS -> UiText.Resource(R.string.update_stage_validating_artifacts)
    UpdateStage.OPENING_APK_INSTALLER -> UiText.Resource(R.string.update_stage_opening_apk_installer)
    UpdateStage.APK_INSTALLER_PENDING -> UiText.Resource(R.string.update_stage_apk_installer_pending)
    UpdateStage.COMPLETE -> UiText.Resource(R.string.update_stage_complete)
}

internal fun UpdateManager.UpdateCheckFailure.toUiText(): UiText = when (this) {
    UpdateManager.UpdateCheckFailure.NoInternet ->
        UiText.Resource(R.string.control_update_check_no_internet)
    UpdateManager.UpdateCheckFailure.ConnectionTimeout ->
        UiText.Resource(R.string.control_update_check_timeout)
    UpdateManager.UpdateCheckFailure.SecureConnectionFailed ->
        UiText.Resource(R.string.control_update_check_secure_connection_failed)
    is UpdateManager.UpdateCheckFailure.ServerResponse ->
        UiText.resource(R.string.control_update_check_http_failed, statusCode)
    UpdateManager.UpdateCheckFailure.MetadataTooLarge ->
        UiText.Resource(R.string.control_update_check_metadata_too_large)
    UpdateManager.UpdateCheckFailure.EmptyResponse ->
        UiText.Resource(R.string.control_update_check_empty_response)
    UpdateManager.UpdateCheckFailure.InvalidMetadata ->
        UiText.Resource(R.string.control_update_check_invalid_metadata)
    UpdateManager.UpdateCheckFailure.RequestFailed ->
        UiText.Resource(R.string.control_update_check_failed)
}

internal fun UpdateFailure.toUiText(): UiText = when (this) {
    is UpdateFailure.Download -> reason.toUiText()
    is UpdateFailure.Validation -> reason.toUiText()
    UpdateFailure.UnsupportedAbi -> UiText.Resource(R.string.control_update_unsupported_abi)
    UpdateFailure.ApkInstallerUnavailable ->
        UiText.Resource(R.string.control_update_apk_installer_unavailable)
    UpdateFailure.ModuleRejected -> UiText.Resource(R.string.control_update_module_rejected)
    UpdateFailure.ModuleInstallationFailed ->
        UiText.Resource(R.string.control_update_module_install_failed)
}

private fun ArtifactValidationReason.toUiText(): UiText = UiText.Resource(
    when (this) {
        ArtifactValidationReason.APK_FILE_INVALID -> R.string.control_update_apk_file_invalid
        ArtifactValidationReason.APK_UNREADABLE -> R.string.control_update_apk_unreadable
        ArtifactValidationReason.APK_PACKAGE_ID_MISMATCH ->
            R.string.control_update_apk_package_mismatch
        ArtifactValidationReason.APK_NOT_NEWER -> R.string.control_update_apk_not_newer
        ArtifactValidationReason.APK_VERSION_CODE_MISMATCH ->
            R.string.control_update_apk_version_code_mismatch
        ArtifactValidationReason.APK_VERSION_MISMATCH ->
            R.string.control_update_apk_version_mismatch
        ArtifactValidationReason.INSTALLED_APK_SIGNER_UNAVAILABLE ->
            R.string.control_update_installed_signer_unavailable
        ArtifactValidationReason.APK_SIGNER_UNAVAILABLE ->
            R.string.control_update_apk_signer_unavailable
        ArtifactValidationReason.APK_SIGNER_MISMATCH ->
            R.string.control_update_apk_signer_mismatch
        ArtifactValidationReason.APK_VALIDATION_FAILED ->
            R.string.control_update_apk_validation_failed
        ArtifactValidationReason.MODULE_TOO_MANY_ENTRIES ->
            R.string.control_update_module_too_many_entries
        ArtifactValidationReason.MODULE_UNSAFE_OR_DUPLICATE_PATH ->
            R.string.control_update_module_unsafe_path
        ArtifactValidationReason.MODULE_ENTRY_TOO_LARGE ->
            R.string.control_update_module_entry_too_large
        ArtifactValidationReason.MODULE_EXPANDED_SIZE_TOO_LARGE ->
            R.string.control_update_module_expanded_too_large
        ArtifactValidationReason.MODULE_EMPTY -> R.string.control_update_module_empty
        ArtifactValidationReason.MODULE_IDENTITY_MISSING ->
            R.string.control_update_module_identity_missing
        ArtifactValidationReason.MODULE_PACKAGE_INVALID ->
            R.string.control_update_module_package_invalid
        ArtifactValidationReason.MODULE_VALIDATION_FAILED ->
            R.string.control_update_module_validation_failed
    },
)

private fun DownloadFailureReason.toUiText(): UiText = UiText.Resource(
    when (this) {
        DownloadFailureReason.SECURITY_POLICY_REJECTED ->
            R.string.control_update_download_security_rejected
        DownloadFailureReason.SERVER_REJECTED -> R.string.control_update_download_server_rejected
        DownloadFailureReason.TOO_MANY_REDIRECTS -> R.string.control_update_download_redirects
        DownloadFailureReason.TOO_LARGE -> R.string.control_update_download_too_large
        DownloadFailureReason.STORAGE_UNAVAILABLE -> R.string.control_update_download_storage
        DownloadFailureReason.CHECKSUM_MISMATCH -> R.string.control_update_download_checksum
        DownloadFailureReason.NO_INTERNET -> R.string.control_update_download_no_internet
        DownloadFailureReason.CONNECTION_TIMEOUT -> R.string.control_update_download_timeout
        DownloadFailureReason.SECURE_CONNECTION_FAILED ->
            R.string.control_update_download_secure_connection_failed
        DownloadFailureReason.FAILED -> R.string.control_update_download_failed
    },
)

private fun String.toSafeUpdateDiagnosticOrNull(): String? = sanitizedBoundedUiDiagnostic(this)
    .takeIf(String::isNotBlank)

data class ControlErrorDialog(
    val kind: ControlErrorKind,
    val details: UiText,
)

sealed interface FullRollbackUiState {
    data object Idle : FullRollbackUiState
    data object Confirmation : FullRollbackUiState
    data object InProgress : FullRollbackUiState
    data class Result(
        val outcome: ServiceLifecycleController.FullRollbackOutcome,
        val rolledBack: Boolean,
        val rebootRequired: Boolean,
        val diagnostic: String,
    ) : FullRollbackUiState {
        /** Rolled back, with one cleanup step the module could not verify and the reboot clears. */
        val unverifiedCleanup: Boolean
            get() = rolledBack &&
                outcome != ServiceLifecycleController.FullRollbackOutcome.COMPLETE

        /**
         * Whether the dialog shows what the module and the transport actually said.
         *
         * A rolled-back result is not a silent one. The receipt behind it can report that it
         * could not write its status receipt — which means the screen keeps reading an older
         * generation until the required reboot — and the transport can report a command it had to
         * cut short. [unverifiedCleanup] names one reservation, the withheld IPv6 assertion, and
         * one only; it is a heading for this text, never a substitute for it. Only a result that
         * both succeeded and returned nothing has nothing to say, because the failing path still
         * owes the user the "no diagnostic was returned" statement.
         */
        val showsDiagnostic: Boolean get() = diagnostic.isNotBlank() || !rolledBack
    }
}

sealed interface ModulePurgeUiState {
    data object Idle : ModulePurgeUiState
    data object Confirmation : ModulePurgeUiState
    data object InProgress : ModulePurgeUiState
    data class Result(
        val outcome: ModulePurgeController.Outcome,
        val erased: Boolean,
        val rebootRequired: Boolean,
        val diagnostic: String,
        /**
         * Whether the module that printed this receipt is one whose `partial` status proves the
         * removal fence is already published. Fail-closed by default; see
         * [modulePublishesRemovalFenceBeforeCleanup].
         */
        val partialProvesRemovalFence: Boolean = false,
    ) : ModulePurgeUiState {
        /**
         * Erased, with one cleanup step the module could not verify and the reboot clears.
         *
         * A non-[ModulePurgeController.Outcome.COMPLETE] outcome names that step exactly, the way
         * it does for the rollback: [ModulePurgeController.Result.erased] holds under any other
         * outcome only for a `partial` receipt that withheld `firewall_clean`, so this reservation
         * can never appear beside a firewall the module did verify.
         */
        val unverifiedCleanup: Boolean
            get() = erased && outcome != ModulePurgeController.Outcome.COMPLETE

        /**
         * Whether the module is still on its way out even though this result is reported as a
         * failure.
         *
         * `commit` publishes the durable `$MODDIR/remove` fence before it touches a single tree, so
         * every receipt printed after that point describes a module the root manager deletes at the
         * next boot no matter what else failed. A module that reserves the `partial` status for
         * exactly those post-fence states — reporting every earlier rejection as `blocked` or
         * `error` — makes [ModulePurgeController.Outcome.PARTIAL] an honest reading of "the fence
         * is already up". [rebootRequired] is a belt on the same fact: such a partial receipt
         * always demands the reboot that completes the removal.
         *
         * That reservation is a property of the *module*, not of the protocol: the wire format is
         * still version 1, and older shipped modules print `partial` for the opposite case — the
         * fence could not be published at all. [partialProvesRemovalFence] is therefore required
         * too, and it is what keeps this sentence from promising a removal that will not happen.
         *
         * Without it the failure dialog says only that something could not be removed, and the user
         * concludes the module survived — while the next boot deletes it out from under them.
         */
        val moduleRemovalStillScheduled: Boolean
            get() = !erased &&
                outcome == ModulePurgeController.Outcome.PARTIAL &&
                rebootRequired &&
                partialProvesRemovalFence

        /**
         * Whether the dialog shows what the module and the transport actually said, on the erased
         * path as much as the failing one. See [FullRollbackUiState.Result.showsDiagnostic]: the
         * static reservation above it names the single unproven firewall family and nothing else.
         */
        val showsDiagnostic: Boolean get() = diagnostic.isNotBlank() || !erased
    }
}

/**
 * Retires everything the screen says about an installed module once the purge removed it.
 *
 * The gate is [ModulePurgeController.Result.moduleDirectoryRemoved] — the module's own measurement
 * that its directory is gone — and deliberately neither the erase verdict
 * [ModulePurgeController.Result.erased] nor the stricter
 * [ModulePurgeController.Result.moduleFullyRemoved] that authorises wiping APK-private data. Those
 * two answer a different question and require proof of facts outside the module directory; the
 * screen only needs to stop describing something that no longer exists. Once the directory is gone
 * so are `zapret-status.sh` and `zapret-purge.sh`, so a screen left on its pre-purge state would
 * show a READY module with a version and live start/stop/update/purge controls that reach nothing,
 * and nothing would correct it for the lifetime of the ViewModel: the environment is reconciled
 * once, from `loadInitialState()`.
 *
 * On every fact the module owns, the projection below is the one `refreshStatus()` publishes for a
 * module it cannot query (`ModuleServiceAccess.NOT_INSTALLED`), and it has to be: the reset also
 * arms [ControlUiState.modulePurgeCompleted], so no later status read is allowed to correct it.
 * Every field that described the runtime of the erased module — the status label, the uptime, the
 * process card, the firewall counters, the pending removal, the module's own diagnostic — is
 * retired here, or it would stay on screen forever, sourced from a process and a module that are
 * both gone. See [withModuleStatusPublication].
 *
 * Three fields deliberately diverge from that projection, and only these three:
 *  - `moduleDiagnostic = null` and `autostart = false` are module-scoped facts the status path has
 *    no reason to touch, because it never removes a module. The diagnostic was printed by
 *    `zapret-status.sh`, which went with the directory, and autostart is the module's own boot
 *    flag; both describe something that no longer exists.
 *  - [ControlUiState.modulePurgeCompleted] is the terminal gate itself, which only a purge arms.
 *
 * [ControlUiState.nfqueueSupported] is explicitly *not* among them. It is not a module fact: the
 * app measures it itself with `Zapret2ModuleRepository.buildProbeCommand()`, whose only NFQUEUE
 * question is `[ -f /proc/net/netfilter/nf_queue ]` or a `grep` for `NFQUEUE` in
 * `/proc/net/ip_tables_targets` and `/proc/net/ip6_tables_targets` — it never runs `iptables`, and
 * it answers the same whether or not the module is installed. Publishing `false` here invented a
 * kernel verdict the app never took, and because the gate blocks every later publication it could
 * not be corrected before a process restart — after which the very same device reported the badge
 * green again. The module's own `Z2_NFQUEUE` is a different measurement, taken from the status
 * payload, and the app keeps none of it beyond [ControlUiState.nfqueueRulesCount] and
 * [ControlUiState.iptablesActive], both of which are retired here.
 */
internal fun ControlUiState.afterModulePurge(result: ModulePurgeController.Result): ControlUiState =
    if (!result.moduleDirectoryRemoved) {
        this
    } else {
        copy(
            autostart = false,
            isRunning = false,
            canStopService = false,
            status = ControlStatus.NOT_INSTALLED,
            serviceUptime = null,
            processStats = ProcessStats(),
            moduleDiagnostic = null,
            moduleInstallState = ModuleInstallState.MISSING,
            pendingModuleState = PendingModuleState.NONE,
            moduleMutationState = ModuleMutationState.IDLE,
            moduleRemovalPending = false,
            moduleVersion = "",
            hasAuthoritativeRuntimeSettings = false,
            iptablesActive = false,
            nfqueueRulesCount = 0,
            modulePurgeCompleted = true,
        )
    }

/**
 * Applies a module status/environment publication unless this session already erased the module.
 *
 * [afterModulePurge] is not the last write the screen sees. A status read that was already in
 * flight when the purge committed still holds the pre-purge environment it sampled — the refresh
 * sequence counter only retires *older* reads, and the purge does not participate in it — and every
 * later read (pull-to-refresh, the settlement observer, a re-entered screen, `loadInitialState`)
 * is free to run once the exclusive-action latch is released. Any of them would republish a READY
 * module with its version and live controls over the reset, and the user would be looking at a
 * module that no longer exists.
 *
 * So the erase is terminal for the session, deterministically: the verdict lives in the state
 * itself, every publication is applied through this gate against the *current* state rather than a
 * sampled one, and no timeout is involved. It cannot be un-armed either — nothing can reinstall the
 * module into a process whose purge script was deleted along with it, so only a fresh process may
 * describe a module again.
 */
internal fun ControlUiState.withModuleStatusPublication(
    publish: ControlUiState.() -> ControlUiState,
): ControlUiState = if (modulePurgeCompleted) this else publish()

/**
 * The first module release whose `commit_purge` publishes the durable `$MODDIR/remove` fence
 * before it touches any tree, and reports every rejection that can still happen before that point
 * as `blocked` or `error`. From this version on — and only from it — a `partial` receipt proves
 * the fence is up and the next boot deletes the module.
 *
 * Shipped releases up to and including v2.1.5 print `partial 1 1 0 0 0 1` for the exact opposite
 * case: `publish_remove_marker` itself failed, no marker exists, and the module survives the
 * reboot. The purge wire protocol is still version 1 and the app accepts every version-1 receipt,
 * so nothing in the record distinguishes the two — only the module version does.
 *
 * The app and the module are versioned independently and legitimately drift apart: `updateAll`
 * installs them separately, the `ApkInstallerPending` and `Partial` update outcomes leave the APK
 * ahead of the module until the next reboot, and a sideloaded APK does the same.
 */
private const val REMOVAL_FENCE_FIRST_MODULE_VERSION_CODE = 2_010_006L

/**
 * Whether the installed module is one whose `partial` purge receipt proves the removal fence was
 * already published.
 *
 * Fail-closed: an absent, unparsable or older version answers false, so the dialog stays silent
 * about a scheduled removal it cannot vouch for rather than promising one that will not happen.
 */
internal fun modulePublishesRemovalFenceBeforeCleanup(moduleVersion: String): Boolean {
    val versionCode = projectModuleVersionCode(moduleVersion) ?: return false
    return versionCode >= REMOVAL_FENCE_FIRST_MODULE_VERSION_CODE
}

/**
 * The single projection of a purge receipt onto the result dialog's state.
 *
 * [moduleVersion] is the version of the module that printed the receipt, sampled before the purge
 * reset retires it, and it decides one sentence only — see [ModulePurgeUiState.Result].
 */
internal fun modulePurgeResultState(
    result: ModulePurgeController.Result,
    diagnostic: String,
    moduleVersion: String,
): ModulePurgeUiState.Result = ModulePurgeUiState.Result(
    outcome = result.outcome,
    erased = result.erased,
    rebootRequired = result.rebootRequired,
    diagnostic = diagnostic,
    partialProvesRemovalFence = modulePublishesRemovalFenceBeforeCleanup(moduleVersion),
)

internal object FullRollbackAvailabilityPolicy {
    fun isAvailable(
        status: ControlStatus,
        hasRootAccess: Boolean,
        moduleInstallState: ModuleInstallState,
        isToggling: Boolean,
        isCheckingForUpdates: Boolean,
        isUpdating: Boolean,
        isRollingBack: Boolean,
    ): Boolean =
        status in setOf(ControlStatus.RUNNING, ControlStatus.DEGRADED, ControlStatus.STOPPED) &&
            hasRootAccess &&
            moduleInstallState.allowsFullRollback &&
            !isToggling &&
            !isCheckingForUpdates &&
            !isUpdating &&
            !isRollingBack
}

data class ControlUiState(
    val isRunning: Boolean = false,
    val status: ControlStatus = ControlStatus.CHECKING,
    /**
     * When the module's verified process started, or `null` when no status read proved one.
     *
     * The screen advances the counter itself from this anchor, so the state carries the fact and
     * not a rendering of it: a sampled duration string would be stale the instant it was published
     * and could only be corrected by a status read the app has no reason to repeat.
     */
    val serviceUptime: ServiceUptimeAnchor? = null,
    val autostart: Boolean = true,
    val moduleVersion: String = "",
    val networkType: UiText = UiText.Resource(R.string.control_network_checking),
    val iptablesActive: Boolean = false,
    val nfqueueRulesCount: Int = 0,
    val processStats: ProcessStats = ProcessStats(),
    val isToggling: Boolean = false,
    val canStopService: Boolean = false,
    val showQuicBanner: Boolean = false,
    val hasRootAccess: Boolean = false,
    val rootAccessState: ServiceLifecycleController.RootAccessState? = null,
    val moduleInstallState: ModuleInstallState = ModuleInstallState.UNKNOWN,
    val pendingModuleState: PendingModuleState = PendingModuleState.NONE,
    val moduleMutationState: ModuleMutationState = ModuleMutationState.IDLE,
    /**
     * The module reports that it will be deleted on the next boot (`Z2_UNINSTALL_TOMBSTONE=1`).
     *
     * The module raises this for either of two facts it deliberately does not distinguish: an
     * uninstall tombstone in its own state directory, or a root-manager removal mark in the module
     * directory. The app cannot tell them apart from the status payload, and does not need to —
     * both end in the same place, and both make `zapret-full-rollback.sh`, `zapret-start.sh` and
     * every `ModuleMutationCoordinator.withMutation` write refuse.
     *
     * It is a live measurement, not an installation fact: the environment is reconciled once per
     * process, so when the user marks the module for removal in Magisk/KernelSU while the screen is
     * open, [moduleInstallState] stays `READY` for the lifetime of the ViewModel and this flag —
     * republished by every status read — is the only thing that can correct the screen.
     */
    val moduleRemovalPending: Boolean = false,
    val nfqueueSupported: Boolean = false,
    val isCheckingForUpdates: Boolean = false,
    val isUpdating: Boolean = false,
    val isSavingSettings: Boolean = false,
    val hasAuthoritativeRuntimeSettings: Boolean = false,
    val moduleDiagnostic: String? = null,
    val updateProgress: Float = 0f,
    val updateStatus: UiText? = null,
    val pendingDialog: ControlDialogKind? = null,
    val updateRelease: UpdateManager.Release? = null,
    val errorDialog: ControlErrorDialog? = null,
    val fullRollback: FullRollbackUiState = FullRollbackUiState.Idle,
    val modulePurge: ModulePurgeUiState = ModulePurgeUiState.Idle,
    /**
     * Session-terminal: an erase that removed the module already happened in this process.
     *
     * Deliberately not persisted. A successful purge clears the app's own saved state along with
     * the module, and a fresh process reconciles the environment from scratch, so the flag only has
     * to outlive the status reads of the process that erased the module.
     */
    val modulePurgeCompleted: Boolean = false,
    val lastResult: ControlLastResult? = null,
    val message: UiText? = null,
) {
    /**
     * Whether the installed module can still be asked to do anything for the user.
     *
     * A module marked for removal is not operational however healthy its runtime looks: the
     * readiness badge, the autostart switch and the start action all rest on this, and all three
     * are refused by the module while the removal mark or the tombstone is up.
     */
    val isModuleOperational: Boolean
        get() = moduleInstallState.isOperational &&
            moduleMutationState == ModuleMutationState.IDLE &&
            !moduleRemovalPending

    /**
     * Whether starting the service is worth offering.
     *
     * Stopping is deliberately *not* gated on [moduleRemovalPending]. `zapret-start.sh` refuses on
     * either fact behind the flag, but `zapret-stop.sh` refuses only on a live uninstall tombstone,
     * not on a root-manager removal mark — and the status payload merges the two, so the app cannot
     * prove a stop will fail. Withholding it would strand a running service the user can still
     * legitimately want to shut down before the reboot that removes the module.
     */
    val canStartService: Boolean
        get() = hasRootAccess && isModuleOperational && nfqueueSupported
    val isFullRollbackInProgress: Boolean get() = fullRollback is FullRollbackUiState.InProgress
    val isModulePurgeInProgress: Boolean get() = modulePurge is ModulePurgeUiState.InProgress
    val canEditSettings: Boolean get() = status in setOf(
        ControlStatus.RUNNING,
        ControlStatus.DEGRADED,
        ControlStatus.STOPPED,
    ) && isModuleOperational && hasRootAccess &&
        hasAuthoritativeRuntimeSettings &&
        !isToggling && !isCheckingForUpdates && !isUpdating &&
        !isSavingSettings && !isFullRollbackInProgress && !isModulePurgeInProgress
    /**
     * `zapret-full-rollback.sh` refuses on both facts [moduleRemovalPending] carries — the
     * uninstall tombstone and the root-manager removal mark are two consecutive `blocked` gates
     * ahead of every other precondition — so offering the action can only produce a failure dialog.
     * Erasing the module is not gated the same way: `zapret-purge.sh` is written to run with the
     * removal mark already published, and it is the one way out of this state.
     */
    val canFullRollback: Boolean
        get() = moduleMutationState == ModuleMutationState.IDLE &&
            !moduleRemovalPending &&
            FullRollbackAvailabilityPolicy.isAvailable(
                status = status,
                hasRootAccess = hasRootAccess,
                moduleInstallState = moduleInstallState,
                isToggling = isToggling || isSavingSettings,
                isCheckingForUpdates = isCheckingForUpdates,
                isUpdating = isUpdating,
                isRollingBack = isFullRollbackInProgress || isModulePurgeInProgress,
            )
    val canPurgeModule: Boolean get() = status in setOf(
        ControlStatus.RUNNING,
        ControlStatus.DEGRADED,
        ControlStatus.STOPPED,
    ) && hasRootAccess && moduleMutationState == ModuleMutationState.IDLE &&
        moduleInstallState.allowsFullRollback &&
        !isToggling && !isCheckingForUpdates && !isUpdating && !isSavingSettings &&
        !isFullRollbackInProgress && !isModulePurgeInProgress
}

/**
 * What `Zapret2ModuleRepository.readProcessMetrics` can prove about the module's own process.
 *
 * There is deliberately no CPU field: the repository reads `/proc/<pid>` for memory and thread
 * count and nothing else, so a `cpu` slot could only ever be empty, and the process card row it fed
 * was unreachable for every device. Uptime is likewise absent — it belongs to
 * [ControlUiState.serviceUptime], which the module's own status payload anchors.
 */
data class ProcessStats(
    val pid: String = "",
    val memory: String = "",
    val threads: String = "",
)

private const val KEY_DIALOG_KIND = "control_dialog_kind"
private const val KEY_ERROR_KIND = "control_error_kind"
private const val KEY_ERROR_DETAIL_RESOURCE = "control_error_detail_resource"
private const val KEY_ERROR_DETAIL_DYNAMIC = "control_error_detail_dynamic"
private const val KEY_ROLLBACK_IN_PROGRESS = "control_full_rollback_in_progress"
private const val KEY_ROLLBACK_OUTCOME = "control_full_rollback_outcome"
private const val KEY_ROLLBACK_ROLLED_BACK = "control_full_rollback_rolled_back"
private const val KEY_ROLLBACK_REBOOT_REQUIRED = "control_full_rollback_reboot_required"
private const val KEY_ROLLBACK_DIAGNOSTIC = "control_full_rollback_diagnostic"
private const val KEY_PURGE_IN_PROGRESS = "control_module_purge_in_progress"
private const val KEY_PURGE_OUTCOME = "control_module_purge_outcome"
private const val KEY_PURGE_REBOOT_REQUIRED = "control_module_purge_reboot_required"
private const val KEY_PURGE_DIAGNOSTIC = "control_module_purge_diagnostic"
private const val KEY_PURGE_REMOVAL_FENCE = "control_module_purge_removal_fence"
private const val KEY_LAST_RESULT = "control_last_result"
private const val MAX_ERROR_DETAIL_LENGTH = 12_000
private const val UPDATE_STATUS_REFRESH_DELAY_MS = 1_000L
private val CONTROL_ERROR_DETAIL_RESOURCES = setOf(
    R.string.control_environment_probe_failed,
    R.string.control_runtime_rollback_failed,
    R.string.control_service_expected_state_error,
    R.string.control_update_apk_file_invalid,
    R.string.control_update_apk_installer_unavailable,
    R.string.control_update_apk_not_newer,
    R.string.control_update_apk_package_mismatch,
    R.string.control_update_apk_signer_mismatch,
    R.string.control_update_apk_signer_unavailable,
    R.string.control_update_apk_unreadable,
    R.string.control_update_apk_validation_failed,
    R.string.control_update_apk_version_code_mismatch,
    R.string.control_update_apk_version_mismatch,
    R.string.control_update_download_checksum,
    R.string.control_update_download_failed,
    R.string.control_update_download_no_internet,
    R.string.control_update_download_redirects,
    R.string.control_update_download_secure_connection_failed,
    R.string.control_update_download_security_rejected,
    R.string.control_update_download_server_rejected,
    R.string.control_update_download_storage,
    R.string.control_update_download_timeout,
    R.string.control_update_download_too_large,
    R.string.control_update_installed_signer_unavailable,
    R.string.control_update_module_empty,
    R.string.control_update_module_entry_too_large,
    R.string.control_update_module_expanded_too_large,
    R.string.control_update_module_identity_missing,
    R.string.control_update_module_install_failed,
    R.string.control_update_module_package_invalid,
    R.string.control_update_module_rejected,
    R.string.control_update_module_too_many_entries,
    R.string.control_update_module_unsafe_path,
    R.string.control_update_module_validation_failed,
    R.string.control_update_unsupported_abi,
    R.string.control_unknown_error,
)
private val CONTROL_ERROR_DETAIL_WRAPPER_FALLBACKS = emptyMap<Int, Int>()

private class EnvironmentProbeException : IllegalStateException()

private fun restoreControlErrorDetails(savedStateHandle: SavedStateHandle): UiText? {
    val hasResource = savedStateHandle.contains(KEY_ERROR_DETAIL_RESOURCE)
    val hasDynamic = savedStateHandle.contains(KEY_ERROR_DETAIL_DYNAMIC)
    if (!hasResource && !hasDynamic) return null

    val resourceId = if (hasResource) {
        savedStateHandle.restoreTypedOrRemove<Int>(KEY_ERROR_DETAIL_RESOURCE)
    } else {
        null
    }
    val safeDynamic = if (hasDynamic) {
        sanitizedBoundedUiDiagnostic(
            savedStateHandle.restoreTypedOrRemove<String>(KEY_ERROR_DETAIL_DYNAMIC).orEmpty(),
        ).takeIf(String::isNotBlank)
    } else {
        null
    }
    return when {
        resourceId != null &&
            resourceId in CONTROL_ERROR_DETAIL_WRAPPER_FALLBACKS &&
            safeDynamic != null -> UiText.resource(resourceId, safeDynamic)
        resourceId != null &&
            resourceId in CONTROL_ERROR_DETAIL_WRAPPER_FALLBACKS -> UiText.Resource(
                CONTROL_ERROR_DETAIL_WRAPPER_FALLBACKS.getValue(resourceId),
            )
        resourceId != null && resourceId in CONTROL_ERROR_DETAIL_RESOURCES ->
            UiText.Resource(resourceId)
        hasResource -> UiText.Resource(R.string.control_unknown_error)
        safeDynamic != null -> UiText.Dynamic(safeDynamic)
        else -> UiText.Resource(R.string.control_unknown_error)
    }
}

private fun UiText.toSafeControlErrorDetails(): UiText = when (this) {
    is UiText.Dynamic -> sanitizedBoundedUiDiagnostic(value)
        .takeIf(String::isNotBlank)
        ?.let(UiText::Dynamic)
        ?: UiText.Resource(R.string.control_unknown_error)
    is UiText.Resource -> when {
        id in CONTROL_ERROR_DETAIL_RESOURCES && arguments.isEmpty() -> this
        id in CONTROL_ERROR_DETAIL_WRAPPER_FALLBACKS && arguments.size == 1 -> {
            val rawDiagnostic = when (val argument = arguments.single()) {
                is String -> argument
                is UiText.Dynamic -> argument.value
                else -> ""
            }
            sanitizedBoundedUiDiagnostic(rawDiagnostic)
                .takeIf(String::isNotBlank)
                ?.let { UiText.resource(id, it) }
                ?: UiText.Resource(CONTROL_ERROR_DETAIL_WRAPPER_FALLBACKS.getValue(id))
        }
        else -> UiText.Resource(R.string.control_unknown_error)
    }
}

private fun SavedStateHandle.persistControlErrorDetails(details: UiText) {
    when (details) {
        is UiText.Dynamic -> {
            this[KEY_ERROR_DETAIL_DYNAMIC] = details.value
            remove<Int>(KEY_ERROR_DETAIL_RESOURCE)
        }
        is UiText.Resource -> {
            this[KEY_ERROR_DETAIL_RESOURCE] = details.id
            val argument = details.arguments.singleOrNull() as? String
            if (argument == null) {
                remove<String>(KEY_ERROR_DETAIL_DYNAMIC)
            } else {
                this[KEY_ERROR_DETAIL_DYNAMIC] = argument
            }
        }
    }
}

internal fun restoreControlUiState(savedStateHandle: SavedStateHandle): ControlUiState {
    val dialogKind = savedStateHandle.restoreEnumNameOrRemove<ControlDialogKind>(KEY_DIALOG_KIND)
    val errorKind = savedStateHandle.restoreEnumNameOrRemove<ControlErrorKind>(KEY_ERROR_KIND)
    val errorDetails = restoreControlErrorDetails(savedStateHandle)
    val rollbackResult = if (dialogKind == ControlDialogKind.FULL_ROLLBACK_RESULT) {
        val outcome = savedStateHandle
            .restoreEnumNameOrRemove<ServiceLifecycleController.FullRollbackOutcome>(
                KEY_ROLLBACK_OUTCOME,
            )
        val persistedRolledBack = savedStateHandle
            .restoreTypedOrRemove<Boolean>(KEY_ROLLBACK_ROLLED_BACK) == true
        outcome?.let {
            FullRollbackUiState.Result(
                outcome = it,
                // A stale or forged flag must never upgrade an outcome that cannot be rolled
                // back; only a partial receipt can carry the claim that it nonetheless finished.
                rolledBack = when (it) {
                    ServiceLifecycleController.FullRollbackOutcome.COMPLETE -> true
                    ServiceLifecycleController.FullRollbackOutcome.PARTIAL -> persistedRolledBack
                    else -> false
                },
                rebootRequired = savedStateHandle
                    .restoreTypedOrRemove<Boolean>(KEY_ROLLBACK_REBOOT_REQUIRED) == true,
                diagnostic = sanitizedBoundedUiDiagnostic(
                    savedStateHandle
                        .restoreTypedOrRemove<String>(KEY_ROLLBACK_DIAGNOSTIC)
                        .orEmpty(),
                ),
            )
        }
    } else {
        null
    }
    val fullRollback = when {
        rollbackResult != null -> rollbackResult
        savedStateHandle.restoreTypedOrRemove<Boolean>(KEY_ROLLBACK_IN_PROGRESS) == true ->
            FullRollbackUiState.InProgress
        dialogKind == ControlDialogKind.FULL_ROLLBACK_CONFIRM -> FullRollbackUiState.Confirmation
        else -> FullRollbackUiState.Idle
    }
    val purgeResult = if (dialogKind == ControlDialogKind.MODULE_PURGE_RESULT) {
        val outcome = savedStateHandle.restoreEnumNameOrRemove<ModulePurgeController.Outcome>(
            KEY_PURGE_OUTCOME,
        )
        outcome?.let {
            ModulePurgeUiState.Result(
                outcome = it,
                // Only a failed erase is ever persisted: a successful one retires its dialog
                // together with the app-owned storage it just wiped.
                erased = false,
                rebootRequired = savedStateHandle
                    .restoreTypedOrRemove<Boolean>(KEY_PURGE_REBOOT_REQUIRED) == true,
                partialProvesRemovalFence = savedStateHandle
                    .restoreTypedOrRemove<Boolean>(KEY_PURGE_REMOVAL_FENCE) == true,
                diagnostic = sanitizedBoundedUiDiagnostic(
                    savedStateHandle.restoreTypedOrRemove<String>(KEY_PURGE_DIAGNOSTIC).orEmpty(),
                ),
            )
        }
    } else {
        null
    }
    val restoredPurge = when {
        purgeResult != null -> purgeResult
        savedStateHandle.restoreTypedOrRemove<Boolean>(KEY_PURGE_IN_PROGRESS) == true ->
            ModulePurgeUiState.InProgress
        dialogKind == ControlDialogKind.MODULE_PURGE_CONFIRM -> ModulePurgeUiState.Confirmation
        else -> ModulePurgeUiState.Idle
    }
    // Corrupt or stale SavedState must never restore two destructive operations at once.
    val modulePurge = restoredPurge.takeIf { fullRollback is FullRollbackUiState.Idle }
        ?: ModulePurgeUiState.Idle
    val restoredDialog = when {
        fullRollback is FullRollbackUiState.InProgress -> null
        fullRollback is FullRollbackUiState.Result -> ControlDialogKind.FULL_ROLLBACK_RESULT
        fullRollback is FullRollbackUiState.Confirmation -> ControlDialogKind.FULL_ROLLBACK_CONFIRM
        modulePurge is ModulePurgeUiState.InProgress -> null
        modulePurge is ModulePurgeUiState.Result -> ControlDialogKind.MODULE_PURGE_RESULT
        modulePurge is ModulePurgeUiState.Confirmation -> ControlDialogKind.MODULE_PURGE_CONFIRM
        else -> when (dialogKind) {
            ControlDialogKind.UPDATE -> ControlDialogKind.UPDATE
            ControlDialogKind.ERROR -> ControlDialogKind.ERROR.takeIf {
                errorKind != null && errorDetails != null
            }
            ControlDialogKind.FULL_ROLLBACK_CONFIRM,
            ControlDialogKind.FULL_ROLLBACK_RESULT,
            ControlDialogKind.MODULE_PURGE_CONFIRM,
            ControlDialogKind.MODULE_PURGE_RESULT,
            null,
            -> null
        }
    }
    canonicalizeRestoredControlState(
        savedStateHandle = savedStateHandle,
        dialog = restoredDialog,
        errorKind = errorKind,
        errorDetails = errorDetails,
        fullRollback = fullRollback,
        modulePurge = modulePurge,
    )
    return ControlUiState(
        pendingDialog = restoredDialog,
        errorDialog = if (
            restoredDialog == ControlDialogKind.ERROR && errorKind != null && errorDetails != null
        ) {
            ControlErrorDialog(errorKind, errorDetails)
        } else {
            null
        },
        fullRollback = fullRollback,
        modulePurge = modulePurge,
        lastResult = restoreControlLastResult(savedStateHandle),
    )
}

private fun canonicalizeRestoredControlState(
    savedStateHandle: SavedStateHandle,
    dialog: ControlDialogKind?,
    errorKind: ControlErrorKind?,
    errorDetails: UiText?,
    fullRollback: FullRollbackUiState,
    modulePurge: ModulePurgeUiState,
) {
    if (dialog == null) savedStateHandle.remove<String>(KEY_DIALOG_KIND)
    else savedStateHandle[KEY_DIALOG_KIND] = dialog.name

    if (dialog != ControlDialogKind.ERROR) {
        savedStateHandle.remove<String>(KEY_ERROR_KIND)
        savedStateHandle.remove<Int>(KEY_ERROR_DETAIL_RESOURCE)
        savedStateHandle.remove<String>(KEY_ERROR_DETAIL_DYNAMIC)
    } else {
        savedStateHandle[KEY_ERROR_KIND] = checkNotNull(errorKind).name
        savedStateHandle.persistControlErrorDetails(checkNotNull(errorDetails))
    }
    if (fullRollback !is FullRollbackUiState.Result) {
        savedStateHandle.remove<String>(KEY_ROLLBACK_OUTCOME)
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_ROLLED_BACK)
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_REBOOT_REQUIRED)
        savedStateHandle.remove<String>(KEY_ROLLBACK_DIAGNOSTIC)
    } else {
        savedStateHandle[KEY_ROLLBACK_OUTCOME] = fullRollback.outcome.name
        savedStateHandle[KEY_ROLLBACK_ROLLED_BACK] = fullRollback.rolledBack
        savedStateHandle[KEY_ROLLBACK_REBOOT_REQUIRED] = fullRollback.rebootRequired
        savedStateHandle[KEY_ROLLBACK_DIAGNOSTIC] = fullRollback.diagnostic
    }
    if (fullRollback !is FullRollbackUiState.InProgress) {
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_IN_PROGRESS)
    }
    if (modulePurge !is ModulePurgeUiState.Result) {
        savedStateHandle.remove<String>(KEY_PURGE_OUTCOME)
        savedStateHandle.remove<Boolean>(KEY_PURGE_REBOOT_REQUIRED)
        savedStateHandle.remove<Boolean>(KEY_PURGE_REMOVAL_FENCE)
        savedStateHandle.remove<String>(KEY_PURGE_DIAGNOSTIC)
    } else {
        savedStateHandle[KEY_PURGE_OUTCOME] = modulePurge.outcome.name
        savedStateHandle[KEY_PURGE_REBOOT_REQUIRED] = modulePurge.rebootRequired
        savedStateHandle[KEY_PURGE_REMOVAL_FENCE] = modulePurge.partialProvesRemovalFence
        savedStateHandle[KEY_PURGE_DIAGNOSTIC] = modulePurge.diagnostic
    }
    if (modulePurge !is ModulePurgeUiState.InProgress) {
        savedStateHandle.remove<Boolean>(KEY_PURGE_IN_PROGRESS)
    }
}

internal enum class FullRollbackLaunchReason { CONFIRMED, RESTORED }

internal class FullRollbackOperationCoordinator(
    private val savedStateHandle: SavedStateHandle,
    private val operationInProgress: AtomicBoolean = AtomicBoolean(false),
    private val onTerminalPersisted: () -> Unit = {},
) {
    fun tryBegin(
        reason: FullRollbackLaunchReason,
        state: ControlUiState,
        launch: () -> Unit,
    ): Boolean {
        val eligible = when (reason) {
            FullRollbackLaunchReason.CONFIRMED ->
                state.fullRollback is FullRollbackUiState.Confirmation && state.canFullRollback
            FullRollbackLaunchReason.RESTORED ->
                state.fullRollback is FullRollbackUiState.InProgress &&
                    savedStateHandle.restoreTypedOrRemove<Boolean>(KEY_ROLLBACK_IN_PROGRESS) == true
        }
        if (!eligible || !operationInProgress.compareAndSet(false, true)) return false

        savedStateHandle[KEY_ROLLBACK_IN_PROGRESS] = true
        savedStateHandle.remove<String>(KEY_DIALOG_KIND)
        savedStateHandle.remove<String>(KEY_ERROR_KIND)
        savedStateHandle.remove<Int>(KEY_ERROR_DETAIL_RESOURCE)
        savedStateHandle.remove<String>(KEY_ERROR_DETAIL_DYNAMIC)
        clearPersistedResult()

        return try {
            launch()
            true
        } catch (error: Throwable) {
            operationInProgress.set(false)
            throw error
        }
    }

    fun persistTerminal(
        result: ServiceLifecycleController.FullRollbackResult,
        diagnostic: String,
        lastResult: ControlLastResult,
    ) {
        savedStateHandle[KEY_ROLLBACK_OUTCOME] = result.outcome.name
        savedStateHandle[KEY_ROLLBACK_ROLLED_BACK] = result.rolledBack
        savedStateHandle[KEY_ROLLBACK_REBOOT_REQUIRED] = result.rebootRequired
        savedStateHandle[KEY_ROLLBACK_DIAGNOSTIC] = diagnostic
        savedStateHandle[KEY_LAST_RESULT] = lastResult.name
        savedStateHandle.remove<String>(KEY_ERROR_KIND)
        savedStateHandle.remove<Int>(KEY_ERROR_DETAIL_RESOURCE)
        savedStateHandle.remove<String>(KEY_ERROR_DETAIL_DYNAMIC)
        // The discriminator is written after the complete terminal payload so restoration
        // cannot mistake a partially persisted terminal transition for a completed result.
        savedStateHandle[KEY_DIALOG_KIND] = ControlDialogKind.FULL_ROLLBACK_RESULT.name
        onTerminalPersisted()
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_IN_PROGRESS)
    }

    fun finishAttempt() {
        operationInProgress.set(false)
    }

    private fun clearPersistedResult() {
        savedStateHandle.remove<String>(KEY_ROLLBACK_OUTCOME)
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_ROLLED_BACK)
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_REBOOT_REQUIRED)
        savedStateHandle.remove<String>(KEY_ROLLBACK_DIAGNOSTIC)
    }
}

internal enum class ModulePurgeLaunchReason { CONFIRMED, RESTORED }

internal class ModulePurgeOperationCoordinator(
    private val savedStateHandle: SavedStateHandle,
    private val operationInProgress: AtomicBoolean = AtomicBoolean(false),
) {
    fun tryBegin(
        reason: ModulePurgeLaunchReason,
        state: ControlUiState,
        launch: () -> Unit,
    ): Boolean {
        val eligible = when (reason) {
            ModulePurgeLaunchReason.CONFIRMED ->
                state.modulePurge is ModulePurgeUiState.Confirmation && state.canPurgeModule
            ModulePurgeLaunchReason.RESTORED ->
                state.modulePurge is ModulePurgeUiState.InProgress &&
                    savedStateHandle.restoreTypedOrRemove<Boolean>(KEY_PURGE_IN_PROGRESS) == true
        }
        if (!eligible || !operationInProgress.compareAndSet(false, true)) return false

        savedStateHandle[KEY_PURGE_IN_PROGRESS] = true
        savedStateHandle.remove<String>(KEY_DIALOG_KIND)
        savedStateHandle.remove<String>(KEY_ERROR_KIND)
        savedStateHandle.remove<Int>(KEY_ERROR_DETAIL_RESOURCE)
        savedStateHandle.remove<String>(KEY_ERROR_DETAIL_DYNAMIC)
        clearPersistedResult()

        return try {
            launch()
            true
        } catch (error: Throwable) {
            operationInProgress.set(false)
            throw error
        }
    }

    fun persistTerminal(
        result: ModulePurgeController.Result,
        diagnostic: String,
        lastResult: ControlLastResult,
        projected: ModulePurgeUiState.Result,
    ) {
        savedStateHandle[KEY_PURGE_OUTCOME] = result.outcome.name
        savedStateHandle[KEY_PURGE_REBOOT_REQUIRED] = result.rebootRequired
        // The module version this was derived from is retired with the module, so the answer, not
        // the input, is what survives a process restart. Absent, it restores fail-closed.
        savedStateHandle[KEY_PURGE_REMOVAL_FENCE] = projected.partialProvesRemovalFence
        savedStateHandle[KEY_PURGE_DIAGNOSTIC] = diagnostic
        savedStateHandle[KEY_LAST_RESULT] = lastResult.name
        savedStateHandle.remove<String>(KEY_ERROR_KIND)
        savedStateHandle.remove<Int>(KEY_ERROR_DETAIL_RESOURCE)
        savedStateHandle.remove<String>(KEY_ERROR_DETAIL_DYNAMIC)
        savedStateHandle[KEY_DIALOG_KIND] = ControlDialogKind.MODULE_PURGE_RESULT.name
        savedStateHandle.remove<Boolean>(KEY_PURGE_IN_PROGRESS)
    }

    fun finishAttempt() {
        operationInProgress.set(false)
    }

    fun retireSuccessfulTerminalState() {
        savedStateHandle.remove<String>(KEY_DIALOG_KIND)
        savedStateHandle.remove<Boolean>(KEY_PURGE_IN_PROGRESS)
        savedStateHandle.remove<String>(KEY_PURGE_OUTCOME)
        savedStateHandle.remove<Boolean>(KEY_PURGE_REBOOT_REQUIRED)
        savedStateHandle.remove<Boolean>(KEY_PURGE_REMOVAL_FENCE)
        savedStateHandle.remove<String>(KEY_PURGE_DIAGNOSTIC)
        savedStateHandle.remove<String>(KEY_LAST_RESULT)
    }

    private fun clearPersistedResult() {
        savedStateHandle.remove<String>(KEY_PURGE_OUTCOME)
        savedStateHandle.remove<Boolean>(KEY_PURGE_REBOOT_REQUIRED)
        savedStateHandle.remove<Boolean>(KEY_PURGE_REMOVAL_FENCE)
        savedStateHandle.remove<String>(KEY_PURGE_DIAGNOSTIC)
    }
}

@HiltViewModel
class ControlViewModel @Inject constructor(
    private val networkStatsManager: NetworkStatsManager,
    private val updateManager: UpdateManager,
    private val prefs: SharedPreferences,
    private val serviceEventBus: ServiceEventBus,
    private val savedStateHandle: SavedStateHandle,
    private val moduleRepository: Zapret2ModuleRepository,
    private val logRepository: RuntimeLogRepository,
    private val modulePurgeAppDataCleaner: ModulePurgeAppDataCleaner,
) : ViewModel() {

    private val _uiState = MutableStateFlow(restoreControlUiState(savedStateHandle))
    val uiState: StateFlow<ControlUiState> = _uiState.asStateFlow()

    private var screenStarted = false
    private var statusInvalidated = false
    private val initializationRequested = AtomicBoolean(false)
    private val initializationFinished = AtomicBoolean(false)
    private val toggleInProgress = AtomicBoolean(false)
    private val settingMutationInProgress = AtomicBoolean(false)
    private val updateCheckInProgress = AtomicBoolean(false)
    private val exclusiveActionInProgress = AtomicBoolean(false)
    private val rollbackOperation = FullRollbackOperationCoordinator(
        savedStateHandle = savedStateHandle,
        operationInProgress = exclusiveActionInProgress,
    )
    private val purgeOperation = ModulePurgeOperationCoordinator(
        savedStateHandle = savedStateHandle,
        operationInProgress = exclusiveActionInProgress,
    )
    private val statusRefreshSequence = AtomicLong(0)
    private val lifecycleSettlementObserver = LifecycleSettlementObserver(
        scope = viewModelScope,
        observe = { refreshServiceStatusOnce() },
    )

    init {
        viewModelScope.launch {
            serviceEventBus.serviceRestarted.collect { source ->
                if (source != ServiceEventSource.CONTROL) statusInvalidated = true
            }
        }
        if (_uiState.value.fullRollback is FullRollbackUiState.InProgress) {
            startFullRollback(FullRollbackLaunchReason.RESTORED)
        } else if (_uiState.value.modulePurge is ModulePurgeUiState.InProgress) {
            startModulePurge(ModulePurgeLaunchReason.RESTORED)
        }
    }

    fun ensureInitialized() {
        if (initializationRequested.compareAndSet(false, true)) loadInitialState()
    }

    fun onScreenStarted() {
        if (screenStarted) return
        screenStarted = true
        if (_uiState.value.moduleMutationState == ModuleMutationState.IN_PROGRESS) {
            lifecycleSettlementObserver.ensureObserving()
        }
        if (statusInvalidated) {
            statusInvalidated = false
            viewModelScope.launch { refreshServiceStatusOnce() }
        }
    }

    fun onScreenStopped() {
        screenStarted = false
        lifecycleSettlementObserver.stop()
    }

    fun clearMessage() {
        _uiState.update { it.copy(message = null) }
    }

    private fun publishMessage(message: UiText) {
        _uiState.update { it.copy(message = message) }
    }

    fun dismissDialog() {
        val state = _uiState.value
        if (state.isFullRollbackInProgress || state.isModulePurgeInProgress ||
            state.isUpdating ||
            ServiceLifecycleController.isAppUpdateInProgress()
        ) return
        clearPersistedDialog()
        _uiState.update {
            it.copy(
                pendingDialog = null,
                updateRelease = null,
                errorDialog = null,
                fullRollback = FullRollbackUiState.Idle,
                modulePurge = ModulePurgeUiState.Idle,
            )
        }
    }

    fun showFullRollbackConfirmation() {
        if (rejectConflictingOperation()) return
        val state = _uiState.value
        if (!state.canFullRollback || state.pendingDialog != null) return
        savedStateHandle[KEY_DIALOG_KIND] = ControlDialogKind.FULL_ROLLBACK_CONFIRM.name
        clearPersistedError()
        clearPersistedRollback()
        clearPersistedPurge()
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_IN_PROGRESS)
        savedStateHandle.remove<Boolean>(KEY_PURGE_IN_PROGRESS)
        _uiState.update {
            it.copy(
                pendingDialog = ControlDialogKind.FULL_ROLLBACK_CONFIRM,
                updateRelease = null,
                errorDialog = null,
                fullRollback = FullRollbackUiState.Confirmation,
                modulePurge = ModulePurgeUiState.Idle,
            )
        }
    }

    fun confirmFullRollback() {
        startFullRollback(FullRollbackLaunchReason.CONFIRMED)
    }

    private fun startFullRollback(reason: FullRollbackLaunchReason) {
        rollbackOperation.tryBegin(reason, _uiState.value) {
            _uiState.update {
                it.copy(
                    pendingDialog = null,
                    updateRelease = null,
                    errorDialog = null,
                    fullRollback = FullRollbackUiState.InProgress,
                    modulePurge = ModulePurgeUiState.Idle,
                )
            }

            viewModelScope.launch {
                try {
                    val result = ServiceLifecycleController.fullRollback()
                    try {
                        refreshStatus()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        // The controller already performed the authoritative post-command check.
                    }
                    // The rollback disarms autostart before anything else it does, so every
                    // outcome that actually rolled back left it off, verified firewall or not.
                    if (result.rolledBack) {
                        _uiState.update { it.copy(autostart = false) }
                    }
                    showFullRollbackResult(result)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    showFullRollbackResult(
                        ServiceLifecycleController.FullRollbackResult(
                            outcome = ServiceLifecycleController.FullRollbackOutcome.ERROR,
                        ),
                    )
                } finally {
                    // Cancellation intentionally keeps the durable marker so a recreated
                    // ViewModel can reconcile the idempotent rollback operation.
                    rollbackOperation.finishAttempt()
                }
            }
        }
    }

    private fun showFullRollbackResult(result: ServiceLifecycleController.FullRollbackResult) {
        val diagnostic = sanitizedBoundedUiDiagnostic(result.diagnosticText())
        val rolledBack = result.rolledBack
        val lastResult = if (rolledBack) {
            ControlLastResult.ROLLBACK_COMPLETED
        } else {
            ControlLastResult.ROLLBACK_FAILED
        }
        rollbackOperation.persistTerminal(
            result = result,
            diagnostic = diagnostic,
            lastResult = lastResult,
        )
        _uiState.update {
            it.copy(
                pendingDialog = ControlDialogKind.FULL_ROLLBACK_RESULT,
                updateRelease = null,
                errorDialog = null,
                fullRollback = FullRollbackUiState.Result(
                    outcome = result.outcome,
                    rolledBack = rolledBack,
                    rebootRequired = result.rebootRequired,
                    diagnostic = diagnostic,
                ),
                modulePurge = ModulePurgeUiState.Idle,
                lastResult = lastResult,
            )
        }
    }

    fun showModulePurgeConfirmation() {
        if (rejectConflictingOperation()) return
        val state = _uiState.value
        if (!state.canPurgeModule || state.pendingDialog != null) return
        savedStateHandle[KEY_DIALOG_KIND] = ControlDialogKind.MODULE_PURGE_CONFIRM.name
        clearPersistedError()
        clearPersistedRollback()
        clearPersistedPurge()
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_IN_PROGRESS)
        savedStateHandle.remove<Boolean>(KEY_PURGE_IN_PROGRESS)
        _uiState.update {
            it.copy(
                pendingDialog = ControlDialogKind.MODULE_PURGE_CONFIRM,
                updateRelease = null,
                errorDialog = null,
                fullRollback = FullRollbackUiState.Idle,
                modulePurge = ModulePurgeUiState.Confirmation,
            )
        }
    }

    fun confirmModulePurge() {
        startModulePurge(ModulePurgeLaunchReason.CONFIRMED)
    }

    private fun startModulePurge(reason: ModulePurgeLaunchReason) {
        purgeOperation.tryBegin(reason, _uiState.value) {
            _uiState.update {
                it.copy(
                    pendingDialog = null,
                    updateRelease = null,
                    errorDialog = null,
                    fullRollback = FullRollbackUiState.Idle,
                    modulePurge = ModulePurgeUiState.InProgress,
                )
            }

            viewModelScope.launch {
                // Sampled before the purge retires it: the reset below clears the module version,
                // and the result dialog still has to know which module printed the receipt.
                val moduleVersion = _uiState.value.moduleVersion
                try {
                    val result = ModulePurgeController.purge(modulePurgeAppDataCleaner)
                    _uiState.update { it.afterModulePurge(result) }
                    showModulePurgeResult(result, moduleVersion)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    showModulePurgeResult(
                        ModulePurgeController.Result(ModulePurgeController.Outcome.ERROR),
                        moduleVersion,
                    )
                } finally {
                    purgeOperation.finishAttempt()
                }
            }
        }
    }

    private fun showModulePurgeResult(
        result: ModulePurgeController.Result,
        moduleVersion: String,
    ) {
        val diagnostic = sanitizedBoundedUiDiagnostic(result.diagnosticText())
        val erased = result.erased
        val projected = modulePurgeResultState(result, diagnostic, moduleVersion)
        val lastResult = if (erased) {
            ControlLastResult.PURGE_COMPLETED
        } else {
            ControlLastResult.PURGE_FAILED
        }
        if (erased) {
            // Keep the success dialog only in memory; a clean reset must not recreate
            // its own persisted app state after the app-owned storage was cleared.
            purgeOperation.retireSuccessfulTerminalState()
        } else {
            purgeOperation.persistTerminal(result, diagnostic, lastResult, projected)
        }
        _uiState.update {
            it.copy(
                pendingDialog = ControlDialogKind.MODULE_PURGE_RESULT,
                updateRelease = null,
                errorDialog = null,
                fullRollback = FullRollbackUiState.Idle,
                modulePurge = projected,
                lastResult = lastResult,
            )
        }
    }

    private fun showUpdateDialog(release: UpdateManager.Release) {
        savedStateHandle[KEY_DIALOG_KIND] = ControlDialogKind.UPDATE.name
        clearPersistedError()
        clearPersistedRollback()
        clearPersistedPurge()
        _uiState.update {
            it.copy(
                pendingDialog = ControlDialogKind.UPDATE,
                updateRelease = release,
                errorDialog = null,
                fullRollback = FullRollbackUiState.Idle,
                modulePurge = ModulePurgeUiState.Idle,
            )
        }
    }

    private fun showErrorDialog(kind: ControlErrorKind, details: UiText) {
        if (_uiState.value.isFullRollbackInProgress || _uiState.value.isModulePurgeInProgress) return
        val safeDetails = details.toSafeControlErrorDetails()
        when (kind) {
            ControlErrorKind.UPDATE -> recordLastResult(ControlLastResult.UPDATE_FAILED)
            ControlErrorKind.START_SERVICE,
            ControlErrorKind.STOP_SERVICE,
            ControlErrorKind.SERVICE_OPERATION,
            -> recordLastResult(ControlLastResult.SERVICE_FAILED)
            ControlErrorKind.INITIALIZATION -> Unit
        }
        savedStateHandle[KEY_DIALOG_KIND] = ControlDialogKind.ERROR.name
        savedStateHandle[KEY_ERROR_KIND] = kind.name
        clearPersistedRollback()
        clearPersistedPurge()
        savedStateHandle.persistControlErrorDetails(safeDetails)
        _uiState.update {
            it.copy(
                pendingDialog = ControlDialogKind.ERROR,
                updateRelease = null,
                errorDialog = ControlErrorDialog(kind, safeDetails),
                fullRollback = FullRollbackUiState.Idle,
                modulePurge = ModulePurgeUiState.Idle,
            )
        }
    }

    private fun clearPersistedDialog() {
        savedStateHandle.remove<String>(KEY_DIALOG_KIND)
        clearPersistedError()
        clearPersistedRollback()
        clearPersistedPurge()
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_IN_PROGRESS)
        savedStateHandle.remove<Boolean>(KEY_PURGE_IN_PROGRESS)
    }

    private fun clearPersistedError() {
        savedStateHandle.remove<String>(KEY_ERROR_KIND)
        savedStateHandle.remove<Int>(KEY_ERROR_DETAIL_RESOURCE)
        savedStateHandle.remove<String>(KEY_ERROR_DETAIL_DYNAMIC)
    }

    private fun clearPersistedRollback() {
        savedStateHandle.remove<String>(KEY_ROLLBACK_OUTCOME)
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_ROLLED_BACK)
        savedStateHandle.remove<Boolean>(KEY_ROLLBACK_REBOOT_REQUIRED)
        savedStateHandle.remove<String>(KEY_ROLLBACK_DIAGNOSTIC)
    }

    private fun clearPersistedPurge() {
        savedStateHandle.remove<String>(KEY_PURGE_OUTCOME)
        savedStateHandle.remove<Boolean>(KEY_PURGE_REBOOT_REQUIRED)
        savedStateHandle.remove<Boolean>(KEY_PURGE_REMOVAL_FENCE)
        savedStateHandle.remove<String>(KEY_PURGE_DIAGNOSTIC)
    }

    private fun recordLastResult(result: ControlLastResult) {
        savedStateHandle[KEY_LAST_RESULT] = result.name
        _uiState.update { it.copy(lastResult = result) }
    }

    private fun revalidateRestoredUpdateDialog() {
        launchUpdateCheck(
            showUpToDateMessage = false,
            expectedDialog = ControlDialogKind.UPDATE,
        )
    }

    private fun loadInitialState() {
        viewModelScope.launch {
            var detectedRootState: ServiceLifecycleController.RootAccessState? = null
            try {
                val rootAccess = ServiceLifecycleController.checkRootAccess()
                detectedRootState = rootAccess.state
                val environment = if (rootAccess.granted) {
                    moduleRepository.reconcileEnvironment()
                        ?: throw EnvironmentProbeException()
                } else {
                    null
                }
                val stableModuleConfig =
                    environment?.activeState in setOf(
                            ModuleInstallState.READY,
                            ModuleInstallState.DISABLED,
                        )
                val runtimeConfig = if (stableModuleConfig) {
                    RuntimeConfigStore.readCore()
                } else {
                    null
                }
                if (runtimeConfig != null && runtimeConfig !is RuntimeConfigReadResult.Valid) {
                    _uiState.update {
                        it.copy(moduleDiagnostic = runtimeConfig.diagnosticText())
                    }
                    throw EnvironmentProbeException()
                }
                val coreValues = runtimeConfig?.values.orEmpty()
                if (stableModuleConfig && coreValues.isEmpty()) throw EnvironmentProbeException()
                val unsupportedWifiOnlyWasEnabled = coreValues["wifi_only"] == "1"
                var runtimeMutationDiagnostic: String? = null
                val wifiOnlyNormalized = if (!unsupportedWifiOnlyWasEnabled) {
                    true
                } else {
                    try {
                        ModuleMutationCoordinator.withNonCancellableMutation {
                            RuntimeConfigStore.upsertCoreValue("wifi_only", "0").let { result ->
                                runtimeMutationDiagnostic = result.diagnosticTextOrNull()
                                result.isSuccess
                            }
                        }
                    } catch (_: ModuleMutationCoordinator.MutationBlockedException) {
                        false
                    }
                }
                val showQuicBanner = withContext(Dispatchers.IO) {
                    !prefs.getBoolean("quic_banner_dismissed", false)
                }

                _uiState.update { state ->
                    // Initialization can still be in flight when a restored purge commits, and its
                    // environment is the pre-purge one it probed. Same gate as every status read.
                    state.withModuleStatusPublication {
                        copy(
                            hasRootAccess = rootAccess.granted,
                            rootAccessState = rootAccess.state,
                            moduleInstallState = environment?.activeState
                                ?: ModuleInstallState.UNKNOWN,
                            pendingModuleState = environment?.pendingState
                                ?: PendingModuleState.NONE,
                            moduleMutationState = ModuleMutationState.IDLE,
                            nfqueueSupported = environment?.nfqueueSupported == true,
                            moduleVersion = environment?.displayedVersion.orEmpty(),
                            autostart = coreValues["autostart"] != "0",
                            hasAuthoritativeRuntimeSettings = stableModuleConfig,
                            moduleDiagnostic = runtimeMutationDiagnostic,
                            showQuicBanner = showQuicBanner,
                        )
                    }
                }

                if (!wifiOnlyNormalized) {
                    publishMessage(UiText.Resource(R.string.control_wifi_only_disable_failed))
                }

                if (rootAccess.granted) checkStatus()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                val rootState = detectedRootState
                    ?: ServiceLifecycleController.RootAccessState.SHELL_FAILURE
                _uiState.update { current ->
                    current.withModuleStatusPublication {
                        copy(
                            hasRootAccess =
                                rootState == ServiceLifecycleController.RootAccessState.GRANTED,
                            rootAccessState = rootState,
                            hasAuthoritativeRuntimeSettings = false,
                            status = if (
                                rootState == ServiceLifecycleController.RootAccessState.GRANTED
                            ) {
                                ControlStatus.UNAVAILABLE
                            } else {
                                rootState.toControlStatus()
                            },
                        )
                    }
                }
                showErrorDialog(
                    kind = ControlErrorKind.INITIALIZATION,
                    details = if (error is EnvironmentProbeException) {
                        _uiState.value.moduleDiagnostic
                            ?.let { UiText.Dynamic(it) }
                            ?: UiText.Resource(R.string.control_environment_probe_failed)
                    } else UiText.Resource(R.string.control_unknown_error),
                )
            } finally {
                if (_uiState.value.pendingDialog == ControlDialogKind.UPDATE) {
                    revalidateRestoredUpdateDialog()
                }
                initializationFinished.set(true)
            }
        }
    }

    private suspend fun refreshServiceStatusOnce(): ModuleMutationState? {
        if (exclusiveActionInProgress.get()) return null
        return try {
            checkStatus().moduleMutationState
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            _uiState.update { current ->
                current.withModuleStatusPublication {
                    copy(
                        isRunning = false,
                        status = ControlStatus.UNAVAILABLE,
                        iptablesActive = false,
                    )
                }
            }
            null
        }
    }

    private data class ServiceSnapshot(
        val isRunning: Boolean,
        val canStopService: Boolean,
        val moduleMutationState: ModuleMutationState,
    )

    /** What every status read reports once the module this session erased is gone for good. */
    private fun purgedServiceSnapshot(): ServiceSnapshot = ServiceSnapshot(
        isRunning = false,
        canStopService = false,
        moduleMutationState = ModuleMutationState.IDLE,
    )

    private suspend fun checkStatus(): ServiceSnapshot {
        return refreshStatus()
    }

    /**
     * Status recovery acquires ModuleMutationCoordinator before the lifecycle controller. Never
     * wrap this method in a view-model mutex: settings saves intentionally keep the module
     * coordinator while restarting, and a reverse wait here would deadlock observation against saves.
     * Installation metadata is retained from the initialization/publication boundary; an ordinary
     * status read consumes only the module's typed lifecycle snapshot.
     * Once this session erased the module there is nothing left to read — the module's own status
     * script went with it — so the read is skipped outright and every publication below stays
     * gated on [withModuleStatusPublication] for the read that was already in flight.
     *
     * [observed] is a status the caller already holds under the lifecycle lock — the typed receipt
     * `zapret-start.sh`/`zapret-stop.sh` printed for the very transition being published. It is the
     * authority the lifecycle boundary already verified against the expected state, so re-reading it
     * would spend another `zapret-status.sh` process (~330 ms on device) to learn what the receipt
     * already said, and would answer about a moment strictly later than the one being reported.
     * Passing null is an ordinary observation and runs the status process itself.
     */
    private suspend fun refreshStatus(
        observed: ServiceLifecycleController.ServiceStatus? = null,
    ): ServiceSnapshot {
        if (_uiState.value.modulePurgeCompleted) return purgedServiceSnapshot()
        val refreshId = statusRefreshSequence.incrementAndGet()
        val cachedEnvironment = _uiState.value
        val environment = ModuleEnvironmentSnapshot(
            activeState = cachedEnvironment.moduleInstallState,
            pendingState = cachedEnvironment.pendingModuleState,
            nfqueueSupported = cachedEnvironment.nfqueueSupported,
            activeVersion = cachedEnvironment.moduleVersion,
        )

        val statusWithoutQuery = environment.serviceAccess.statusWithoutQuery()
        if (statusWithoutQuery != null) {
            if (refreshId == statusRefreshSequence.get()) {
                _uiState.update { current ->
                    current.withModuleStatusPublication {
                        copy(
                            isRunning = false,
                            canStopService = false,
                            status = statusWithoutQuery,
                            networkType = UiText.Resource(
                                networkStatsManager.getNetworkType().labelRes,
                            ),
                            serviceUptime = null,
                            iptablesActive = false,
                            nfqueueRulesCount = 0,
                            processStats = ProcessStats(),
                            hasRootAccess = cachedEnvironment.hasRootAccess,
                            rootAccessState = cachedEnvironment.rootAccessState,
                            moduleInstallState = environment.activeState,
                            pendingModuleState = environment.pendingState,
                            moduleMutationState = ModuleMutationState.IDLE,
                            // No status script answered, so the installation authority is the only
                            // evidence of a pending removal there is.
                            moduleRemovalPending =
                                environment.activeState == ModuleInstallState.REMOVAL_PENDING,
                            moduleVersion = environment.displayedVersion,
                            nfqueueSupported = environment.nfqueueSupported,
                            hasAuthoritativeRuntimeSettings = false,
                        )
                    }
                }
            }
            return ServiceSnapshot(
                isRunning = false,
                canStopService = false,
                moduleMutationState = ModuleMutationState.IDLE,
            )
        }

        val serviceStatus = observed ?: ServiceLifecycleController.getStatus()
        val lifecycleMutationState = serviceStatus.lifecycleState.toModuleMutationState()
        if (lifecycleMutationState != ModuleMutationState.IDLE) {
            val current = _uiState.value
            val publishResult = refreshId == statusRefreshSequence.get()
            val currentNetworkType = UiText.Resource(
                networkStatsManager.getNetworkType().labelRes,
            )
            if (publishResult) {
                _uiState.update { latest ->
                    latest.withModuleStatusPublication {
                        copy(
                            status = projectedControlStatus(
                                serviceStatus = serviceStatus,
                                canStopService = current.canStopService,
                            ),
                            hasRootAccess = serviceStatus.rootGranted,
                            rootAccessState = serviceStatus.rootAccessState,
                            moduleInstallState = environment.activeState,
                            pendingModuleState = environment.pendingState,
                            moduleMutationState = lifecycleMutationState,
                            moduleRemovalPending = serviceStatus.uninstallTombstone,
                            moduleVersion = environment.displayedVersion,
                            nfqueueSupported = environment.nfqueueSupported,
                            hasAuthoritativeRuntimeSettings = false,
                            moduleDiagnostic = projectedLifecycleDiagnostic(serviceStatus),
                            networkType = currentNetworkType,
                        )
                    }
                }
            }
            if (
                publishResult &&
                screenStarted &&
                lifecycleMutationState == ModuleMutationState.IN_PROGRESS
            ) {
                lifecycleSettlementObserver.ensureObserving()
            }
            return ServiceSnapshot(
                isRunning = current.isRunning,
                canStopService = current.canStopService,
                moduleMutationState = lifecycleMutationState,
            )
        }
        val networkType = networkStatsManager.getNetworkType()
        val isRunning = confirmedRunning(serviceStatus)
        val effectiveRulesCount = serviceStatus.nfqueueRulesCount
        val canStopService = serviceStatus.hasOwnedState
        val processPid = serviceStatus.pid.takeIf {
            serviceStatus.processRunning && serviceStatus.pidVerified && it.matches(Regex("[1-9][0-9]*"))
        }.orEmpty()

        val processStats = if (serviceStatus.processRunning && processPid.isNotEmpty()) {
            moduleRepository.readProcessMetrics(processPid).let { metrics ->
                ProcessStats(
                    pid = processPid,
                    memory = metrics.memoryKb.takeIf(String::isNotBlank)?.let { "$it KB" }.orEmpty(),
                    threads = metrics.threads,
                )
            }
        } else ProcessStats()
        val serviceUptime = serviceStatus.serviceUptimeAnchor()

        val status = projectedControlStatus(
            serviceStatus = serviceStatus,
            canStopService = canStopService,
        )
        if (refreshId == statusRefreshSequence.get()) {
            _uiState.update { current ->
                current.withModuleStatusPublication {
                    copy(
                        isRunning = isRunning,
                        canStopService = canStopService,
                        status = status,
                        serviceUptime = serviceUptime,
                        networkType = UiText.Resource(networkType.labelRes),
                        iptablesActive = serviceStatus.iptablesActive,
                        nfqueueRulesCount = effectiveRulesCount,
                        processStats = processStats,
                        hasRootAccess = serviceStatus.rootGranted,
                        rootAccessState = serviceStatus.rootAccessState,
                        moduleInstallState = environment.activeState,
                        pendingModuleState = environment.pendingState,
                        moduleMutationState = lifecycleMutationState,
                        moduleRemovalPending = serviceStatus.uninstallTombstone,
                        moduleVersion = environment.displayedVersion,
                        nfqueueSupported = environment.nfqueueSupported,
                        hasAuthoritativeRuntimeSettings = current.hasAuthoritativeRuntimeSettings &&
                            environment.activeState == ModuleInstallState.READY &&
                            lifecycleMutationState == ModuleMutationState.IDLE,
                        moduleDiagnostic = projectedLifecycleDiagnostic(serviceStatus)
                            ?: current.moduleDiagnostic.takeUnless {
                                serviceStatus.metadataComplete &&
                                    current.hasAuthoritativeRuntimeSettings
                            },
                    )
                }
            }
        }

        return ServiceSnapshot(
            isRunning = isRunning,
            canStopService = canStopService,
            moduleMutationState = lifecycleMutationState,
        )
    }

    fun refreshStatusManually() {
        if (!screenStarted) return
        val state = _uiState.value
        if (state.moduleInstallState == ModuleInstallState.UNKNOWN || !state.hasRootAccess) {
            if (!initializationFinished.get()) return
            initializationRequested.set(false)
            initializationFinished.set(false)
            ensureInitialized()
            return
        }
        viewModelScope.launch {
            refreshServiceStatusOnce()
        }
    }

    fun toggleService() {
        if (!exclusiveActionInProgress.compareAndSet(false, true)) return
        toggleInProgress.set(true)
        if (_uiState.value.pendingDialog != null) {
            toggleInProgress.set(false)
            exclusiveActionInProgress.set(false)
            return
        }
        if (
            _uiState.value.isUpdating ||
            _uiState.value.isCheckingForUpdates ||
            _uiState.value.isSavingSettings || settingMutationInProgress.get() ||
            _uiState.value.isFullRollbackInProgress ||
            _uiState.value.isModulePurgeInProgress ||
            ServiceLifecycleController.isAppUpdateInProgress() ||
            ServiceLifecycleController.isFullRollbackInProgress() ||
            ModulePurgeController.isInProgress()
        ) {
            toggleInProgress.set(false)
            exclusiveActionInProgress.set(false)
            publishMessage(UiText.Resource(R.string.control_wait_operation_finish))
            return
        }
        _uiState.update { it.copy(isToggling = true) }

        viewModelScope.launch {
            try {
                // The direction is the one the user acted on: the button they pressed was rendered
                // from this very state. A leading status process here would spend ~330 ms to
                // re-derive it, and `perform` immediately takes its own observation under the
                // lifecycle lock anyway — the only one that can decide anything, because only it
                // excludes a concurrent owner. Either way the module is idempotent: a start it
                // already satisfies and a stop with nothing left to stop both commit as no-ops.
                val shouldStop = _uiState.value.canStopService
                if (!shouldStop && rejectUnavailableModuleOperation()) return@launch
                val lifecycleResult = if (shouldStop) {
                    ServiceLifecycleController.stop()
                } else {
                    ServiceLifecycleController.start()
                }
                val verifiedState = refreshStatus(lifecycleResult.status)

                val verified = if (shouldStop) !verifiedState.canStopService else verifiedState.isRunning
                if (lifecycleResult.success && verified) {
                    val outcome = if (shouldStop) {
                        stoppedServiceResult(lifecycleResult.status.rulesetVerified)
                    } else {
                        ControlLastResult.SERVICE_STARTED
                    }
                    recordLastResult(outcome)
                    publishMessage(UiText.Resource(outcome.messageRes))
                    if (!shouldStop) {
                        serviceEventBus.notifyServiceRestarted(ServiceEventSource.CONTROL)
                    }
                } else {
                    val diagnostic = lifecycleResult.diagnosticText()
                        .ifBlank { readServiceFailureLogs() }
                    val details = if (diagnostic.isBlank()) {
                        UiText.Resource(R.string.control_service_expected_state_error)
                    } else {
                        UiText.Dynamic(diagnostic)
                    }
                    showErrorDialog(
                        kind = if (shouldStop) {
                            ControlErrorKind.STOP_SERVICE
                        } else {
                            ControlErrorKind.START_SERVICE
                        },
                        details = details,
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                showErrorDialog(
                    kind = ControlErrorKind.SERVICE_OPERATION,
                    details = UiText.Resource(R.string.control_service_expected_state_error),
                )
            } finally {
                _uiState.update { it.copy(isToggling = false) }
                toggleInProgress.set(false)
                exclusiveActionInProgress.set(false)
            }
        }
    }

    private suspend fun readServiceFailureLogs(): String = withContext(Dispatchers.IO) {
        when (val result = logRepository.readFailureTail()) {
            is ProtectedTextRead.Content -> result.value.takeLast(MAX_ERROR_DETAIL_LENGTH)
            ProtectedTextRead.Absent,
            ProtectedTextRead.Failed,
            -> ""
        }
    }

    fun setAutostart(enabled: Boolean) {
        if (rejectConflictingOperation()) return
        if (rejectUnavailableSettingMutation()) return
        if (_uiState.value.autostart == enabled) return
        launchSettingMutation(R.string.control_autostart_save_failed) {
            handleRuntimeMutation(
                RuntimeConfigStore.upsertCoreValue(
                    "autostart",
                    if (enabled) "1" else "0",
                ),
            ).also { success ->
                if (success) _uiState.update { it.copy(autostart = enabled) }
            }
        }
    }

    private fun handleRuntimeMutation(result: RuntimeConfigMutationResult): Boolean {
        result.diagnosticTextOrNull()?.let { diagnostic ->
            _uiState.update { it.copy(moduleDiagnostic = diagnostic) }
        }
        return result.isSuccess
    }

    private fun launchSettingMutation(
        @StringRes failureMessage: Int,
        block: suspend () -> Boolean,
    ) {
        if (!exclusiveActionInProgress.compareAndSet(false, true)) {
            publishMessage(UiText.Resource(R.string.control_wait_operation_finish))
            return
        }
        settingMutationInProgress.set(true)
        _uiState.update { it.copy(isSavingSettings = true) }
        viewModelScope.launch {
            try {
                val succeeded = ModuleMutationCoordinator.withNonCancellableMutation(block)
                if (!succeeded) {
                    publishMessage(UiText.Resource(failureMessage))
                }
            } catch (_: ModuleMutationCoordinator.MutationBlockedException) {
                publishMessage(UiText.Resource(R.string.control_module_update_in_progress))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                publishMessage(UiText.Resource(failureMessage))
            } finally {
                settingMutationInProgress.set(false)
                _uiState.update { it.copy(isSavingSettings = false) }
                exclusiveActionInProgress.set(false)
            }
        }
    }

    fun dismissQuicBanner() {
        prefs.edit { putBoolean("quic_banner_dismissed", true) }
        _uiState.update { it.copy(showQuicBanner = false) }
    }

    fun checkForUpdates() {
        if (_uiState.value.pendingDialog != null) return
        if (
            _uiState.value.status in setOf(
                ControlStatus.CHECKING,
                ControlStatus.LIFECYCLE_BUSY,
            ) ||
            _uiState.value.isToggling ||
            _uiState.value.isUpdating ||
            _uiState.value.isSavingSettings || settingMutationInProgress.get() ||
            _uiState.value.isFullRollbackInProgress ||
            _uiState.value.isModulePurgeInProgress ||
            ServiceLifecycleController.isAppUpdateInProgress() ||
            ServiceLifecycleController.isFullRollbackInProgress() ||
            ModulePurgeController.isInProgress()
        ) {
            publishMessage(UiText.Resource(R.string.control_wait_operation_finish))
            return
        }
        launchUpdateCheck(showUpToDateMessage = true, expectedDialog = null)
    }

    private fun launchUpdateCheck(
        showUpToDateMessage: Boolean,
        expectedDialog: ControlDialogKind?,
    ) {
        if (!exclusiveActionInProgress.compareAndSet(false, true)) {
            if (showUpToDateMessage) {
                publishMessage(UiText.Resource(R.string.control_wait_operation_finish))
            }
            return
        }
        if (!updateCheckInProgress.compareAndSet(false, true)) {
            exclusiveActionInProgress.set(false)
            return
        }
        _uiState.update { it.copy(isCheckingForUpdates = true) }
        viewModelScope.launch {
            try {
                checkForUpdatesInternal(showUpToDateMessage, expectedDialog)
            } finally {
                finishUpdateCheckState()
            }
        }
    }

    private fun finishUpdateCheckState() {
        _uiState.update { it.copy(isCheckingForUpdates = false) }
        updateCheckInProgress.set(false)
        exclusiveActionInProgress.set(false)
    }

    private fun rejectUnavailableModuleOperation(): Boolean {
        if (_uiState.value.isModuleOperational && _uiState.value.hasRootAccess) return false
        publishMessage(UiText.Resource(R.string.control_module_not_ready))
        return true
    }

    private fun rejectUnavailableSettingMutation(): Boolean {
        if (_uiState.value.canEditSettings) return false
        publishMessage(UiText.Resource(R.string.control_module_not_ready))
        return true
    }

    private fun rejectConflictingOperation(): Boolean {
        val state = _uiState.value
        if (state.pendingDialog != null) return true
        if (!state.isCheckingForUpdates && !state.isToggling && !state.isUpdating &&
            !state.isSavingSettings && !state.isFullRollbackInProgress &&
            !state.isModulePurgeInProgress &&
            !toggleInProgress.get() && !settingMutationInProgress.get() &&
            !updateCheckInProgress.get() && !exclusiveActionInProgress.get() &&
            !ServiceLifecycleController.isAppUpdateInProgress() &&
            !ServiceLifecycleController.isFullRollbackInProgress() &&
            !ModulePurgeController.isInProgress()
        ) return false
        publishMessage(UiText.Resource(R.string.control_wait_operation_finish))
        return true
    }

    private suspend fun checkForUpdatesInternal(
        showUpToDateMessage: Boolean,
        expectedDialog: ControlDialogKind?,
    ) {
        val state = _uiState.value
        val comparableModuleVersion = state.moduleVersion.takeIf {
            it.isNotBlank() && (
                state.moduleInstallState in setOf(
                    ModuleInstallState.READY,
                    ModuleInstallState.DISABLED,
                ) || state.pendingModuleState == PendingModuleState.READY
                )
        }
        val result = updateManager.checkForUpdates(
            currentModuleVersion = comparableModuleVersion,
            allowModuleUpdate = state.hasRootAccess &&
                state.moduleMutationState == ModuleMutationState.IDLE &&
                state.pendingModuleState == PendingModuleState.NONE &&
                state.moduleInstallState.allowsModuleUpdate,
        )
        if (
            _uiState.value.isFullRollbackInProgress ||
            _uiState.value.isModulePurgeInProgress ||
            ServiceLifecycleController.isFullRollbackInProgress() ||
            ModulePurgeController.isInProgress()
        ) {
            return
        }
        if (_uiState.value.pendingDialog != expectedDialog) return
        when (result) {
            is UpdateManager.UpdateResult.Available -> showUpdateDialog(result.release)
            is UpdateManager.UpdateResult.UpToDate -> {
                if (_uiState.value.pendingDialog == ControlDialogKind.UPDATE) dismissDialog()
                if (showUpToDateMessage) {
                    publishMessage(UiText.Resource(R.string.control_app_up_to_date))
                }
            }
            is UpdateManager.UpdateResult.Error -> {
                if (_uiState.value.pendingDialog == ControlDialogKind.UPDATE) dismissDialog()
                publishMessage(result.reason.toUiText())
            }
        }
    }

    fun updateAll(release: UpdateManager.Release) {
        if (_uiState.value.pendingDialog != ControlDialogKind.UPDATE ||
            _uiState.value.updateRelease != release
        ) return
        if (!exclusiveActionInProgress.compareAndSet(false, true)) {
            publishMessage(UiText.Resource(R.string.control_wait_operation_finish))
            return
        }
        if (
            _uiState.value.isToggling ||
            _uiState.value.isSavingSettings ||
            settingMutationInProgress.get() ||
            updateCheckInProgress.get() ||
            _uiState.value.isFullRollbackInProgress ||
            _uiState.value.isModulePurgeInProgress ||
            ServiceLifecycleController.isFullRollbackInProgress() ||
            ModulePurgeController.isInProgress()
        ) {
            exclusiveActionInProgress.set(false)
            publishMessage(UiText.Resource(R.string.control_wait_operation_finish))
            return
        }
        if (!ServiceLifecycleController.tryBeginAppUpdate()) {
            exclusiveActionInProgress.set(false)
            publishMessage(UiText.Resource(R.string.control_wait_operation_finish))
            return
        }
        _uiState.update {
            it.copy(
                isUpdating = true,
                updateProgress = 0f,
                updateStatus = UiText.Resource(R.string.update_in_progress),
            )
        }

        viewModelScope.launch {
            val result = try {
                Result.success(withContext(Dispatchers.IO) {
                    // Module installation acquires the shared lifecycle lock inside UpdateManager.
                    updateManager.updateAll(release) { progress ->
                        _uiState.update {
                            it.copy(
                                updateProgress = progress.normalizedFraction,
                                updateStatus = progress.toUiText(),
                            )
                        }
                    }
                })
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                Result.failure(error)
            } finally {
                _uiState.update {
                    it.copy(isUpdating = false, updateProgress = 0f, updateStatus = null)
                }
                ServiceLifecycleController.finishAppUpdate()
                exclusiveActionInProgress.set(false)
            }

            result.onSuccess { report ->
                when (val terminal = report.toTerminalOutcome()) {
                    is UpdateTerminalOutcome.Partial -> {
                        val failureText = terminal.failure?.toUiText()
                        dismissDialog()
                        recordLastResult(
                            if (terminal.requiresReboot) {
                                ControlLastResult.UPDATE_PARTIAL_REBOOT
                            } else {
                                ControlLastResult.UPDATE_PARTIAL
                            },
                        )
                        publishMessage(
                            failureText?.let {
                                UiText.resource(
                                    if (terminal.requiresReboot) {
                                        R.string.control_update_partial_reboot_details
                                    } else {
                                        R.string.control_update_partial_details
                                    },
                                    it,
                                )
                            } ?: UiText.Resource(
                                if (terminal.requiresReboot) {
                                    R.string.control_update_partial_reboot
                                } else {
                                    R.string.control_update_partial
                                },
                            ),
                        )
                        if (!terminal.requiresReboot) {
                            refreshStatusAfterUpdate()
                        }
                    }
                    is UpdateTerminalOutcome.Failed -> showErrorDialog(
                        kind = ControlErrorKind.UPDATE,
                        details = terminal.failure.toUiText(),
                    )
                    is UpdateTerminalOutcome.ApkInstallerPending -> {
                        dismissDialog()
                        recordLastResult(
                            if (terminal.requiresReboot) {
                                ControlLastResult.UPDATE_APK_PENDING_REBOOT
                            } else {
                                ControlLastResult.UPDATE_APK_PENDING
                            },
                        )
                        publishMessage(
                            UiText.Resource(
                                if (terminal.requiresReboot) {
                                    R.string.control_update_apk_pending_reboot
                                } else {
                                    R.string.control_update_apk_pending
                                },
                            ),
                        )
                    }
                    is UpdateTerminalOutcome.Installed -> {
                        dismissDialog()
                        val requiresReboot = terminal.requiresReboot
                        recordLastResult(
                            if (requiresReboot) {
                                ControlLastResult.UPDATE_REBOOT_REQUIRED
                            } else {
                                ControlLastResult.UPDATE_COMPLETED
                            },
                        )
                        publishMessage(
                            UiText.Resource(
                                if (requiresReboot) {
                                    R.string.control_update_installed_reboot
                                } else {
                                    R.string.control_update_completed
                                },
                            ),
                        )
                        if (!requiresReboot) {
                            refreshStatusAfterUpdate()
                        }
                    }
                    UpdateTerminalOutcome.Invalid -> showErrorDialog(
                        kind = ControlErrorKind.UPDATE,
                        details = UiText.Resource(R.string.control_unknown_error),
                    )
                }
            }.onFailure {
                showErrorDialog(
                    kind = ControlErrorKind.UPDATE,
                    details = UiText.Resource(R.string.control_unknown_error),
                )
            }
        }
    }

    private suspend fun refreshStatusAfterUpdate() {
        delay(UPDATE_STATUS_REFRESH_DELAY_MS)
        if (screenStarted) refreshServiceStatusOnce()
    }

}

internal fun sanitizedBoundedUiDiagnostic(text: String): String =
    redactedBoundedLogShareText(text).takeLast(MAX_ERROR_DETAIL_LENGTH)

internal fun restoreControlLastResult(savedStateHandle: SavedStateHandle): ControlLastResult? {
    return savedStateHandle.restoreEnumNameOrRemove(KEY_LAST_RESULT)
}

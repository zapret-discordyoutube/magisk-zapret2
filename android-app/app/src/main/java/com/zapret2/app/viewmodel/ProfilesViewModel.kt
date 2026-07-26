package com.zapret2.app.viewmodel

import androidx.annotation.StringRes
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.zapret2.app.data.PresetDurableOutcome
import com.zapret2.app.data.PresetMutationOutcome
import com.zapret2.app.data.PresetProfileDocument
import com.zapret2.app.data.PresetStateRevision
import com.zapret2.app.data.ProfileListEntry
import com.zapret2.app.data.ProfileMutationResult
import com.zapret2.app.data.ProfileRepository
import com.zapret2.app.data.ServiceEventBus
import com.zapret2.app.data.ServiceEventSource
import com.zapret2.app.data.StrategyCatalogEntry
import com.zapret2.app.R
import com.zapret2.app.ui.UiText
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject

data class ProfileSelectorTarget(
    val profileIndex: Int,
    val selectorIndex: Int,
)

/**
 * What the screen is waiting for, and therefore what its modal overlay is allowed to claim.
 *
 * Three of the four are pure reads. Announcing "validating and saving" for any of them told the
 * user — and, through the overlay's polite live region, TalkBack — that a privileged write to the
 * module was in flight when nothing had been written at all; entering the screen did it every time,
 * because [LOAD] runs on first composition.
 */
enum class ProfilesOperation(@param:StringRes val loadingTextRes: Int) {
    LOAD(R.string.profiles_loading),
    STRATEGY_CATALOG(R.string.profiles_loading_strategies),
    SELECTOR_LISTS(R.string.profiles_loading_lists),
    SAVE(R.string.profiles_saving),
}

data class ProfilesUiState(
    val document: PresetProfileDocument? = null,
    val operation: ProfilesOperation? = null,
    val error: Boolean = false,
    val message: UiText? = null,
    val strategyProfileIndex: Int? = null,
    val strategies: List<StrategyCatalogEntry> = emptyList(),
    val renameProfileIndex: Int? = null,
    val renameDraft: String = "",
    val selectorTarget: ProfileSelectorTarget? = null,
    val listEntries: List<ProfileListEntry> = emptyList(),
) {
    val isLoading: Boolean
        get() = operation != null
    val loadingText: UiText?
        get() = operation?.let { UiText.resource(it.loadingTextRes) }
}

@HiltViewModel
class ProfilesViewModel @Inject constructor(
    private val repository: ProfileRepository,
    private val serviceEventBus: ServiceEventBus,
    private val presetStateRevision: PresetStateRevision,
) : ViewModel() {
    private val busy = AtomicBoolean(false)
    private val _uiState = MutableStateFlow(ProfilesUiState())
    val uiState: StateFlow<ProfilesUiState> = _uiState.asStateFlow()
    private var screenStarted = false
    private var reloadPending = false
    private var observedPresetRevision = presetStateRevision.revision.value

    init {
        viewModelScope.launch {
            presetStateRevision.revision.collect { revision ->
                if (revision != observedPresetRevision) {
                    observedPresetRevision = revision
                    invalidateProjection()
                }
            }
        }
    }

    /**
     * A restored navigation destination is not an authoritative cache boundary.
     *
     * Every visible entry reads runtime.ini and the selected TXT again through the repository's
     * bounded active-snapshot path. No catalog enumeration or preset qualification is involved.
     */
    fun onScreenStarted() {
        if (screenStarted) return
        screenStarted = true
        invalidateProjection()
    }

    fun onScreenStopped() {
        screenStarted = false
    }

    fun load() {
        invalidateProjection(loadWhileStopped = true)
    }

    private fun invalidateProjection(loadWhileStopped: Boolean = false) {
        reloadPending = true
        _uiState.update {
            it.copy(
                document = null,
                operation = if (screenStarted || loadWhileStopped) ProfilesOperation.LOAD else null,
                error = false,
                strategyProfileIndex = null,
                strategies = emptyList(),
                renameProfileIndex = null,
                renameDraft = "",
                selectorTarget = null,
                listEntries = emptyList(),
            )
        }
        if (screenStarted || loadWhileStopped) startProjectionRead()
    }

    private fun startProjectionRead() {
        if (!reloadPending || !busy.compareAndSet(false, true)) return
        reloadPending = false
        _uiState.update { it.copy(operation = ProfilesOperation.LOAD, error = false) }
        viewModelScope.launch {
            val revisionAtReadStart = presetStateRevision.revision.value
            try {
                val document = repository.loadActive()
                if (revisionAtReadStart == presetStateRevision.revision.value) {
                    _uiState.update {
                        it.copy(document = document, operation = null, error = document == null)
                    }
                } else {
                    reloadPending = true
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                if (revisionAtReadStart == presetStateRevision.revision.value) {
                    _uiState.update { it.copy(document = null, operation = null, error = true) }
                } else {
                    reloadPending = true
                }
            } finally {
                busy.set(false)
                if (reloadPending && screenStarted) startProjectionRead()
            }
        }
    }

    fun setEnabled(profileIndex: Int, enabled: Boolean) = mutate { document ->
        repository.setEnabled(document, profileIndex, enabled)
    }

    fun openRename(profileIndex: Int) {
        if (busy.get()) return
        val profile = _uiState.value.document?.profiles?.getOrNull(profileIndex) ?: return
        _uiState.update { it.copy(renameProfileIndex = profileIndex, renameDraft = profile.name) }
    }

    fun updateRenameDraft(value: String) {
        _uiState.update { it.copy(renameDraft = value.take(MAX_PROFILE_NAME_CHARS)) }
    }

    fun closeRename() {
        if (busy.get()) return
        _uiState.update { it.copy(renameProfileIndex = null, renameDraft = "") }
    }

    fun saveRename() {
        val state = _uiState.value
        val index = state.renameProfileIndex ?: return
        val name = state.renameDraft.trim()
        if (name.isEmpty()) return
        _uiState.update { it.copy(renameProfileIndex = null, renameDraft = "") }
        mutate { repository.rename(it, index, name) }
    }

    fun move(profileIndex: Int, delta: Int) {
        val document = _uiState.value.document ?: return
        val target = profileIndex + delta
        if (target !in document.profiles.indices) return
        mutate { repository.move(it, profileIndex, target) }
    }

    fun openStrategyPicker(profileIndex: Int) {
        val profile = _uiState.value.document?.profiles?.getOrNull(profileIndex) ?: return
        val scope = profile.catalogScope ?: run {
            _uiState.update { it.copy(message = UiText.resource(R.string.profiles_scope_ambiguous)) }
            return
        }
        if (!busy.compareAndSet(false, true)) return
        _uiState.update { it.copy(operation = ProfilesOperation.STRATEGY_CATALOG) }
        viewModelScope.launch {
            try {
                val items = repository.loadStrategies(scope, _uiState.value.document?.declaredBlobs.orEmpty())
                _uiState.update {
                    it.copy(
                        operation = null,
                        strategyProfileIndex = profileIndex.takeIf { items != null },
                        strategies = items.orEmpty(),
                        message = if (items == null) UiText.resource(R.string.profiles_catalog_unavailable) else null,
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                _uiState.update {
                    it.copy(
                        operation = null,
                        strategyProfileIndex = null,
                        strategies = emptyList(),
                        message = UiText.resource(R.string.profiles_catalog_unavailable),
                    )
                }
            } finally {
                busy.set(false)
            }
        }
    }

    fun openSelectorPicker(profileIndex: Int, selectorIndex: Int) {
        val profile = _uiState.value.document?.profiles?.getOrNull(profileIndex) ?: return
        val selector = profile.selectors.getOrNull(selectorIndex) ?: return
        if (!busy.compareAndSet(false, true)) return
        _uiState.update { it.copy(operation = ProfilesOperation.SELECTOR_LISTS) }
        viewModelScope.launch {
            try {
                val items = repository.loadListEntries(selector)
                _uiState.update {
                    it.copy(
                        operation = null,
                        selectorTarget = ProfileSelectorTarget(profileIndex, selectorIndex).takeIf { items != null },
                        listEntries = items.orEmpty(),
                        message = if (items == null) UiText.resource(R.string.profiles_lists_unavailable) else null,
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                _uiState.update {
                    it.copy(
                        operation = null,
                        selectorTarget = null,
                        listEntries = emptyList(),
                        message = UiText.resource(R.string.profiles_lists_unavailable),
                    )
                }
            } finally {
                busy.set(false)
            }
        }
    }

    fun closeSelectorPicker() {
        if (busy.get()) return
        _uiState.update { it.copy(selectorTarget = null, listEntries = emptyList()) }
    }

    fun selectList(entry: ProfileListEntry) {
        val target = _uiState.value.selectorTarget ?: return
        _uiState.update { it.copy(selectorTarget = null, listEntries = emptyList()) }
        mutate {
            repository.replaceSelector(
                it,
                target.profileIndex,
                target.selectorIndex,
                entry.relativePath,
            )
        }
    }

    fun closeStrategyPicker() {
        if (busy.get()) return
        _uiState.update { it.copy(strategyProfileIndex = null, strategies = emptyList()) }
    }

    fun selectStrategy(strategy: StrategyCatalogEntry) {
        val index = _uiState.value.strategyProfileIndex ?: return
        _uiState.update { it.copy(strategyProfileIndex = null, strategies = emptyList()) }
        mutate { repository.replaceStrategy(it, index, strategy) }
    }

    fun clearMessage() = _uiState.update { it.copy(message = null) }

    private fun mutate(block: suspend (PresetProfileDocument) -> ProfileMutationResult) {
        val document = _uiState.value.document ?: return
        if (!busy.compareAndSet(false, true)) return
        _uiState.update { it.copy(operation = ProfilesOperation.SAVE, message = null) }
        viewModelScope.launch {
            try {
                val result = block(document)
                val outcome = result.outcome
                if (outcome.durable in setOf(PresetDurableOutcome.APPLIED, PresetDurableOutcome.SAVED_AND_APPLIED)) {
                    serviceEventBus.notifyServiceRestarted(ServiceEventSource.PROFILES)
                }
                if (outcome.durable in OUTCOMES_REQUIRING_AUTHORITATIVE_READ) {
                    reloadPending = true
                    _uiState.update {
                        it.copy(
                            document = null,
                            operation = ProfilesOperation.LOAD,
                            error = false,
                            message = outcomeMessage(outcome),
                        )
                    }
                } else {
                    _uiState.update {
                        it.copy(
                            document = document,
                            operation = null,
                            error = false,
                            message = outcomeMessage(outcome),
                        )
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                reloadPending = true
                _uiState.update {
                    it.copy(
                        document = null,
                        operation = ProfilesOperation.LOAD,
                        error = false,
                        message = UiText.resource(R.string.profiles_save_failed),
                    )
                }
            } finally {
                busy.set(false)
                if (reloadPending && screenStarted) startProjectionRead()
            }
        }
    }

    private fun outcomeMessage(outcome: PresetMutationOutcome): UiText = when (outcome) {
        PresetMutationOutcome.Saved -> UiText.resource(R.string.profiles_saved_stopped)
        PresetMutationOutcome.SavedAndApplied, PresetMutationOutcome.Applied ->
            UiText.resource(R.string.profiles_applied)
        PresetMutationOutcome.SourceChanged -> UiText.resource(R.string.profiles_source_changed)
        PresetMutationOutcome.RestartFailedRolledBack ->
            UiText.resource(R.string.profiles_restart_failed_rolled_back)
        PresetMutationOutcome.WriteFailedRolledBack ->
            UiText.resource(R.string.profiles_write_failed_rolled_back)
        PresetMutationOutcome.RollbackFailed -> UiText.resource(R.string.profiles_rollback_failed)
        PresetMutationOutcome.IoFailed -> UiText.resource(R.string.profiles_io_failed)
        PresetMutationOutcome.Blocked -> UiText.resource(R.string.profiles_blocked)
        is PresetMutationOutcome.Rejected ->
            UiText.resource(R.string.profiles_rejected, outcome.issue.wireCode)
    }

    private companion object {
        const val MAX_PROFILE_NAME_CHARS = 200
        val OUTCOMES_REQUIRING_AUTHORITATIVE_READ = setOf(
            PresetDurableOutcome.SAVED,
            PresetDurableOutcome.SAVED_AND_APPLIED,
            PresetDurableOutcome.APPLIED,
            PresetDurableOutcome.SOURCE_CHANGED,
            PresetDurableOutcome.IO_FAILED,
            PresetDurableOutcome.ROLLBACK_FAILED,
        )
    }
}

package com.zapret2.app.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Process-local invalidation for projections of the authoritative preset files.
 *
 * The value carries no configuration itself. A consumer that observes a new revision must read
 * the active preset through the bounded active-snapshot path; replaying the latest revision keeps
 * restored destinations from missing a mutation while they were outside the visible lifecycle.
 */
@Singleton
class PresetStateRevision @Inject constructor() {
    private val _revision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = _revision.asStateFlow()

    internal fun publishCommittedMutation() {
        _revision.update { current ->
            check(current != Long.MAX_VALUE) { "Preset state revision exhausted" }
            current + 1L
        }
    }
}

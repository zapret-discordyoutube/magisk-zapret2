package com.zapret2.app.viewmodel

import com.zapret2.app.data.PresetMutationOutcome
import com.zapret2.app.data.PresetProfileDocument
import com.zapret2.app.data.PresetProfileParser
import com.zapret2.app.data.PresetStateRevision
import com.zapret2.app.data.ProfileListEntry
import com.zapret2.app.data.ProfileMutationResult
import com.zapret2.app.data.ProfileRepository
import com.zapret2.app.data.ServiceEventBus
import com.zapret2.app.data.StrategyCatalogEntry
import com.zapret2.app.data.StrategyCatalogScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ProfilesViewModelSynchronizationTest {
    private val mainDispatcher = StandardTestDispatcher()

    @Before
    fun setUpMainDispatcher() {
        Dispatchers.setMain(mainDispatcher)
    }

    @After
    fun resetMainDispatcher() {
        Dispatchers.resetMain()
    }

    @Test
    fun everyVisibleEntryReadsTheCurrentActivePresetInsteadOfRestoredState() =
        runTest(mainDispatcher) {
            val repository = FakeProfileRepository(document("first.txt", "First", "Second"))
            val viewModel = ProfilesViewModel(repository, ServiceEventBus(), PresetStateRevision())

            viewModel.onScreenStarted()
            advanceUntilIdle()
            assertEquals(listOf("First", "Second"), viewModel.profileNames())

            viewModel.onScreenStopped()
            repository.current = document("second.txt", "Replacement", "Final")
            viewModel.onScreenStarted()
            advanceUntilIdle()

            assertEquals(2, repository.loadCalls)
            assertEquals("second.txt", viewModel.uiState.value.document?.fileName)
            assertEquals(listOf("Replacement", "Final"), viewModel.profileNames())
        }

    @Test
    fun committedMutationWhileStoppedInvalidatesWithoutDoingBackgroundIo() =
        runTest(mainDispatcher) {
            val revision = PresetStateRevision()
            val repository = FakeProfileRepository(document("first.txt", "Old"))
            val viewModel = ProfilesViewModel(repository, ServiceEventBus(), revision)
            viewModel.onScreenStarted()
            advanceUntilIdle()
            viewModel.onScreenStopped()

            repository.current = document("second.txt", "Current")
            revision.publishCommittedMutation()
            advanceUntilIdle()

            assertEquals(1, repository.loadCalls)
            assertNull(viewModel.uiState.value.document)

            viewModel.onScreenStarted()
            advanceUntilIdle()
            assertEquals(2, repository.loadCalls)
            assertEquals(listOf("Current"), viewModel.profileNames())
        }

    @Test
    fun readThatRacesACommittedMutationCanNeverPublishItsStaleOrder() =
        runTest(mainDispatcher) {
            val revision = PresetStateRevision()
            val gate = CompletableDeferred<Unit>()
            val repository = FakeProfileRepository(document("old.txt", "Old first", "Old second"))
                .apply { nextLoadGate = gate }
            val viewModel = ProfilesViewModel(repository, ServiceEventBus(), revision)

            viewModel.onScreenStarted()
            runCurrent()
            repository.current = document("new.txt", "New second", "New first")
            revision.publishCommittedMutation()
            runCurrent()
            gate.complete(Unit)
            advanceUntilIdle()

            assertEquals(2, repository.loadCalls)
            assertEquals("new.txt", viewModel.uiState.value.document?.fileName)
            assertEquals(listOf("New second", "New first"), viewModel.profileNames())
        }

    private fun ProfilesViewModel.profileNames(): List<String> =
        uiState.value.document?.profiles.orEmpty().map { it.name }

    private fun document(fileName: String, vararg names: String): PresetProfileDocument {
        val source = names.mapIndexed { index, name ->
            buildString {
                if (index > 0) append("--new\n")
                append("--name=$name\n")
                append("--filter-tcp=443\n")
                append("--lua-desync=pass\n")
            }
        }.joinToString("")
        return requireNotNull(PresetProfileParser.parse(fileName, source))
    }

    private class FakeProfileRepository(
        var current: PresetProfileDocument?,
    ) : ProfileRepository {
        var loadCalls = 0
        var nextLoadGate: CompletableDeferred<Unit>? = null

        override suspend fun loadActive(): PresetProfileDocument? {
            loadCalls++
            val snapshot = current
            nextLoadGate?.also { nextLoadGate = null }?.await()
            return snapshot
        }

        override suspend fun loadStrategies(
            scope: StrategyCatalogScope,
            availableBlobs: Set<String>,
        ): List<StrategyCatalogEntry>? = emptyList()

        override suspend fun loadListEntries(selectorLine: String): List<ProfileListEntry>? =
            emptyList()

        override suspend fun setEnabled(
            document: PresetProfileDocument,
            profileIndex: Int,
            enabled: Boolean,
        ): ProfileMutationResult = ProfileMutationResult(PresetMutationOutcome.Saved)

        override suspend fun rename(
            document: PresetProfileDocument,
            profileIndex: Int,
            name: String,
        ): ProfileMutationResult = ProfileMutationResult(PresetMutationOutcome.Saved)

        override suspend fun replaceSelector(
            document: PresetProfileDocument,
            profileIndex: Int,
            selectorIndex: Int,
            relativePath: String,
        ): ProfileMutationResult = ProfileMutationResult(PresetMutationOutcome.Saved)

        override suspend fun replaceStrategy(
            document: PresetProfileDocument,
            profileIndex: Int,
            strategy: StrategyCatalogEntry,
        ): ProfileMutationResult = ProfileMutationResult(PresetMutationOutcome.Saved)

        override suspend fun move(
            document: PresetProfileDocument,
            fromIndex: Int,
            toIndex: Int,
        ): ProfileMutationResult = ProfileMutationResult(PresetMutationOutcome.Saved)
    }
}

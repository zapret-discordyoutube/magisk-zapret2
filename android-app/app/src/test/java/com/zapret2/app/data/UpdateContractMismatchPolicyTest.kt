package com.zapret2.app.data

import com.zapret2.app.repositorySourceFile
import com.zapret2.app.sourceRegion
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v2.3.0 raised the packaged lifecycle contract, and every already-installed app rejected the
 * release for it — then deferred that release's APK behind the module it had just rejected. The
 * only way out was sideloading the APK by hand, which is exactly the situation in-app updates
 * exist to avoid. Deferring is still right for a suspect package; it is wrong for the one
 * failure whose fix is the deferred artifact itself.
 */
class UpdateContractMismatchPolicyTest {

    private val source by lazy {
        repositorySourceFile(
            "android-app/app/src/main/java/com/zapret2/app/data/UpdateManager.kt",
        ).readText()
    }

    @Test
    fun aRaisedContractIsNamedBeforeThePackageIsCalledInvalid() {
        val verdict = source.sourceRegion(
            after = "!hasModuleProp -> ArtifactValidationReason.MODULE_IDENTITY_MISSING",
            before = "} catch (_: Exception) {",
        )
        assertTrue(
            "a raised contract must be recognized before the generic invalid-package verdict",
            verdict.indexOf("MODULE_CONTRACT_MISMATCH") in
                0 until verdict.indexOf("MODULE_PACKAGE_INVALID"),
        )
        assertTrue(
            "the contract question must be asked of the archive itself",
            verdict.contains("archiveSpeaksAnotherLifecycleContract("),
        )
    }

    @Test
    fun theSameReleasesApkSurvivesAModuleItCannotRead() {
        val rejection = source.sourceRegion(
            after = "moduleOutcome = ModuleArtifactOutcome.Failed(validationFailure)",
            before = "validatedModule = ValidatedModuleArtifact(",
        )
        assertTrue(
            "the contract case has to be told apart from any other validation failure",
            rejection.contains("ArtifactValidationReason.MODULE_CONTRACT_MISMATCH"),
        )
        assertTrue(
            "a suspect package must still defer the APK",
            rejection.contains("!contractMismatch"),
        )

        val deferral = rejection.sourceRegion(
            after = "if (apkArtifact != null && !contractMismatch) {",
            before = "if (apkArtifact == null) {",
        )
        assertTrue(
            "the deferral belongs to the suspect-package branch only",
            deferral.contains("UpdateDeferredReason.MODULE_PREFLIGHT_FAILED"),
        )

        // Reaching the APK handoff requires leaving the module unvalidated rather than falling
        // through into staging a package this build cannot read.
        assertTrue(
            "the rejected module must not continue into installation",
            rejection.contains("downloadedModule = null") && rejection.contains("return@let"),
        )
    }

    @Test
    fun theRejectionIsReportedAsAStaleAppRatherThanABrokenPackage() {
        val presentation = repositorySourceFile(
            "android-app/app/src/main/java/com/zapret2/app/viewmodel/ControlViewModel.kt",
        ).readText()
        assertTrue(
            "the contract mismatch needs its own user-facing answer",
            presentation.contains("R.string.control_update_module_contract_mismatch"),
        )
        assertFalse(
            "it must not reuse the integrity-failure copy",
            presentation.sourceRegion(
                after = "ArtifactValidationReason.MODULE_CONTRACT_MISMATCH ->",
                before = "ArtifactValidationReason.MODULE_VALIDATION_FAILED ->",
            ).contains("control_update_module_package_invalid"),
        )
    }
}

package com.zapret2.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ReleaseArtifactIntegrityTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun downloadProgress_isBoundedForUntrustedContentLength() {
        assertEquals(0, requireNotNull(boundedDownloadPercent(totalBytesRead = 0, contentLength = 100)))
        assertEquals(33, requireNotNull(boundedDownloadPercent(totalBytesRead = 1, contentLength = 3)))
        assertEquals(100, requireNotNull(boundedDownloadPercent(totalBytesRead = 100, contentLength = 100)))
        assertEquals(100, requireNotNull(boundedDownloadPercent(totalBytesRead = 500, contentLength = 100)))
        assertNull(boundedDownloadPercent(totalBytesRead = -1, contentLength = 100))
        assertNull(boundedDownloadPercent(totalBytesRead = 1, contentLength = 0))
        assertNull(boundedDownloadPercent(totalBytesRead = 1, contentLength = -1))
        assertNull(
            boundedDownloadPercent(
                totalBytesRead = 512L * 1024L * 1024L + 1,
                contentLength = 512L * 1024L * 1024L,
            ),
        )
        assertNull(
            boundedDownloadPercent(
                totalBytesRead = 1,
                contentLength = 512L * 1024L * 1024L + 1,
            ),
        )
    }

    @Test
    fun downloadRedirects_acceptOnlyReviewedGetRedirectStatuses() {
        listOf(301, 302, 303, 307, 308).forEach {
            assertTrue(it.toString(), isSupportedDownloadRedirectStatus(it))
        }
        listOf(200, 300, 304, 305, 306, 309, 400).forEach {
            assertFalse(it.toString(), isSupportedDownloadRedirectStatus(it))
        }
    }

    @Test
    fun releaseAssetUrl_acceptsOnlyTheExactForgejoRepositoryReleasePath() {
        listOf(
            "https://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/app.apk",
            "https://git.zapret.moe:443/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/module.zip?download=1",
        ).forEach { assertTrue(it, isTrustedReleaseAssetUrl(it)) }

        listOf(
            "http://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/app.apk",
            "https://git.zapret.moe/other/repository/releases/download/v1/app.apk",
            "https://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2/releases/app.apk",
            "https://git.zapret.moe/api/v1/repos/owner/repository/releases/assets/1",
            "https://example.test/app.apk",
            "https://git.zapret.moe.evil.test/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/app.apk",
            "https://user@git.zapret.moe/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/app.apk",
            "https://git.zapret.moe:444/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/app.apk",
            "https://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/app.apk#fragment",
            "https://127.0.0.1/app.apk",
            "https://[::1]/app.apk",
            "https://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/app.apk\nX-Test: injected",
            "https://git.zapret.moe/${"a".repeat(2_100)}",
        ).forEach { assertFalse(it, isTrustedReleaseAssetUrl(it)) }
    }

    @Test
    fun releaseAssetUrl_rejectsCredentialsPortsAndFragmentsAfterAForgejoRedirect() {
        val releaseAsset =
            "https://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2/releases/download/v1/module.zip"
        assertTrue(isTrustedReleaseAssetUrl(releaseAsset))
        listOf(
            releaseAsset.replace("https://", "https://attacker@"),
            releaseAsset.replace("git.zapret.moe", "git.zapret.moe:8443"),
            "$releaseAsset#fragment",
        ).forEach {
            assertFalse(it, isTrustedReleaseAssetUrl(it))
        }
    }

    @Test
    fun checksumSidecar_requiresExactSha256AndExactFileName() {
        val uppercase = "AB".repeat(32)
        assertEquals(
            "ab".repeat(32),
            ReleaseArtifactIntegrity.parseSha256Sidecar("$uppercase  app.apk\n", "app.apk").getOrThrow(),
        )
        assertEquals(
            "ab".repeat(32),
            ReleaseArtifactIntegrity.parseSha256Sidecar("$uppercase *app.apk\r\n", "app.apk").getOrThrow(),
        )
        assertTrue(ReleaseArtifactIntegrity.parseSha256Sidecar("", "app.apk").isFailure)
        assertTrue(ReleaseArtifactIntegrity.parseSha256Sidecar("1234  app.apk", "app.apk").isFailure)
        assertTrue(ReleaseArtifactIntegrity.parseSha256Sidecar("$uppercase  other.apk", "app.apk").isFailure)
        assertTrue(ReleaseArtifactIntegrity.parseSha256Sidecar("$uppercase  app.apk\n$uppercase  other.apk", "app.apk").isFailure)
        assertTrue(ReleaseArtifactIntegrity.parseSha256Sidecar("$uppercase  app.apk", "../app.apk").isFailure)
    }

    @Test
    fun partialDownloadNames_acceptOnlyOwnedLegacyOrUuidFiles() {
        val expected = "zapret2.apk"
        assertTrue(isUpdatePartialFileName(expected, "$expected.part.123456"))
        assertTrue(isUpdatePartialFileName(expected, "$expected.part.-123456"))
        assertTrue(
            isUpdatePartialFileName(
                expected,
                "$expected.part.123e4567-e89b-12d3-a456-426614174000",
            ),
        )
        assertFalse(isUpdatePartialFileName(expected, expected))
        assertFalse(isUpdatePartialFileName(expected, "$expected.part."))
        assertFalse(isUpdatePartialFileName(expected, "$expected.part.123.tmp"))
        assertFalse(isUpdatePartialFileName(expected, "other.apk.part.123456"))
        assertFalse(isUpdatePartialFileName("../zapret2.apk", "$expected.part.123456"))
    }

    @Test
    fun downloadedFileMustMatchAdvertisedDigest() {
        val file = temporaryFolder.newFile("asset.zip").apply { writeText("trusted release bytes") }
        val expected = ReleaseArtifactIntegrity.sha256(file)

        assertTrue(ReleaseArtifactIntegrity.matches(file, expected))
        assertFalse(ReleaseArtifactIntegrity.matches(file, "00".repeat(32)))
        assertFalse(ReleaseArtifactIntegrity.matches(file, "not-a-digest"))
    }

    @Test
    fun apkSigningIdentity_acceptsExactOrRotatedSingleSignerAndRejectsAllOtherShapes() {
        val installed = ApkSigningIdentity(
            currentCertificates = setOf("current"),
            hasMultipleSigners = false,
            certificateHistory = setOf("old", "current"),
        )
        assertTrue(
            apkSigningIdentitiesAreCompatible(
                installed,
                ApkSigningIdentity(
                    currentCertificates = setOf("current"),
                    hasMultipleSigners = false,
                    certificateHistory = setOf("old", "current"),
                ),
            ),
        )
        assertTrue(
            apkSigningIdentitiesAreCompatible(
                installed,
                ApkSigningIdentity(
                    currentCertificates = setOf("next"),
                    hasMultipleSigners = false,
                    certificateHistory = setOf("old", "current", "next"),
                ),
            ),
        )
        assertFalse(
            apkSigningIdentitiesAreCompatible(
                installed,
                ApkSigningIdentity(setOf("foreign"), hasMultipleSigners = false),
            ),
        )
        assertFalse(
            "An old signer from installed history is not a forward update",
            apkSigningIdentitiesAreCompatible(
                installed,
                ApkSigningIdentity(setOf("old"), hasMultipleSigners = false),
            ),
        )
        assertFalse(
            "Candidate history must authenticate its own current signer",
            apkSigningIdentitiesAreCompatible(
                installed,
                ApkSigningIdentity(
                    currentCertificates = setOf("next"),
                    hasMultipleSigners = false,
                    certificateHistory = setOf("current"),
                ),
            ),
        )

        val multi = ApkSigningIdentity(setOf("one", "two"), hasMultipleSigners = true)
        assertTrue(apkSigningIdentitiesAreCompatible(multi, multi.copy()))
        assertFalse(
            apkSigningIdentitiesAreCompatible(
                multi,
                ApkSigningIdentity(setOf("one"), hasMultipleSigners = true),
            ),
        )
        assertFalse(
            apkSigningIdentitiesAreCompatible(
                multi,
                ApkSigningIdentity(setOf("one", "two"), hasMultipleSigners = false),
            ),
        )
        assertFalse(
            apkSigningIdentitiesAreCompatible(
                ApkSigningIdentity(emptySet(), hasMultipleSigners = false),
                installed,
            ),
        )
    }

    @Test
    fun releaseVersionComparison_isBoundedStrictAndPrereleaseAware() {
        assertTrue(isNewerReleaseVersion("2.0.0", "1.99.99"))
        assertTrue(isNewerReleaseVersion("v2.0", "1.9.9"))
        assertTrue(isNewerReleaseVersion("2.0.0", "2.0.0-beta.1"))
        assertFalse(isNewerReleaseVersion("2.0.0-beta.1", "2.0.0"))
        assertTrue(isNewerReleaseVersion("2.0.0-beta.11", "2.0.0-beta.2"))
        assertFalse(isNewerReleaseVersion("2.0.0-beta.2", "2.0.0-beta.11"))
        assertFalse(isNewerReleaseVersion("2.0.0", "2.0.0"))
        assertFalse(isNewerReleaseVersion("not-a-version", "1.0.0"))
        assertFalse(isNewerReleaseVersion("vv2.0.0", "1.0.0"))
        assertFalse(isNewerReleaseVersion("999999999999999999999999.0", "1.0.0"))
        assertTrue(isNewerReleaseVersion("2.0.0", "unknown"))
        assertEquals(2_000_000L, requireNotNull(projectReleaseVersionCode("v2.0.0")))
        assertEquals(2_010_017L, requireNotNull(projectReleaseVersionCode("2.1.17")))
        assertEquals(3_000_000L, requireNotNull(projectReleaseVersionCode("3.0.0")))
        assertNull(projectReleaseVersionCode("2.100.0"))
        assertNull(projectReleaseVersionCode("2.0.10000"))
        assertNull(projectReleaseVersionCode("2.0.0.1"))
        assertNull(projectReleaseVersionCode("02.0.0"))
        assertNull(projectReleaseVersionCode("2.00.0"))
        assertNull(projectReleaseVersionCode("2.0.00"))
        assertNull(projectReleaseVersionCode("2101.0.0"))
        assertNull(projectReleaseVersionCode("2.0.0-beta.1"))
        assertTrue(isProjectReleaseTag("v2.0.0"))
        assertFalse(isProjectReleaseTag("2.0.0"))
        assertFalse(moduleVersionAllowsInstall(null, "2.0.0", allowSameVersionRepair = false))
        assertTrue(moduleVersionAllowsInstall(null, "2.0.0", allowSameVersionRepair = true))
        assertTrue(moduleVersionAllowsInstall("v1.9.122601", "2.0.0", allowSameVersionRepair = false))
        assertFalse(moduleVersionAllowsInstall("v2.0.0", "2.0.0", allowSameVersionRepair = false))
        assertTrue(moduleVersionAllowsInstall("v2.0.0", "2.0.0", allowSameVersionRepair = true))
        assertFalse(moduleVersionAllowsInstall("v3.0.0", "2.0.0", allowSameVersionRepair = true))
    }

    @Test
    fun moduleVersionGrammar_admitsDevIdentitiesWithoutWideningTheReleaseChannel() {
        val dev = "v2.1.5-dev.20260725110254.2a7ce2d1"
        assertEquals(2_010_005L, requireNotNull(projectModuleVersionCode(dev)))
        assertEquals(2_010_005L, requireNotNull(projectModuleVersionCode("v2.1.5")))
        assertNull(projectModuleVersionCode("v2.1.5-dev.20260725110254"))
        assertNull(projectModuleVersionCode("v2.1.5-beta.1"))
        assertNull(projectModuleVersionCode("v2.1.5-dev.20260725110254.2a7ce2d1.extra"))

        // A dev build is never a release tag, and a published release supersedes
        // a dev prerelease of the same base version without the repair flag.
        assertNull(projectReleaseVersionCode(dev))
        assertFalse(isProjectReleaseTag(dev))
        assertTrue(isNewerReleaseVersion("2.1.5", dev))
        assertFalse(isNewerReleaseVersion("2.1.4", dev))
        assertTrue(moduleVersionAllowsInstall(dev, "2.1.5", allowSameVersionRepair = false))
        assertFalse(moduleVersionAllowsInstall(dev, "2.1.4", allowSameVersionRepair = false))
    }

    @Test
    fun standardModuleInstall_requiresExactPublishedVersionAndArchiveGeneration() {
        val digest = "ab".repeat(32)
        val generation = InstallGenerationMetadata.Record("generation-1", digest)

        assertTrue(
            standardInstallPublicationMatches(
                installedVersion = "v2.0.0",
                installGeneration = generation,
                expectedReleaseVersion = "2.0.0",
                expectedArchiveSha256 = digest,
            ),
        )
        assertFalse(
            standardInstallPublicationMatches(
                "v1.9.122601",
                generation,
                "2.0.0",
                digest,
            ),
        )
        assertFalse(
            standardInstallPublicationMatches(
                "v2.0.0",
                generation.copy(archiveSha256 = "cd".repeat(32)),
                "2.0.0",
                digest,
            ),
        )
        assertFalse(standardInstallPublicationMatches(null, generation, "2.0.0", digest))
        assertFalse(standardInstallPublicationMatches("v2.0.0", null, "2.0.0", digest))
        assertFalse(
            standardInstallPublicationMatches(
                "v2.0.0",
                generation,
                "2.0.0",
                digest.uppercase(),
            ),
        )
    }
}

package com.zapret2.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PresetImportReaderTest {

    @Test
    fun validUtf8TxtPreservesNfqws2ArgumentsAndCanonicalizesOnlyTextFraming() {
        val source = "\uFEFF--comment=kept exactly\r\n--filter-tcp=443\r\n--filter-l7=tls\r\n"

        val result = validatePresetImport("My strategy.txt", source.toByteArray(Charsets.UTF_8))

        assertEquals(
            PresetImportValidation.Valid(
                "My strategy.txt",
                "--comment=kept exactly\n--filter-tcp=443\n--filter-l7=tls\n",
            ),
            result,
        )
    }

    @Test
    fun importBoundaryRejectsUnsafeNamesOversizeAndMalformedText() {
        assertEquals(
            PresetImportFailure.INVALID_NAME,
            (validatePresetImport("../escape.txt", byteArrayOf(1)) as PresetImportValidation.Failure).reason,
        )
        assertEquals(
            PresetImportFailure.TOO_LARGE,
            (
                validatePresetImport(
                    "large.txt",
                    ByteArray(PresetContentPolicy.MAX_BYTES + 1),
                ) as PresetImportValidation.Failure
            ).reason,
        )
        assertEquals(
            PresetImportFailure.TOO_LARGE,
            (
                validatePresetImport(
                    "needs-newline.txt",
                    ByteArray(PresetContentPolicy.MAX_BYTES) { 'a'.code.toByte() },
                ) as PresetImportValidation.Failure
            ).reason,
        )
        assertEquals(
            PresetImportFailure.INVALID_ENCODING,
            (
                validatePresetImport(
                    "broken.txt",
                    byteArrayOf(0xc3.toByte()),
                ) as PresetImportValidation.Failure
            ).reason,
        )
        assertTrue(
            validatePresetImport("nul.txt", byteArrayOf(0)) ==
                PresetImportValidation.Failure(PresetImportFailure.INVALID_ENCODING),
        )
    }

    @Test
    fun legacyNativePresetGetsOnlyExplicitAndroidMetadataAndMissingProfileNames() {
        val legacy = """
            # Preset: Legacy

            --lua-init=@lua/zapret-lib.lua
            --comment=keep exactly

            --filter-tcp=443
            --filter-l7=tls
            --lua-desync=pass

            --new=Voice from upstream

            --filter-udp=443
            --filter-l7=discord,stun
            --lua-desync=pass
        """.trimIndent() + "\n"

        val adapted = adaptPresetImportForAndroid("Legacy.txt", legacy)

        assertTrue(adapted.contains("# NFQWS2_TCP_PKT_OUT=20\n"))
        assertTrue(adapted.contains("# NFQWS2_TCP_PKT_IN=10\n"))
        assertTrue(adapted.contains("# NFQWS2_UDP_PKT_OUT=20\n"))
        assertTrue(adapted.contains("# NFQWS2_UDP_PKT_IN=10\n"))
        assertTrue(adapted.contains("--name=Legacy\n--filter-tcp=443\n--filter-l7=tls"))
        assertTrue(adapted.contains("--new\n\n--name=Voice from upstream\n--filter-udp=443"))
        assertTrue(adapted.contains("--comment=keep exactly"))
        assertTrue(!adapted.contains("--new=Voice from upstream"))
    }

    @Test
    fun canonicalPresetIsNotRewrittenByImportAdapter() {
        val canonical = """
            # NFQWS2_TCP_PKT_OUT=5
            # NFQWS2_TCP_PKT_IN=4
            # NFQWS2_UDP_PKT_OUT=3
            # NFQWS2_UDP_PKT_IN=2

            --lua-init=@lua/zapret-lib.lua

            --name=Already named
            --filter-tcp=443
            --lua-desync=pass
        """.trimIndent() + "\n"

        assertEquals(canonical, adaptPresetImportForAndroid("Canonical.txt", canonical))
    }
}

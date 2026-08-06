package com.zapret2.app.data

import java.io.File
import java.security.MessageDigest
import java.util.Locale

internal object ReleaseArtifactIntegrity {
    private val SHA256 = Regex("^[0-9a-fA-F]{64}$")

    fun isSha256(value: String): Boolean = SHA256.matches(value)

    /** Parse the exact one-file format produced by `sha256sum file > file.sha256`. */
    fun parseSha256Sidecar(contents: String, expectedFileName: String): Result<String> {
        if (!RootFileIo.isSimpleFileName(expectedFileName)) {
            return Result.failure(IllegalArgumentException("Release artifact name is invalid"))
        }
        val normalized = contents.removeSuffix("\n").removeSuffix("\r")
        if ('\n' in normalized || '\r' in normalized || normalized.any(Char::isISOControl)) {
            return Result.failure(IllegalArgumentException("Checksum sidecar has multiple or invalid lines"))
        }
        val separator = normalized.indexOfFirst { it == ' ' || it == '\t' }
        if (separator != 64) {
            return Result.failure(IllegalArgumentException("Checksum sidecar digest is malformed"))
        }
        val digest = normalized.substring(0, separator)
        val advertisedName = normalized.substring(separator).trimStart(' ', '\t').removePrefix("*")
        if (!SHA256.matches(digest) || advertisedName != expectedFileName) {
            return Result.failure(IllegalArgumentException("Checksum sidecar does not match the release artifact"))
        }
        return Result.success(digest.lowercase(Locale.ROOT))
    }

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.readWithProgress(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    fun matches(file: File, expectedSha256: String): Boolean =
        SHA256.matches(expectedSha256) && sha256(file) == expectedSha256.lowercase(Locale.ROOT)
}

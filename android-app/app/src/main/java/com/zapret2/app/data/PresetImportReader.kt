package com.zapret2.app.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CancellationException
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import javax.inject.Inject

enum class PresetImportFailure {
    INVALID_NAME,
    TOO_LARGE,
    INVALID_ENCODING,
    READ_FAILED,
}

sealed interface PresetImportValidation {
    data class Valid(val fileName: String, val content: String) : PresetImportValidation
    data class Failure(val reason: PresetImportFailure) : PresetImportValidation
}

interface PresetImportReader {
    fun readAndValidate(uri: Uri): PresetImportValidation
}

/** Bounded, UTF-8-only Android document-provider boundary for custom preset TXT files. */
class ContentResolverPresetImportReader @Inject constructor(
    @param:ApplicationContext private val context: Context,
) : PresetImportReader {
    override fun readAndValidate(uri: Uri): PresetImportValidation {
        val fileName = try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        } ?: return PresetImportValidation.Failure(PresetImportFailure.INVALID_NAME)
        if (!PresetNamePolicy.isValid(fileName)) {
            return PresetImportValidation.Failure(PresetImportFailure.INVALID_NAME)
        }

        val bytes = try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                input.readBoundedBytes(PresetContentPolicy.MAX_BYTES)
                    ?: ByteArray(PresetContentPolicy.MAX_BYTES + 1)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        } ?: return PresetImportValidation.Failure(PresetImportFailure.READ_FAILED)

        return validatePresetImport(fileName, bytes)
    }
}

internal fun validatePresetImport(fileName: String, bytes: ByteArray): PresetImportValidation {
    if (bytes.size > PresetContentPolicy.MAX_BYTES) {
        return PresetImportValidation.Failure(PresetImportFailure.TOO_LARGE)
    }
    if (!PresetNamePolicy.isValid(fileName)) {
        return PresetImportValidation.Failure(PresetImportFailure.INVALID_NAME)
    }
    val decoded = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
            .removePrefix("\uFEFF")
    } catch (_: Exception) {
        return PresetImportValidation.Failure(PresetImportFailure.INVALID_ENCODING)
    }
    if ('\u0000' in decoded) {
        return PresetImportValidation.Failure(PresetImportFailure.INVALID_ENCODING)
    }
    val normalized = PresetContentPolicy.normalizedForWrite(decoded)
    if (!PresetContentPolicy.isAllowed(normalized)) {
        return PresetImportValidation.Failure(PresetImportFailure.TOO_LARGE)
    }
    return PresetImportValidation.Valid(fileName = fileName, content = normalized)
}

/**
 * Adds only the Android wrapper metadata that a native/legacy nfqws2 preset cannot carry.
 * Existing nfqws2 arguments are kept byte-for-byte after text framing was canonicalized.
 */
internal fun adaptPresetImportForAndroid(fileName: String, content: String): String {
    val sourceLines = PresetContentPolicy.normalizedForWrite(content)
        .trimEnd('\n')
        .split('\n')
        .toMutableList()
    if (sourceLines.none(::isCapturePolicyLine)) {
        val headerEnd = sourceLines.indexOfFirst { line ->
            line.isNotBlank() && !line.startsWith("#") && !line.startsWith(";")
        }.let { if (it < 0) sourceLines.size else it }
        sourceLines.addAll(headerEnd, ANDROID_CAPTURE_POLICY + "")
    }

    val blocks = mutableListOf<MutableList<String>>()
    val separatorNames = mutableListOf<String?>()
    var current = mutableListOf<String>()
    sourceLines.forEach { line ->
        when {
            line == "--new" -> {
                blocks += current
                separatorNames += null
                current = mutableListOf()
            }
            line.startsWith("--new=") -> {
                blocks += current
                separatorNames += line.removePrefix("--new=").takeIf(String::isNotBlank)
                current = mutableListOf()
            }
            else -> current += line
        }
    }
    blocks += current

    val baseName = fileName.removeSuffix(".txt")
    blocks.forEachIndexed { index, block ->
        if (block.none { it.startsWith("--name=") } && block.any(::isProfileOption)) {
            val importedName = separatorNames.getOrNull(index - 1)
                ?: if (index == 0) baseName else "$baseName #${index + 1}"
            val insertion = if (index == 0) {
                block.indexOfFirst(::isProfileOption).coerceAtLeast(0)
            } else {
                block.indexOfFirst { it.isNotBlank() && !it.startsWith("#") && !it.startsWith(";") }
                    .let { if (it < 0) block.size else it }
            }
            block.add(insertion, "--name=$importedName")
        }
    }

    return buildString {
        blocks.forEachIndexed { index, block ->
            if (index > 0) append("--new\n")
            append(block.joinToString("\n"))
            if (index != blocks.lastIndex || block.isNotEmpty()) append('\n')
        }
    }
}

private fun isCapturePolicyLine(line: String): Boolean =
    ANDROID_CAPTURE_POLICY_KEYS.any { line.startsWith("# $it=") }

private fun isProfileOption(line: String): Boolean = when {
    line == "--skip" -> true
    line.startsWith("--name=") -> true
    line.startsWith("--template") -> true
    line.startsWith("--cookie") -> true
    line.startsWith("--import=") -> true
    line.startsWith("--filter-") -> true
    line.startsWith("--ipset") -> true
    line.startsWith("--hostlist") -> true
    line.startsWith("--payload=") -> true
    line.startsWith("--out-range=") -> true
    line.startsWith("--in-range=") -> true
    line.startsWith("--lua-desync=") -> true
    else -> false
}

private val ANDROID_CAPTURE_POLICY_KEYS = listOf(
    "NFQWS2_TCP_PKT_OUT",
    "NFQWS2_TCP_PKT_IN",
    "NFQWS2_UDP_PKT_OUT",
    "NFQWS2_UDP_PKT_IN",
)

private val ANDROID_CAPTURE_POLICY = listOf(
    "# NFQWS2_TCP_PKT_OUT=20",
    "# NFQWS2_TCP_PKT_IN=10",
    "# NFQWS2_UDP_PKT_OUT=20",
    "# NFQWS2_UDP_PKT_IN=10",
)

@Module
@InstallIn(SingletonComponent::class)
internal abstract class PresetImportModule {
    @Binds
    abstract fun bindPresetImportReader(
        implementation: ContentResolverPresetImportReader,
    ): PresetImportReader
}

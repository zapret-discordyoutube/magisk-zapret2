package com.zapret2.app

import java.io.File

/**
 * Locates a checked-in file by its repository-relative path, from wherever Gradle happens to have
 * set the unit-test working directory.
 *
 * Source-shaped policy tests read production text off disk; every one of them used to carry its
 * own copy of this walk. Sharing it keeps the failure message identical no matter which policy
 * test hits a moved file.
 */
internal fun repositorySourceFile(relativePath: String): File {
    var current = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
    repeat(8) {
        val candidate = File(current, relativePath)
        if (candidate.isFile) return candidate
        current = current.parentFile ?: return@repeat
    }
    error("Unable to locate repository file: $relativePath")
}

/** Same walk, for a directory a policy test has to enumerate rather than read. */
internal fun repositorySourceDirectory(relativePath: String): File {
    var current = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
    repeat(8) {
        val candidate = File(current, relativePath)
        if (candidate.isDirectory) return candidate
        current = current.parentFile ?: return@repeat
    }
    error("Unable to locate repository directory: $relativePath")
}

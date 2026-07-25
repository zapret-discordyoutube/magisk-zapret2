package com.zapret2.app

/**
 * Cuts the region of a source file that lies between two anchors, failing loudly if either is gone.
 *
 * `String.substringAfter`/`substringBefore` return the receiver *unchanged* when the delimiter is
 * absent. A source-shaped policy test built on them therefore stops failing the moment its anchor
 * is renamed: the "region" silently widens to the whole file, and assertions such as
 * `assertTrue(region.contains(...))` keep passing against text from somewhere else entirely. The
 * test then guards nothing while still reporting green, which is worse than not existing — it was
 * proven by rewriting a real condition in `ControlViewModel.refreshStatus()` and watching the
 * observer policy test pass anyway.
 *
 * Every source-region cut goes through here so the pattern cannot be reintroduced by hand.
 */
internal fun String.sourceRegion(after: String, before: String): String {
    val start = indexOf(after)
    require(start >= 0) { "Source anchor disappeared: \"$after\"" }
    val from = start + after.length
    val end = indexOf(before, startIndex = from)
    require(end >= 0) { "Source anchor disappeared: \"$before\" (searched after \"$after\")" }
    return substring(from, end)
}

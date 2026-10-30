package com.zapret2.app.data

import org.json.JSONException
import org.json.JSONObject
import java.util.Locale

/**
 * Names of the project's Forgejo: one site under several names. git.zapret.moe is dropped by name
 * (TLS SNI) in Russia, so the numbered mirrors go first; the API answered under a name returns asset
 * URLs on that same name.
 *
 * When every known name is silent (they are blocked too), the names handed out now (random labels
 * since 2026-10-30) are read from an entry page on a big platform: the Apps Script page of the project
 * on script.google.com and the project's gist (schema 1, `families.git.hosts`). The same lists serve
 * ZapretGUI and Zapret KVN. Only `*.zapret.moe` names that are not another site's numbered names are
 * learned, so a list can never point the updater outside the project's domain.
 */
internal object ForgejoHosts {
    val BUILT_IN = listOf("git2.zapret.moe", "git3.zapret.moe", "git4.zapret.moe", "git.zapret.moe")
    val ENTRY_LISTS = listOf(
        "https://script.google.com/macros/s/AKfycbzcEPk67WW6fYC0vPVm397QyDFHd4m-SrfKDBnfvG8jAD-n_HXVv8AqQnEHZ6A42oIh/exec?format=json",
        "https://gist.githubusercontent.com/fuckyourkn/ecb9b6a03f53bddcdd47023ebc12d4f9/raw/targets.json",
    )

    /** Hosts an entry list may be read from (Apps Script answers through a redirect to googleusercontent). */
    val ENTRY_HOSTS = setOf("script.google.com", "script.googleusercontent.com", "gist.githubusercontent.com")
    private val NAME = Regex("[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.zapret\\.moe")
    private val PREFIXED = Regex("(git|wiki)\\d*\\.zapret\\.moe")

    @Volatile
    private var learned: List<String> = emptyList()

    /** Names in the order to try them: the ones learned from an entry list, then the built-in ones. */
    fun all(): List<String> = (learned + BUILT_IN).distinct()

    fun isKnown(host: String?): Boolean = host != null && host.lowercase(Locale.ROOT) in all()

    fun accepts(name: String): Boolean {
        if (!NAME.matches(name)) return false
        val family = PREFIXED.matchEntire(name)?.groupValues?.get(1)
        return family == null || family == "git"
    }

    /** The git names of an entry list (schema 1, `families.git.hosts`); remembered for the asset checks of this process. */
    fun learnFromEntry(text: String): List<String> = learn(gitHostsOf(text))

    /** The accepted names among [candidates], lower-cased, in order; they become the names tried first. */
    fun learn(candidates: List<String>): List<String> {
        val hosts = candidates.map { it.trim().lowercase(Locale.ROOT) }.filter(::accepts).distinct()
        if (hosts.isNotEmpty()) learned = hosts
        return hosts
    }

    private fun gitHostsOf(text: String): List<String> = try {
        val document = JSONObject(text)
        val array = document.optJSONObject("families")?.optJSONObject("git")?.optJSONArray("hosts")
        if (document.optInt("schema") != 1 || array == null) {
            emptyList()
        } else {
            (0 until array.length()).mapNotNull { array.opt(it) as? String }
        }
    } catch (_: JSONException) {
        emptyList()   // not a list of ours: nothing is learned from it
    }

    internal fun forgetForTests() {
        learned = emptyList()
    }
}

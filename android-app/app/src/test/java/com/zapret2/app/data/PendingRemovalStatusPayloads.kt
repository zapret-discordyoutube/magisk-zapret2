package com.zapret2.app.data

/**
 * The two `zapret-status.sh --machine-v6` payloads a module marked for removal really prints.
 *
 * Both are shared because the same records have to be proven twice: the parser must grade them,
 * and the screen must keep offering the recovery actions on the result. Keeping one copy stops the
 * two proofs from drifting onto different bytes.
 */

/**
 * A verified running service on a module marked for removal.
 *
 * The fast snapshot path validates owner metadata, the ruleset and the queue number, so
 * `Z2_STATUS=ok` with `Z2_CHAINS`/`Z2_ANCHORS` taken from the published snapshot and the error
 * envelope cleared. `Z2_UNINSTALL_TOMBSTONE=1` comes from a different question entirely —
 * `[ -e "$UNINSTALL_TOMBSTONE" ]` or `module_removal_pending` — and nothing on the grading path
 * reads it back, so the record is graded `ok` with the flag set.
 */
internal fun runningMarkedForRemovalStatusLines(): List<String> = listOf(
    "Z2_PROTOCOL=6",
    "Z2_STATUS=ok",
    "Z2_OWNED=1",
    "Z2_PROCESS=1",
    "Z2_ACTIVE=1",
    "Z2_PID=4242",
    "Z2_PID_VERIFIED=1",
    "Z2_PID_STARTTIME=98765",
    "Z2_OWNER_GENERATION=generation-1",
    "Z2_OWNER_METADATA_VERIFIED=1",
    "Z2_QNUM=200",
    "Z2_IPV4=1",
    "Z2_IPV6=1",
    "Z2_RULES=3",
    "Z2_EXPECTED_RULES=3",
    "Z2_IPV4_RULES=2",
    "Z2_IPV6_RULES=1",
    "Z2_RULESET_VERIFIED=1",
    "Z2_NFQUEUE=1",
    "Z2_QUEUE_BYPASS=1",
    "Z2_UPDATE_BLOCKED=0",
    "Z2_UNINSTALL_TOMBSTONE=1",
    "Z2_LIFECYCLE_STATE=idle",
    "Z2_LIFECYCLE_OWNER_KIND=none",
    "Z2_CHAINS=4",
    "Z2_ANCHORS=4",
    "Z2_ERROR_SCHEMA=1",
    "Z2_ERROR_STATUS=OK",
    "Z2_ERROR_DOMAIN=NONE",
    "Z2_ERROR_STAGE=NONE",
    "Z2_ERROR_CODE=NONE",
    "Z2_ERROR_DETAIL=",
    "Z2_COMPLETE=1",
)

/**
 * The observation right after a clean stop, with the module marked for removal.
 *
 * The stopped fast path is taken (`STATUS_FILE_STATUS=stopped`, `RULES_TOTAL=0`,
 * `STATUS_FILE_RULESET_VERIFIED=1`, no pidfile, no owner state), so every measured field is zero
 * and `Z2_RULESET_VERIFIED` is recomputed as 1. `Z2_UNINSTALL_TOMBSTONE=1` then forces
 * `Z2_OWNED=1`, which keeps the grade off `stopped` and lands it on `degraded` — the branch that
 * echoes the kernel capabilities from the snapshot and leaves chains/anchors at zero.
 * `Z2_STATUS=degraded` also arms the module's own STATUS_DEGRADED error envelope.
 */
internal fun tombstoneOwnedQuietStatusLines(): List<String> = listOf(
    "Z2_PROTOCOL=6",
    "Z2_STATUS=degraded",
    "Z2_OWNED=1",
    "Z2_PROCESS=0",
    "Z2_ACTIVE=0",
    "Z2_PID=",
    "Z2_PID_VERIFIED=0",
    "Z2_PID_STARTTIME=",
    "Z2_OWNER_GENERATION=",
    "Z2_OWNER_METADATA_VERIFIED=0",
    "Z2_QNUM=200",
    "Z2_IPV4=0",
    "Z2_IPV6=0",
    "Z2_RULES=0",
    "Z2_EXPECTED_RULES=0",
    "Z2_IPV4_RULES=0",
    "Z2_IPV6_RULES=0",
    "Z2_RULESET_VERIFIED=1",
    "Z2_NFQUEUE=0",
    "Z2_QUEUE_BYPASS=0",
    "Z2_UPDATE_BLOCKED=0",
    "Z2_UNINSTALL_TOMBSTONE=1",
    "Z2_LIFECYCLE_STATE=idle",
    "Z2_LIFECYCLE_OWNER_KIND=none",
    "Z2_CHAINS=0",
    "Z2_ANCHORS=0",
    "Z2_ERROR_SCHEMA=1",
    "Z2_ERROR_STATUS=ERROR",
    "Z2_ERROR_DOMAIN=STATUS",
    "Z2_ERROR_STAGE=STATUS_QUERY",
    "Z2_ERROR_CODE=STATUS_DEGRADED",
    "Z2_ERROR_DETAIL=Service state is degraded; inspect the lifecycle log for full details",
    "Z2_COMPLETE=1",
)

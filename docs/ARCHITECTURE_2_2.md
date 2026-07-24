# Zapret2 2.2.0 — Architecture Redesign

Status: implemented in 2.2.0. This document records the analysis findings that
motivated the redesign, the design principles adopted, and the concrete changes.

## 1. Why

Eleven independent code-analysis passes over 2.1.5 (module shell layer, Android
app, state files, tests) converged on the same diagnosis: the architecture had
accreted layers that re-prove facts already proven, and kept machinery for data
formats nothing produces anymore.

Key numbers from the analysis (2.1.5 baseline):

| Finding | Measured |
|---|---|
| `common.sh` size | 3802 lines, 164 functions |
| Legacy direct-rule migration (`legacy_*`) | ~665 lines, executed unconditionally on **every** start and stop |
| Track-journal WAL validator/reaper | ~324 lines with **zero producers** in production code |
| `firewall-teardown.wal` reader | reader/deleter only — no writer anywhere |
| Dead function cluster | 5 functions / 82 lines |
| Boot: lifecycle lock acquire/release cycles | 2 (recovery pass + start pass) |
| Boot: `getprop sys.boot_completed` busy-wait | 1 fork/second, typically 10–40 forks |
| Warm start: compiled-artifact full parses | 5–6 per start |
| Warm start: `sha256sum` invocations | ~7 (preset ×3, runtime.ini ×3, artifact ×1) |
| Warm start: `install-generation.meta` reads | up to 4 (4 stat forks + `wc -c` each) |
| Stop: `restore_status_facts` calls | 3 reads of the same status file |
| Stop: owner-state reads | ~6 × ≈7 forks ≈ 42 forks for one 35-line file |
| Stop/start: full `/proc` scans | 2–3 per operation |
| Full rollback: global `sync` calls | 8 — violating the contract documented in `common.sh` itself |
| Purge: recovery-artifact audits in `uninstall.sh` | 5 |
| Preset change from the app | 11 root round-trips, 6 full `runtime.ini` parses by 4 parser implementations |

Two correctness defects were also found:

1. **Crash residue blocks uninstall.** Ephemeral files (`firewall-batch.*`,
   `z2-ports.*`, …) written directly into `$STATE_DIR` are not covered by
   `enumerate_recovery_artifacts` nor the uninstall cleanup loop; after a crash
   they trip the "unknown child" guard and block uninstall instead of being
   swept.
2. **Purge ordering.** `zapret-purge.sh` published the `remove` marker *after*
   running `uninstall.sh`, forcing the long uninstall branch and leaving the
   destructive `rm -rf` fenced by nothing.

## 2. Principles

P1. **A fact is proven once per transaction.** A transaction is one lock cycle.
    Within it, each state file is read once and cached in shell globals;
    verification of an invariant happens at exactly one layer. Postconditions
    proven by a callee are not re-proven by the caller.

P2. **No consumers for formats nothing produces.** Code that only validates,
    classifies, or retires a file format with no live writer is deleted, not
    hardened.

P3. **Reboot is the migration barrier.** Magisk/KernelSU/APatch activate
    updated module files only after a reboot, and iptables rules do not survive
    a reboot. Therefore the running module never coexists with firewall state
    from an older module version, and no runtime migration machinery is needed.

P4. **Ephemeral state is disposable by construction.** Scratch files live in
    `$STATE_DIR/tmp/`, which every entry point may sweep wholesale. Recovery
    logic never has to reason about their names.

P5. **Root-manager canon.** `customize.sh` stages and validates; `service.sh`
    waits for boot and delegates; `action.sh` performs the user action;
    `uninstall.sh` cleans owned state. Destructive removal is fenced by the
    `remove` marker published *before* teardown begins.

## 3. Changes in 2.2.0 (module)

- **Removed the legacy direct-rule migration** (`legacy_*` family, its snapshot
  transaction, markers, and the calls in start/stop/full-rollback). Justified
  by P3. `uninstall.sh` still deletes the old marker file if present.
- **Removed the track-journal apparatus** (grammar validator, liveness
  classifiers, reapers) and the `firewall-teardown.wal` reader — P2. The
  firewall layer is WAL-free by design (`firewall-reconciler.sh` header);
  interrupted publications are recovered by re-running cleanup under the lock.
- **Removed the dead cluster**: `republish_owner_ipv6_inactive`,
  `owner_load_generation_fields`, `owner_loaded_generation_for_write`,
  `trim_config_value`, `retire_installer_ephemeral_track_journals`.
- **Ephemeral workspace** (`$STATE_DIR/tmp/`, 0700 root): all PID-suffixed
  scratch files (`firewall-batch.*`, `firewall-cleanup.*`,
  `firewall-restore.*.error`, `z2-ports.*`, `preset-preflight.*`,
  `preset-preview.*`) moved there. Boot recovery and uninstall remove the
  directory wholesale; the unknown-child guard ignores it. Fixes defect 1.
- **Single boot pass**: when autostart is enabled, `service.sh` no longer runs
  its own lock+audit recovery cycle — `zapret-start.sh` performs the identical
  audit under its own lock moments later. The standalone recovery pass remains
  for the autostart-disabled path. Boot wait uses `resetprop -w` when available
  instead of a 1 Hz `getprop` fork loop.
- **Transaction-scoped caches** in `common.sh` for `read_owner_state`,
  `read_install_generation_meta` and status facts, invalidated by the
  corresponding writers in the same process. Callers that re-read for no
  reason were collapsed (P1).
- **Warm-start dedup**: one compiled-artifact binding check at entry plus one
  TOCTOU re-check immediately before daemon launch (was 3); metadata parsed
  once (was 5–6); receipt writer reuses the hashes the checker just computed;
  `prepare_private_runtime_file` runs once per file; the write-only
  `nfqws2.cmdline` artifact is no longer produced; pidfile wait polls at
  100 ms.
- **Stop dedup**: status facts restored once, owner state read once via the
  cache, `/proc` scanned once, the firewall-absence postcondition of
  `z2_fw_apply_cleanup` is trusted instead of re-proven, the unused
  `runtime.ini` parse and the dead `audit_owned_firewall_for_cleanup` argument
  are gone.
- **Purge/uninstall**: `zapret-purge.sh` publishes the `remove` marker *before*
  invoking `uninstall.sh` — the fence commits the twice-confirmed purge, blocks
  concurrent starts throughout the destruction, and routes uninstall onto the
  short manager-remove branch (so the tombstone long path with its repeated
  audits no longer runs during a purge); the duplicate status-snapshot
  deletion is removed and `pm clear` failure after a successful purge is a
  warning, not a failure exit. The `read_install_generation_meta` shadow in
  `uninstall.sh` was kept deliberately: it authenticates against `MODPATH`,
  not `MODDIR`. Fixes defect 2.
- **Full rollback**: the duplicated firewall audit collapsed and the retired
  legacy phase became a pure journal advance kept for resume compatibility.
  The `sync` barriers were *kept*: they implement the write-ahead ordering of
  the hosts-preservation transaction, which the `common.sh` durability
  contract explicitly assigns to the dedicated mutation scripts (the analysis
  finding that they violated the contract was a misreading).
- **`customize.sh`**: one validation loop and one filesystem traversal for
  permission normalization (was two loops and three traversals).

## 4. Changes in 2.2.0 (app)

- **Main-thread root I/O fixed**: environment reconciliation now runs on
  `Dispatchers.IO`; previously a cold start could block the main thread on the
  root transport for up to 30 s.
- **Status protocol negotiation is cached**: the controller remembers the
  highest protocol version the module answered with instead of re-walking
  v6→v1 on every refresh.

## 5. Deferred (designed, not shipped in 2.2.0)

- **Single-endpoint preset application.** The app currently performs the
  preset transaction step-by-step (11 root round-trips, duplicate parsers on
  both sides of the boundary). The target design is one module endpoint
  (`apply-preset <name>`) returning a typed receipt, with the app reduced to a
  pure client. This moves the Kotlin/shell boundary and is scheduled separately
  to keep 2.2.0 reviewable.
- **App decomposition**: splitting `ServiceLifecycleController` /
  `UpdateManager` / `ControlViewModel`, DI for the privileged layer, moving
  long-running installs to WorkManager, replacing source-grep policy tests
  with lint rules and behavioral tests.

## 6. Compatibility

- Update path from 2.1.x: state files (`owner.meta` v8, `runtime.ini`,
  `install-generation.meta`, status snapshot) are unchanged. Obsolete files
  from older versions (`legacy-direct-rules.migrated`, `firewall-teardown.wal`,
  track journals, `nfqws2.cmdline`) are deleted on sight by boot recovery and
  uninstall.
- Status wire protocols (v1–v6), the error envelope, and all `Z2_*` machine
  outputs are unchanged; the Android app from 2.1.x keeps working against a
  2.2.0 module and vice versa.

---
name: build-zapret2-locally
description: Build, verify, and optionally publish Zapret2 stable artifacts, or build development artifacts from the current worktree, entirely on the trusted local machine. Use for stable/release/production builds, dev/development/test builds, APK or Magisk ZIP assembly, signing verification, stable Forgejo publication, or diagnosis of either local build channel. Forgejo Actions is background validation only.
---

# Build Zapret2 Locally

## Commit readiness and stable scope

A commit is a readiness boundary. Never create an intermediate, checkpoint, or
partially verified commit. During a stable release, inspect the entire shared
working tree, finish and validate every intentional source change, and include
every ready change regardless of who authored it. If an intentional source
change is incomplete or unsafe, stop the stable release until it is resolved
instead of hiding, stashing, or excluding it. Generated artifacts, caches,
signing material, credentials, and other local-only state are never part of the
source commit.

## Protect signing state

- Treat `/home/codex-pve/.config/zapret2-signing` as durable private state.
- Never delete, move, regenerate, overwrite, commit, upload, or print its contents.
- Read individual JSON values only with `jq`; never enable shell tracing.
- Require mode `700` on the directory and `600` on confidential files.
- Use the existing production signer for both channels so dev APKs remain
  install-compatible with stable. Never substitute another signer.
- Read signing values from `signing-secrets.json`; the historical GitHub-named
  private file is not part of the Forgejo release contract.

## Select the channel

Use `stable` for a production candidate. First inspect every tracked and
untracked path and treat all intentional source changes as release scope
regardless of author. Finish and validate them all or stop. Stage every reviewed,
ready source change by explicit path, review the staged diff, and create one
concise commit only after the complete source task and its required checks have
succeeded. Fetch and integrate `origin/main` without force-pushing, repeat the
relevant verification, push the final snapshot, and then require a clean `main`
exactly equal to `origin/main`. Build that immutable commit, run every local
qualification, produce release-bound `update.json`, and allow publication only
after explicit authorization.

Use `dev` for testing the current worktree, including non-ignored uncommitted and
untracked source files. Snapshot without modifying the worktree, assign a unique
`v<VERSION>-dev.<timestamp>.<sha>` identity, run the same local qualifications, and
produce production-signed APK/ZIP artifacts plus `build-info.json`. Never create
  `update.json`, a tag, a Forgejo Release, or `Latest` from dev output.

## Build locally

Run exactly one channel:

```bash
SKILL_DIR=/home/codex-pve/magisk-zapret2/.codex/skills/build-zapret2-locally

"$SKILL_DIR/scripts/build-local-release.sh" \
  --channel stable \
  --repo /home/codex-pve/magisk-zapret2

"$SKILL_DIR/scripts/build-local-release.sh" \
  --channel dev \
  --repo /home/codex-pve/magisk-zapret2
```

Require source/release policy, full shell tests, Android unit tests, release lint,
package validation, checksums, and production signer verification in both channels.
Keep only the latest successful default output per channel:

- stable: `.artifacts/local-releases/v<VERSION>/`
- dev: `.artifacts/dev-builds/v<VERSION>-dev.<timestamp>.<sha>/`

Report the channel, source commit and snapshot digest, version, output directory,
checksums, qualification results, and public signer digest.

## Publish stable only

Publish only after the user explicitly asks to release/deploy stable:

```bash
/home/codex-pve/magisk-zapret2/.codex/skills/build-zapret2-locally/scripts/publish-stable-release.sh \
  --repo /home/codex-pve/magisk-zapret2
```

Require an increasing `versionCode`, an absent immutable `v<VERSION>` tag/Release,
the exact pushed source SHA, five exact assets, and the production signer. Create a
non-draft, non-prerelease Release, mark it `Latest`, then verify the remote tag,
flags, bytes, update metadata, clean worktree, and preserved signing state.

Write the stable change list from the complete range after the previous stable
tag plus the final reviewed working-tree changes. Include meaningful user-visible
work from every author; do not describe only the most recent agent's task.

Treat Forgejo Actions as independent background validation. Observe its run after a
push but never wait for it as a build or publication prerequisite. Never let Actions
create or mutate tags or Releases.

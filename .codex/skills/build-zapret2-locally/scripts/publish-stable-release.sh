#!/usr/bin/env bash
# Publish a locally qualified build as the canonical stable Forgejo release.
set -euo pipefail
umask 077

readonly DEFAULT_SIGNING_DIR="/home/codex-pve/.config/zapret2-signing"
readonly DEFAULT_TOKEN_FILE="/home/codex-pve/.config/forgejo/release-token"
readonly DEFAULT_SDK_DIR="/opt/android-sdk"
readonly FORGEJO_API_ROOT="https://git.zapret.moe/api/v1"
readonly RELEASE_REPO="zapretdiscordyoutube/magisk-zapret2"
readonly RELEASE_WEB_ROOT="https://git.zapret.moe/$RELEASE_REPO"

usage() {
    cat >&2 <<'USAGE'
Usage: publish-stable-release.sh [options]

Options:
  --repo PATH          Repository checkout (default: current directory)
  --signing-dir PATH   Durable production signing directory
  --token-file PATH    Forgejo write:repository token file
  --artifacts PATH     Qualified build directory
                       (default: REPO/.artifacts/local-releases/vVERSION)
  -h, --help           Show this help

The source commit must be the clean, pushed origin/main tip. Run
build-local-release.sh --channel stable first. This command creates an immutable
vVERSION Forgejo release, verifies that it is Latest, and uploads the APK, module
ZIP, checksum sidecars, and update.json.
USAGE
}

fail() {
    printf 'stable release publish: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        fail "required command is unavailable: $1"
}

normalize_digest() {
    tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]'
}

repo_arg="$PWD"
signing_arg="$DEFAULT_SIGNING_DIR"
token_arg="$DEFAULT_TOKEN_FILE"
artifacts_arg=""

while (($#)); do
    case "$1" in
        --repo|--signing-dir|--token-file|--artifacts)
            (($# >= 2)) || fail "missing value for $1"
            case "$1" in
                --repo) repo_arg="$2" ;;
                --signing-dir) signing_arg="$2" ;;
                --token-file) token_arg="$2" ;;
                --artifacts) artifacts_arg="$2" ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

for command_name in git curl jq stat sha256sum awk sed sort tr find mktemp unzip grep cmp; do
    require_command "$command_name"
done

[[ -f "$token_arg" && ! -L "$token_arg" && -s "$token_arg" ]] ||
    fail "Forgejo release token file is missing or unsafe"
[[ "$(stat -c '%a' "$token_arg")" == "600" ]] ||
    fail "Forgejo release token file mode must be 600"
IFS= read -r FORGEJO_TOKEN < "$token_arg"
readonly FORGEJO_TOKEN
[[ -n "$FORGEJO_TOKEN" && "$FORGEJO_TOKEN" != *[[:space:]]* ]] ||
    fail "Forgejo release token is malformed"

api_status() {
    local method="$1" path="$2" output="$3" body_file="${4:-}"
    local -a request=(
        curl -sS -o "$output" -w '%{http_code}'
        --proto '=https'
        -X "$method"
        -H "Authorization: token $FORGEJO_TOKEN"
        -H 'Accept: application/json'
    )
    if [[ -n "$body_file" ]]; then
        request+=(
            -H 'Content-Type: application/json'
            --data-binary "@$body_file"
        )
    fi
    request+=("$FORGEJO_API_ROOT$path")
    "${request[@]}"
}

api_json() {
    local method="$1" path="$2" output="$3" body_file="${4:-}"
    local status
    status="$(api_status "$method" "$path" "$output" "$body_file")" ||
        fail "Forgejo API request failed: $method $path"
    case "$method:$status" in
        GET:200|POST:201|PATCH:200) ;;
        *) fail "Forgejo API rejected $method $path with HTTP $status" ;;
    esac
}

api_optional_get() {
    local path="$1" output="$2" status
    status="$(api_status GET "$path" "$output")" ||
        fail "Forgejo API request failed: GET $path"
    case "$status" in
        200) return 0 ;;
        404) return 1 ;;
        *) fail "Forgejo API rejected GET $path with HTTP $status" ;;
    esac
}

[[ -d "$repo_arg" && ! -L "$repo_arg" ]] ||
    fail "repository path is not a regular directory"
REPO="$(cd -- "$repo_arg" && pwd -P)"
readonly REPO
[[ "$(git -C "$REPO" rev-parse --show-toplevel)" == "$REPO" ]] ||
    fail "--repo must identify the repository root"
[[ -z "$(git -C "$REPO" status --short)" ]] ||
    fail "repository worktree is not clean"
[[ "$(git -C "$REPO" branch --show-current)" == "main" ]] ||
    fail "current branch must be main"

SOURCE_SHA="$(git -C "$REPO" rev-parse HEAD)"
readonly SOURCE_SHA
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source commit"
REMOTE_SHA="$(
    git -C "$REPO" ls-remote --heads origin refs/heads/main |
        awk 'NR == 1 { print $1 }'
)"
readonly REMOTE_SHA
[[ "$REMOTE_SHA" == "$SOURCE_SHA" ]] ||
    fail "HEAD is not the exact pushed origin/main commit"

VERSION_METADATA="$(sh "$REPO/tools/release-version.sh")"
readonly VERSION_METADATA
VERSION="$(printf '%s\n' "$VERSION_METADATA" | sed -n 's/^version=//p')"
VERSION_CODE="$(printf '%s\n' "$VERSION_METADATA" | sed -n 's/^version_code=//p')"
VERSION_TAG="$(printf '%s\n' "$VERSION_METADATA" | sed -n 's/^version_tag=//p')"
readonly VERSION VERSION_CODE VERSION_TAG
[[ -n "$VERSION" && -n "$VERSION_CODE" && "$VERSION_TAG" == "v$VERSION" ]] ||
    fail "canonical release metadata is incomplete"

if [[ -n "$artifacts_arg" ]]; then
    if [[ "$artifacts_arg" == /* ]]; then
        ARTIFACT_DIR="$artifacts_arg"
    else
        ARTIFACT_DIR="$REPO/$artifacts_arg"
    fi
else
    ARTIFACT_DIR="$REPO/.artifacts/local-releases/$VERSION_TAG"
fi
readonly ARTIFACT_DIR
[[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] ||
    fail "qualified artifact directory is missing or unsafe: $ARTIFACT_DIR"

ZIP_NAME="zapret2-magisk-$VERSION_TAG.zip"
APK_NAME="zapret2-control-$VERSION_TAG.apk"
UPDATE_NAME="update.json"
readonly ZIP_NAME APK_NAME UPDATE_NAME
readonly ZIP_PATH="$ARTIFACT_DIR/$ZIP_NAME"
readonly APK_PATH="$ARTIFACT_DIR/$APK_NAME"
readonly UPDATE_PATH="$ARTIFACT_DIR/$UPDATE_NAME"
readonly ZIP_SUM_PATH="$ZIP_PATH.sha256"
readonly APK_SUM_PATH="$APK_PATH.sha256"

expected_names=(
    "$ZIP_NAME"
    "$ZIP_NAME.sha256"
    "$APK_NAME"
    "$APK_NAME.sha256"
    "$UPDATE_NAME"
)
for expected_name in "${expected_names[@]}"; do
    [[ -f "$ARTIFACT_DIR/$expected_name" &&
        ! -L "$ARTIFACT_DIR/$expected_name" &&
        -s "$ARTIFACT_DIR/$expected_name" ]] ||
        fail "required release asset is missing or unsafe: $expected_name"
done

mapfile -d '' artifact_entries < <(
    find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -print0
)
((${#artifact_entries[@]} == ${#expected_names[@]})) ||
    fail "artifact directory must contain exactly the five release assets"

(
    cd "$ARTIFACT_DIR"
    sha256sum -c "$ZIP_NAME.sha256"
    sha256sum -c "$APK_NAME.sha256"
) >/dev/null || fail "artifact checksum verification failed"
unzip -tq "$ZIP_PATH" >/dev/null || fail "module ZIP integrity check failed"
[[ "$(unzip -p "$ZIP_PATH" module.prop | sed -n 's/^version=//p')" == "$VERSION_TAG" ]] ||
    fail "module ZIP version does not match $VERSION_TAG"
[[ "$(unzip -p "$ZIP_PATH" module.prop | sed -n 's/^versionCode=//p')" == "$VERSION_CODE" ]] ||
    fail "module ZIP versionCode does not match $VERSION_CODE"

EXPECTED_ZIP_URL="$RELEASE_WEB_ROOT/releases/download/$VERSION_TAG/$ZIP_NAME"
EXPECTED_CHANGELOG="$RELEASE_WEB_ROOT/releases/tag/$VERSION_TAG"
readonly EXPECTED_ZIP_URL EXPECTED_CHANGELOG
jq -e \
    --arg version "$VERSION_TAG" \
    --argjson version_code "$VERSION_CODE" \
    --arg zip_url "$EXPECTED_ZIP_URL" \
    --arg changelog "$EXPECTED_CHANGELOG" \
    'keys == ["changelog", "version", "versionCode", "zipUrl"] and
     .version == $version and
     .versionCode == $version_code and
     .zipUrl == $zip_url and
     .changelog == $changelog' \
    "$UPDATE_PATH" >/dev/null ||
    fail "update.json does not describe this stable release exactly"

[[ -d "$signing_arg" && ! -L "$signing_arg" ]] ||
    fail "signing path is not a regular directory"
SIGNING_DIR="$(cd -- "$signing_arg" && pwd -P)"
readonly SIGNING_DIR
[[ "$(stat -c '%a' "$SIGNING_DIR")" == "700" ]] ||
    fail "signing directory mode must be 700"
readonly CERT_DIGEST_FILE="$SIGNING_DIR/apk-signing-cert-sha256.txt"
[[ -f "$CERT_DIGEST_FILE" && ! -L "$CERT_DIGEST_FILE" &&
    -s "$CERT_DIGEST_FILE" ]] ||
    fail "production signer digest file is missing or unsafe"
EXPECTED_CERT="$(normalize_digest < "$CERT_DIGEST_FILE")"
readonly EXPECTED_CERT
[[ "$EXPECTED_CERT" =~ ^[0-9A-F]{64}$ ]] ||
    fail "invalid production signer digest"

SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$DEFAULT_SDK_DIR}}"
readonly SDK_ROOT
APKSIGNER="$(
    find "$SDK_ROOT/build-tools" -mindepth 2 -maxdepth 2 -type f \
        -name apksigner -print | sort -V | tail -n 1
)"
readonly APKSIGNER
[[ -x "$APKSIGNER" ]] || fail "apksigner was not found"
VERIFY_OUTPUT="$("$APKSIGNER" verify --verbose --print-certs "$APK_PATH")"
ACTUAL_CERT="$(
    printf '%s\n' "$VERIFY_OUTPUT" |
        awk '
            /certificate SHA-256 digest:/ {
                digest = $0
                sub(/^.*certificate SHA-256 digest:[[:space:]]*/, "", digest)
                gsub(/:|[[:space:]]/, "", digest)
                print toupper(digest)
            }
        ' |
        sort -u
)"
readonly ACTUAL_CERT
[[ "${#ACTUAL_CERT}" -eq 64 && "$ACTUAL_CERT" == "$EXPECTED_CERT" ]] ||
    fail "APK signer does not match the production identity"

REMOTE_WORK="$(mktemp -d /tmp/zapret2-forgejo-release.XXXXXXXX)"
readonly REMOTE_WORK
cleanup() {
    case "$REMOTE_WORK" in
        /tmp/zapret2-forgejo-release.*)
            find "$REMOTE_WORK" -depth -delete
            ;;
    esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

REMOTE_TAG="$(
    git -C "$REPO" ls-remote --tags origin "refs/tags/$VERSION_TAG"
)" || fail "unable to inspect the remote release tag"
[[ -z "$REMOTE_TAG" ]] ||
    fail "immutable release tag already exists: $VERSION_TAG"

if api_optional_get "/repos/$RELEASE_REPO/releases/tags/$VERSION_TAG" \
    "$REMOTE_WORK/release-lookup.json"; then
    fail "immutable Forgejo Release already exists: $VERSION_TAG"
fi

if api_optional_get "/repos/$RELEASE_REPO/releases/latest" "$REMOTE_WORK/latest.json"; then
    LATEST_TAG="$(jq -er '.tag_name | strings' "$REMOTE_WORK/latest.json")"
    LATEST_UPDATE_URL="$(
        jq -er '
            [.assets[] | select(.name == "update.json")] |
            if length == 1 then .[0].browser_download_url
            else error("latest release update.json is not unique") end
        ' "$REMOTE_WORK/latest.json"
    )"
    case "$LATEST_UPDATE_URL" in
        "$RELEASE_WEB_ROOT/releases/download/"*) ;;
        *) fail "Latest release update.json points outside the Forgejo repository" ;;
    esac
    curl -fsS --proto '=https' --max-redirs 0 \
        -H "Authorization: token $FORGEJO_TOKEN" \
        "$LATEST_UPDATE_URL" > "$REMOTE_WORK/latest-update.json"
    LATEST_VERSION="$(jq -er '.version | strings' "$REMOTE_WORK/latest-update.json")"
    LATEST_VERSION_CODE="$(
        jq -er '.versionCode | select(type == "number" and floor == .)' \
            "$REMOTE_WORK/latest-update.json"
    )"
    [[ "$LATEST_VERSION" == "$LATEST_TAG" ]] ||
        fail "Latest release metadata does not match its tag"
    ((VERSION_CODE > LATEST_VERSION_CODE)) ||
        fail "versionCode $VERSION_CODE must exceed Latest versionCode $LATEST_VERSION_CODE"
fi

# Recheck immediately before the one-way publication boundary.
REMOTE_TAG="$(
    git -C "$REPO" ls-remote --tags origin "refs/tags/$VERSION_TAG"
)" || fail "unable to recheck the remote release tag"
[[ -z "$REMOTE_TAG" ]] ||
    fail "release tag appeared during validation: $VERSION_TAG"
if api_optional_get "/repos/$RELEASE_REPO/releases/tags/$VERSION_TAG" \
    "$REMOTE_WORK/release-recheck.json"; then
    fail "Forgejo Release appeared during validation: $VERSION_TAG"
fi

RELEASE_NOTES="$(
    printf 'Production build created locally from exact commit `%s`.\n\n' "$SOURCE_SHA"
    printf 'APK signing certificate SHA-256: `%s`.\n\n' "$ACTUAL_CERT"
    printf 'Forgejo Actions is an independent background validation and is not a publication dependency.'
)"
jq -n \
    --arg tag "$VERSION_TAG" \
    --arg target "$SOURCE_SHA" \
    --arg name "Zapret2 $VERSION" \
    --arg body "$RELEASE_NOTES" \
    '{tag_name:$tag, target_commitish:$target, name:$name, body:$body,
      draft:true, prerelease:false, hide_archive_links:false}' \
    > "$REMOTE_WORK/create-release.json"
api_json POST "/repos/$RELEASE_REPO/releases" \
    "$REMOTE_WORK/draft-release.json" "$REMOTE_WORK/create-release.json"
RELEASE_ID="$(jq -er '.id | numbers' "$REMOTE_WORK/draft-release.json")"
readonly RELEASE_ID

mkdir "$REMOTE_WORK/uploaded"
for expected_name in "${expected_names[@]}"; do
    ENCODED_NAME="$(jq -rn --arg value "$expected_name" '$value | @uri')"
    upload_status="$(
        curl -sS -o "$REMOTE_WORK/uploaded/$expected_name.json" -w '%{http_code}' \
            --proto '=https' \
            -X POST \
            -H "Authorization: token $FORGEJO_TOKEN" \
            -H 'Accept: application/json' \
            -F "attachment=@$ARTIFACT_DIR/$expected_name" \
            "$FORGEJO_API_ROOT/repos/$RELEASE_REPO/releases/$RELEASE_ID/assets?name=$ENCODED_NAME"
    )" || fail "upload failed for release asset: $expected_name"
    [[ "$upload_status" == "201" ]] ||
        fail "Forgejo rejected release asset $expected_name with HTTP $upload_status"
done

jq -n '{draft:false, prerelease:false}' > "$REMOTE_WORK/publish-release.json"
api_json PATCH "/repos/$RELEASE_REPO/releases/$RELEASE_ID" \
    "$REMOTE_WORK/published-release.json" "$REMOTE_WORK/publish-release.json"

api_json GET "/repos/$RELEASE_REPO/releases/tags/$VERSION_TAG" \
    "$REMOTE_WORK/verified-release.json"
PUBLISHED_RELEASE="$REMOTE_WORK/verified-release.json"
jq -e \
    --arg tag "$VERSION_TAG" \
    '(.draft | not) and
     (.prerelease | not) and
     .tag_name == $tag and
     ([.assets[].name] | sort) ==
       ["update.json",
        ("zapret2-control-" + $tag + ".apk"),
        ("zapret2-control-" + $tag + ".apk.sha256"),
        ("zapret2-magisk-" + $tag + ".zip"),
        ("zapret2-magisk-" + $tag + ".zip.sha256")]' \
    "$PUBLISHED_RELEASE" >/dev/null ||
    fail "published release does not satisfy the stable asset contract"

PUBLISHED_TAG_SHA="$(
    git -C "$REPO" ls-remote --tags origin "refs/tags/$VERSION_TAG" |
        awk 'NR == 1 { print $1 }'
)"
[[ "$PUBLISHED_TAG_SHA" == "$SOURCE_SHA" ]] ||
    fail "published tag does not target the exact source commit"

api_json GET "/repos/$RELEASE_REPO/releases/latest" "$REMOTE_WORK/latest-after.json"
[[ "$(jq -er '.tag_name' "$REMOTE_WORK/latest-after.json")" == "$VERSION_TAG" ]] ||
    fail "published stable release was not selected as Latest"

mkdir "$REMOTE_WORK/assets"
for expected_name in "${expected_names[@]}"; do
    asset_url="$(
        jq -er --arg name "$expected_name" '
            [.assets[] | select(.name == $name)] |
            if length == 1 then .[0].browser_download_url
            else error("release asset is not unique") end
        ' "$PUBLISHED_RELEASE"
    )"
    case "$asset_url" in
        "$RELEASE_WEB_ROOT/releases/download/$VERSION_TAG/"*) ;;
        *) fail "published release asset points outside the immutable release" ;;
    esac
    curl -fsS --proto '=https' --max-redirs 0 \
        -H "Authorization: token $FORGEJO_TOKEN" \
        "$asset_url" > "$REMOTE_WORK/assets/$expected_name"
    cmp -s "$ARTIFACT_DIR/$expected_name" "$REMOTE_WORK/assets/$expected_name" ||
        fail "remote asset bytes differ from the qualified local asset: $expected_name"
done

[[ -z "$(git -C "$REPO" status --short)" ]] ||
    fail "repository worktree changed during publication"
[[ "$(stat -c '%a' "$SIGNING_DIR")" == "700" ]] ||
    fail "signing directory permissions changed during publication"

RELEASE_URL="$(jq -er '.html_url' "$PUBLISHED_RELEASE")"
printf 'release_url=%s\n' "$RELEASE_URL"
printf 'source_commit=%s\n' "$SOURCE_SHA"
printf 'version=%s\n' "$VERSION"
printf 'version_code=%s\n' "$VERSION_CODE"
printf 'version_tag=%s\n' "$VERSION_TAG"
printf 'signer_sha256=%s\n' "$ACTUAL_CERT"
printf 'latest=verified\n'
printf 'remote_assets=verified\n'

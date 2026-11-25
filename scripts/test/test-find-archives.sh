#!/usr/bin/env bash
# Verify find-archives.sh names the upstream release carrying the Linux
# archives, prints nothing when none does, and fails on any API error rather
# than reporting that nothing was published. A stand-in gh serves JSON
# fixtures through the real jq, so the filters themselves are exercised.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fa="$here/../find-archives.sh"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
fail=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/fx"

# Serves $FX/<path with / and ? as _>.json for "gh api <path> --jq <filter>",
# and fails as gh does on an HTTP error when the path matches $FAIL, recording
# that it did so in $FIRED.
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] && [ "$3" = --jq ] || { echo "unexpected gh call: $*" >&2; exit 99; }
case "$2" in $FAIL) echo "$2" >> "$FIRED"; echo "gh: HTTP 502" >&2; exit 1 ;; esac
f="$FX/$(printf '%s' "$2" | tr '/?' '__').json"
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -r "$4" "$f"
EOF
chmod +x "$work/bin/gh"

r=repos_ggml-org_whisper.cpp
sha_v=96ec4d9823e9d0211944172da35f9f29134af990
sha_old=5eaee0cc9024eb9e9a99469199920c8b7f5cb9ec

# fixtures <assets of the v1.9.6 release, as a JSON array> <nightly>=<sha> ...
fixtures() {
    rm -f "$work/fx"/*.json
    local assets=$1 list='' pair
    shift
    printf '{"tag_name":"v1.9.6","assets":%s}\n' "$assets" > "$work/fx/${r}_releases_tags_v1.9.6.json"
    printf '{"sha":"%s"}\n' "$sha_v" > "$work/fx/${r}_commits_v1.9.6.json"
    for pair in "$@"; do
        printf '{"sha":"%s"}\n' "${pair#*=}" > "$work/fx/${r}_commits_${pair%%=*}.json"
        list="$list{\"tag_name\":\"${pair%%=*}\"},"
    done
    printf '[{"tag_name":"v1.9.6"},%s{"tag_name":"v1.9.5"}]\n' "$list" \
        > "$work/fx/${r}_releases_per_page=100.json"
}

# finds <label> <fail pattern> <expected stdout>
finds() {
    local out status=0
    out=$(PATH="$work/bin:$PATH" FX="$work/fx" FAIL="$2" FIRED=/dev/null \
        "$fa" v1.9.6 2>/dev/null) || status=$?
    if [ "$status" -eq 0 ] && [ "$out" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (exit %s)\n       expected: %s\n       got:      %s\n' \
            "$1" "$status" "$3" "$out"
        fail=1
    fi
}

# fails <label> <fail pattern>
# Passes only when the injected failure fired, so an exit for any other reason,
# such as a missing script, cannot satisfy it.
fails() {
    local status=0
    rm -f "$work/fired"
    PATH="$work/bin:$PATH" FX="$work/fx" FAIL="$2" FIRED="$work/fired" \
        "$fa" v1.9.6 >/dev/null 2>&1 || status=$?
    if [ ! -s "$work/fired" ]; then
        printf 'FAIL  %s (the injected failure never fired, exit %s)\n' "$1" "$status"
        fail=1
    elif [ "$status" -ne 0 ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected a non-zero exit, got 0)\n' "$1"
        fail=1
    fi
}

none='__no_failure__'
archives='[{"name":"whisper-bin-Win32.zip"},{"name":"whisper-bin-ubuntu-x64.tar.gz"}]'

# Every release up to v1.9.2 carried its own archives.
fixtures "$archives" b5907=$sha_old
finds "the semantic release carrying the archives is used" "$none" v1.9.6

# From v1.9.3 they sit on the nightly cut from the same commit.
fixtures '[]' b5910=$sha_v b5907=$sha_old
finds "the nightly at the same commit is used" "$none" b5910
fixtures '[]' b5911=0000000000000000000000000000000000000000 b5910=$sha_v
finds "a newer nightly at another commit is passed over" "$none" b5910

# v1.9.6 itself, whose release upstream published with no archives at all.
fixtures '[]' b5907=$sha_old b5454=d1be6fde110000000000000000000000000000000
finds "no release carrying the archives prints nothing" "$none" ''
fixtures '[]'
finds "no nightly at all prints nothing" "$none" ''

# An outage must never read as upstream having published nothing.
fixtures '[]' b5907=$sha_old
fails "a failed release lookup fails" '*/releases/tags/*'
fails "a failed lookup of the tag's commit fails" '*/commits/v1.9.6'
fails "a failed release listing fails" '*/releases?per_page=100'
fails "a failed lookup of a nightly's commit fails" '*/commits/b5907'

status=0; "$fa" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
    printf 'ok    a wrong argument count is a usage error\n'
else
    printf 'FAIL  a wrong argument count is a usage error (expected exit 2, got %s)\n' "$status"
    fail=1
fi

exit "$fail"

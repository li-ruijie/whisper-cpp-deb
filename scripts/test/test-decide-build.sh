#!/usr/bin/env bash
# Verify decide-build.sh chooses the version, the release tag, and whether to
# build, from the upstream tag, a packaging revision, and the deployed version.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
db="$here/../decide-build.sh"
fail=0

# decides <label> <tag> <revision> <deployed> <force> <expected stdout>
decides() {
    local out status=0
    out=$("$db" "$2" "$3" "$4" "$5" 2>/dev/null) || status=$?
    if [ "$status" -eq 0 ] && [ "$out" = "$6" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (exit %s)\n       expected: %s\n       got:      %s\n' \
            "$1" "$status" "$(printf '%s' "$6" | tr '\n' ' ')" "$(printf '%s' "$out" | tr '\n' ' ')"
        fail=1
    fi
}

# refuses <label> <expected exit> <tag> <revision> <deployed> <force>
refuses() {
    local status=0
    "$db" "$3" "$4" "$5" "$6" >/dev/null 2>&1 || status=$?
    if [ "$status" -eq "$2" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected exit %s, got %s)\n' "$1" "$2" "$status"
        fail=1
    fi
}

build() { printf 'version=%s\nrelease_tag=%s\nskip=false' "$1" "$2"; }
skip()  { printf 'version=%s\nrelease_tag=%s\nskip=true' "$1" "$2"; }

decides "a new upstream version builds" \
    v1.9.6 '' 1.9.5 false "$(build 1.9.6 v1.9.6)"
decides "nothing deployed yet builds" \
    v1.9.5 '' '' false "$(build 1.9.5 v1.9.5)"
decides "the deployed upstream version is skipped" \
    v1.9.5 '' 1.9.5 false "$(skip 1.9.5 v1.9.5)"
decides "a forced rebuild of the deployed version builds" \
    v1.9.5 '' 1.9.5 true "$(build 1.9.5 v1.9.5)"

# A revision ships a packaging change against an unchanged upstream version.
decides "a revision builds above the plain upstream version" \
    v1.9.5 1 1.9.5 false "$(build 1.9.5-1 v1.9.5-1)"
decides "a deployed revision is skipped" \
    v1.9.5 1 1.9.5-1 false "$(skip 1.9.5-1 v1.9.5-1)"
decides "a forced rebuild of a deployed revision builds" \
    v1.9.5 1 1.9.5-1 true "$(build 1.9.5-1 v1.9.5-1)"
decides "the next revision builds" \
    v1.9.5 2 1.9.5-1 false "$(build 1.9.5-2 v1.9.5-2)"

# The weekly run passes no revision. Once a revision is deployed it must skip
# the upstream version it was built from rather than rebuild it as 1.9.5,
# which apt sorts below 1.9.5-1, and must still build the next upstream one.
decides "a scheduled run skips the upstream version a revision was built from" \
    v1.9.5 '' 1.9.5-1 false "$(skip 1.9.5 v1.9.5)"
decides "a new upstream version builds over a deployed revision" \
    v1.9.6 '' 1.9.5-1 false "$(build 1.9.6 v1.9.6)"

# A version apt sorts below the deployed one would never be installed.
refuses "a revision below the deployed one is refused" 1 v1.9.5 1 1.9.5-2 false
refuses "a forced plain rebuild below a deployed revision is refused" 1 v1.9.5 '' 1.9.5-1 true
refuses "an older upstream version is refused" 1 v1.9.4 '' 1.9.5 false

refuses "a zero revision is refused" 1 v1.9.5 0 1.9.5 false
refuses "a revision with a leading zero is refused" 1 v1.9.5 01 1.9.5 false
refuses "a non-numeric revision is refused" 1 v1.9.5 x 1.9.5 false
refuses "a negative revision is refused" 1 v1.9.5 -1 1.9.5 false
refuses "a nightly tag is refused" 1 b4938 '' 1.9.5 false

status=0; "$db" v1.9.5 '' 1.9.5 >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
    printf 'ok    a wrong argument count is a usage error\n'
else
    printf 'FAIL  a wrong argument count is a usage error (expected exit 2, got %s)\n' "$status"
    fail=1
fi

exit "$fail"

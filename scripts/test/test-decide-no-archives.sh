#!/usr/bin/env bash
# Verify decide-no-archives.sh fails a run once for each release published with
# no Linux archives, skips the runs after that, and always fails a run that
# asked for a build.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dna="$here/../decide-no-archives.sh"
fail=0

# A scheduled run, Sunday 03:00 UTC.
now=$(date -u -d '2026-11-29T03:00:00Z' +%s)

# expect <label> <expected exit> <published> <now> <explicit>
expect() {
    local status=0
    "$dna" "$3" "$4" "$5" >/dev/null 2>&1 || status=$?
    if [ "$status" -eq "$2" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected exit %s, got %s)\n' "$1" "$2" "$status"
        fail=1
    fi
}

# The first run to see the release fails, so GitHub sends its failure email.
expect "a release published days ago fails" 1 2026-11-23T17:51:11Z "$now" false
expect "a release published minutes ago fails" 1 2026-11-29T02:50:00Z "$now" false
# A scheduled run that starts late is still inside the window.
expect "a release seen a week and an hour later still fails" 1 \
    2026-11-22T02:00:00Z "$now" false

# Every run after that has already reported it.
expect "a release past the window skips" 0 2026-11-21T02:59:59Z "$now" false
expect "a release reported weeks ago skips" 0 2026-10-06T17:39:17Z "$now" false

# A run that asked for a version, a revision, or a rebuild gets none.
expect "a run that asked for a build fails on an old release" 1 \
    2026-10-06T17:39:17Z "$now" true

expect "an empty publication time is a usage error" 2 '' "$now" false
expect "an unreadable publication time is a usage error" 2 null "$now" false
expect "a non-numeric current time is a usage error" 2 2026-10-06T17:39:17Z soon false
expect "an explicit flag other than true or false is a usage error" 2 \
    2026-10-06T17:39:17Z "$now" yes

status=0; "$dna" 2026-10-06T17:39:17Z "$now" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
    printf 'ok    a wrong argument count is a usage error\n'
else
    printf 'FAIL  a wrong argument count is a usage error (expected exit 2, got %s)\n' "$status"
    fail=1
fi

exit "$fail"

#!/usr/bin/env bash
# Decide what a run does when no upstream release carries the Linux archives
# for the tag it resolved, from the publication time of that tag's release,
# the current time in epoch seconds, and whether the run asked for a build.
# Exits 0 to skip, 1 to fail the run, and 2 on a usage error, giving the reason
# on stderr.
#
# Upstream cut v1.9.6 with no Linux archives and no nightly at its commit, and
# no later nightly can match it, so failing every run would turn every Sunday
# red until the next version. Skipping every run would let a permanent end to
# the archives go unnoticed, as GitHub emails on a failure and not on a notice.
# A run therefore fails while the release is under 8 days old and skips after
# that, so each release without archives fails exactly one scheduled run, the
# day beyond the week allowing for a late start. A release published within a
# day before a run fails that run and the next.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <published> <now> <explicit>" >&2
    exit 2
fi
published=$1 now=$2 explicit=$3

case "$now" in
    '' | *[!0-9]*) echo "the current time is in epoch seconds, got '$now'" >&2; exit 2 ;;
esac
case "$explicit" in
    true | false) ;;
    *) echo "explicit is true or false, got '$explicit'" >&2; exit 2 ;;
esac

# Skipping would hide that a run which asked for a version, a revision, or a
# rebuild did not get one.
if [ "$explicit" = true ]; then
    echo "this run asked for a build, and there are no archives to build from" >&2
    exit 1
fi

# date -d reads an empty string as midnight today, which would pass.
[ -n "$published" ] || { echo "no publication time given" >&2; exit 2; }
pub=$(date -u -d "$published" +%s 2>/dev/null) \
    || { echo "unreadable publication time '$published'" >&2; exit 2; }

age=$(( now - pub ))
days=$(( age / 86400 ))
if [ "$age" -lt $(( 8 * 86400 )) ]; then
    echo "released $days days ago, so this is the run that reports it" >&2
    exit 1
fi
echo "released $days days ago and reported by an earlier run, skipping" >&2

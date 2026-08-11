#!/usr/bin/env bash
# Verify package-base.sh produces a correct whisper-cpp package.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tag=v1.9.2
version=1.9.2
fail=0

assert_contains() {  # assert_contains <label> <haystack> <needle>
    if printf '%s\n' "$2" | grep -qF -- "$3"; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n       expected to find: %s\n' "$1" "$3"
        fail=1
    fi
}

assert_absent() {  # assert_absent <label> <haystack> <needle>
    if printf '%s\n' "$2" | grep -qF -- "$3"; then
        printf 'FAIL  %s\n       did not expect to find: %s\n' "$1" "$3"
        fail=1
    else
        printf 'ok    %s\n' "$1"
    fi
}

# Counts need equality, since a substring test would pass "7" against "70".
assert_equals() {  # assert_equals <label> <actual> <expected>
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$3" "$2"
        fail=1
    fi
}

curl -fsSL -o "$work/base.tar.gz" \
    "https://github.com/ggml-org/whisper.cpp/releases/download/${tag}/whisper-bin-ubuntu-x64.tar.gz"

# Capture stdout. The script's documented contract is that it prints the path it
# wrote, so asserting it here verifies that contract and keeps the stray path
# line out of the test output.
deb=$("$here/../package-base.sh" "$work/base.tar.gz" "$version" amd64 "$work")

assert_equals "prints the path it wrote" "$deb" "$work/whisper-cpp_${version}_amd64.deb"
[ -f "$deb" ] || { echo "FAIL  package-base.sh produced no .deb at $deb"; exit 1; }

control=$(dpkg-deb -f "$deb")
contents=$(dpkg-deb -c "$deb")

assert_contains "package name"        "$control" "Package: whisper-cpp"
assert_contains "version"             "$control" "Version: 1.9.2"
assert_contains "architecture"        "$control" "Architecture: amd64"
assert_contains "maintainer"          "$control" \
    "Maintainer: li-ruijie <1547237+li-ruijie@users.noreply.github.com>"
assert_contains "libgomp1 dependency" "$control" "libgomp1"
assert_contains "curl dependency"     "$control" "curl"
assert_contains "jq dependency"       "$control" "jq"
assert_contains "debian conflict"     "$control" "Conflicts: whisper.cpp-tools"

# llama-cpp needs libssl for its server. The whisper.cpp archive links no
# OpenSSL at all, measured with readelf on 2026-08-11, so copying that
# alternation across would declare a dependency nothing needs.
depends=$(printf '%s\n' "$control" | grep '^Depends:' || true)
assert_absent "no spurious OpenSSL dependency" "$depends" "libssl"

assert_contains "payload under /usr/lib" "$contents" "./usr/lib/whisper.cpp/whisper-cli"
assert_contains "bin symlink"            "$contents" \
    "./usr/bin/whisper-cli -> ../lib/whisper.cpp/whisper-cli"
assert_contains "root ownership"         "$contents" "root/root"
assert_contains "licence installed"      "$contents" "./usr/share/doc/whisper-cpp/copyright"

assert_equals "cuda backend absent" \
    "$(printf '%s\n' "$contents" | grep -c 'libggml-cuda' || true)" "0"
assert_equals "vulkan backend absent" \
    "$(printf '%s\n' "$contents" | grep -c 'libggml-vulkan' || true)" "0"
assert_equals "licence not left in libdir" \
    "$(printf '%s\n' "$contents" | grep -c 'usr/lib/whisper.cpp/LICENSE' || true)" "0"

# Exactly 7 tools are symlinked. Match the link target, not the path: dpkg-deb -c
# also lists the ./usr/bin/ directory itself, which would inflate a plain path
# match. Matching the target additionally proves each symlink points into the
# payload directory.
assert_equals "one symlink per allowlisted tool" \
    "$(printf '%s\n' "$contents" | grep -c -- '-> ../lib/whisper.cpp/' || true)" "7"

# The deprecation stubs and the test harnesses must stay out of /usr/bin. This is
# the assertion that stops /usr/bin/main appearing on every target machine.
for excluded in main bench test-vad test-parakeet test-common-utf8; do
    assert_equals "no /usr/bin/$excluded" \
        "$(printf '%s\n' "$contents" | grep -c "\./usr/bin/${excluded}\$" || true)" "0"
    assert_equals "$excluded retained in the payload directory" \
        "$(printf '%s\n' "$contents" | grep -c "\./usr/lib/whisper\.cpp/${excluded}\$" || true)" "1"
done

# Runtime check. libgomp1 is absent from a clean trixie, so fetch it unprivileged.
dpkg-deb -x "$deb" "$work/root"
( cd "$work" && apt-get download libgomp1 >/dev/null 2>&1 )
dpkg-deb -x "$work"/libgomp1_*.deb "$work/gomp"
gomp="$work/gomp/usr/lib/x86_64-linux-gnu"

direct=$(LD_LIBRARY_PATH="$gomp" "$work/root/usr/lib/whisper.cpp/whisper-cli" --help 2>&1 || true)
assert_contains "binary runs from its real path" "$direct" "usage:"

viasym=$(LD_LIBRARY_PATH="$gomp" "$work/root/usr/bin/whisper-cli" --help 2>&1 || true)
assert_contains "binary runs through the symlink" "$viasym" "usage:"

exit "$fail"

#!/usr/bin/env bash
# Verify smoke-test.sh accepts a sound tree and rejects a broken backend.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tag=v1.9.2
version=1.9.2
fail=0

report() {  # report <label> <expected-status> <actual-status>
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected exit %s, got %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

contains() {  # contains <label> <haystack> <needle>
    if printf '%s\n' "$2" | grep -qF -- "$3"; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n       expected to find: %s\n' "$1" "$3"
        fail=1
    fi
}

curl -fsSL -o "$work/base.tar.gz" \
    "https://github.com/ggml-org/whisper.cpp/releases/download/${tag}/whisper-bin-ubuntu-x64.tar.gz"
base=$("$here/../package-base.sh" "$work/base.tar.gz" "$version" amd64 "$work")

# libgomp1 is absent from a clean trixie, and the tools need it on the path.
( cd "$work" && apt-get download libgomp1 >/dev/null 2>&1 )
dpkg-deb -x "$work"/libgomp1_*.deb "$work/gomp"
export BACKEND_STUB_DIR="$work/gomp/usr/lib/x86_64-linux-gnu"

# One shared model directory across all three invocations below. Without this
# each run downloads ggml-tiny.en.bin again, roughly 78 MB a time.
export WHISPER_MODEL_DIR="$work/models"

# The base package alone must pass, since there is no backend to resolve.
status=0
out=$("$here/../smoke-test.sh" "$base" 2>&1) || status=$?
report "the base package alone passes" 0 "$status"
contains "it actually transcribed the sample" "$out" "ask not what your country"

# A backend that is not even an ELF object must be rejected.
printf 'not a real library' > "$work/broken.so"
brokendeb=$("$here/../package-vulkan.sh" "$work/broken.so" "$version" "$work")
status=0
"$here/../smoke-test.sh" "$base" "$brokendeb" >/dev/null 2>&1 || status=$?
report "a corrupt backend is rejected" 1 "$status"

# The real ABI guard. A backend can be a perfectly valid ELF and still fail to
# resolve against the base package, which is exactly what a ggml ABI mismatch
# looks like. ldd -r exits 0 in that case, so the greps over its output are the
# only thing standing between a broken build and the APT repository. The corrupt
# stub above never reaches them, since ldd -r exits 1 on a non-ELF file and the
# script bails at the earlier branch.
#
# The stand-in is compiled here rather than borrowed from the base package. An
# earlier version of this test reused libggml-cpu-haswell.so and relied on
# libgomp being absent from the host, which silently stopped working the moment
# anything pulled libgomp1 in as a transitive dependency, and the test then
# passed a backend it was supposed to reject. Compiling the stub makes both
# branches fire regardless of what the host happens to have installed.
if ! command -v gcc >/dev/null 2>&1; then
    echo "FAIL  gcc is required to build the ABI stub for this test" >&2
    exit 1
fi

mkdir -p "$work/abi"

# A throwaway library to link against and then delete, so the backend carries a
# DT_NEEDED for a soname that exists nowhere. That drives the missing-library
# branch. The undefined call drives the undefined-symbol branch.
printf 'int zzzz_present(void) { return 0; }\n' > "$work/abi/dummy.c"
gcc -shared -fPIC -o "$work/abi/libzzzz.so.1" -Wl,-soname,libzzzz.so.1 "$work/abi/dummy.c"
# -lzzzz resolves libzzzz.so at link time while the recorded DT_NEEDED comes
# from the soname, so the development symlink is required to link at all.
ln -sf libzzzz.so.1 "$work/abi/libzzzz.so"

cat > "$work/abi/stub.c" <<'CEOF'
extern int zzzz_present(void);
extern int a_symbol_no_library_provides(void);
int ggml_backend_reg(void) { return zzzz_present() + a_symbol_no_library_provides(); }
CEOF
gcc -shared -fPIC -o "$work/abi/libggml-vulkan.so" "$work/abi/stub.c" \
    -L"$work/abi" -Wl,--no-as-needed -lzzzz

# Remove the library it now records a dependency on.
rm -f "$work/abi/libzzzz.so.1" "$work/abi/libzzzz.so"

unresolvable=$("$here/../package-vulkan.sh" "$work/abi/libggml-vulkan.so" "$version" "$work/abi")

status=0
out=$("$here/../smoke-test.sh" "$base" "$unresolvable" 2>&1) || status=$?
report "an unresolvable backend is rejected" 1 "$status"
contains "the missing-library branch fires" "$out" \
    "the backend is missing a library"
contains "the undefined-symbol branch fires" "$out" \
    "the backend has undefined symbols against the base package"

# Argument validation.
status=0; "$here/../smoke-test.sh" >/dev/null 2>&1 || status=$?
report "no argument exits 2" 2 "$status"

exit "$fail"

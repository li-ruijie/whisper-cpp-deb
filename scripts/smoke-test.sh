#!/usr/bin/env bash
# Verify a whisper-cpp tree loads, that any backend resolves against it, and
# that a real transcription returns the expected text.
#
# BACKEND_STUB_DIR, when set, is appended to LD_LIBRARY_PATH. In the CUDA job it
# points at the toolkit stub directory, which supplies libcuda.so.1 in place of
# a real driver.
#
# WHISPER_MODEL_DIR, when already set, is honoured rather than overridden, so a
# caller running this repeatedly downloads the model once instead of per run.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 <base.deb> [backend.deb]" >&2
    exit 2
fi

# A build job that has checked out whisper.cpp should pass a file:// URL to its
# own samples/jfk.wav rather than refetching this. curl needs the scheme: a bare
# path is treated as a hostname and fails.
SAMPLE_URL=${SAMPLE_URL:-https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/samples/jfk.wav}
MODEL_ID=${MODEL_ID:-tiny.en}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for deb in "$@"; do
    dpkg-deb -x "$deb" "$work/root"
done

tree="$work/root/usr/lib/whisper.cpp"
export LD_LIBRARY_PATH="$tree${BACKEND_STUB_DIR:+:$BACKEND_STUB_DIR}"

status=0
found_backend=""

for backend in libggml-cuda.so libggml-vulkan.so; do
    [ -f "$tree/$backend" ] || continue
    found_backend=$backend
    echo "== resolving $backend against the base package =="
    # ldd -r performs relocation, so it reports undefined symbols rather than
    # only missing libraries. That is the ABI check this whole design rests on.
    if ! unresolved=$(ldd -r "$tree/$backend" 2>&1); then
        echo "ldd could not process the backend at all:" >&2
        printf '%s\n' "$unresolved" >&2
        exit 1
    fi
    # Print the whole list rather than only a verdict. The NCCL link in
    # llama-cpp-cuda was found by reading a passing test's output.
    printf '%s\n' "$unresolved"

    # Libraries the target machine supplies are expected to be absent here.
    # Anything else is a genuine fault.
    if printf '%s\n' "$unresolved" \
        | grep 'not found' \
        | grep -qvE 'libcuda\.so|libcudart\.so|libcublas\.so|libcublasLt\.so|libvulkan\.so'; then
        echo "the backend is missing a library" >&2
        status=1
    fi

    if printf '%s\n' "$unresolved" | grep -q 'undefined symbol'; then
        echo "the backend has undefined symbols against the base package" >&2
        status=1
    fi
done

# A backend package was passed but no backend shared object reached the tree,
# which means the loop above checked nothing at all. Without this the job passes
# on a package that ships the wrong path, or nothing.
if [ "$#" -eq 2 ] && [ -z "$found_backend" ]; then
    echo "a backend package was given but no backend landed in $tree" >&2
    ls -la "$tree" >&2
    exit 1
fi

echo "== fetching a model and a sample =="
export WHISPER_MODEL_DIR="${WHISPER_MODEL_DIR:-$work/models}"
"$work/root/usr/bin/whisper-model" download "$MODEL_ID"
curl -fsSL -o "$work/jfk.wav" "$SAMPLE_URL"

echo "== transcribing =="
model="$WHISPER_MODEL_DIR/ggml-${MODEL_ID}.bin"
if ! out=$("$work/root/usr/bin/whisper-cli" -m "$model" -f "$work/jfk.wav" 2>&1); then
    echo "whisper-cli failed to run:" >&2
    printf '%s\n' "$out" >&2
    exit 1
fi
printf '%s\n' "$out"

if ! printf '%s\n' "$out" | grep -qi 'ask not what your country'; then
    echo "the transcription did not contain the expected text" >&2
    status=1
fi

# The transcription above proves the tree works, but whisper-cli produces the
# same text on CPU, so on its own it cannot tell a working backend from one that
# silently declined to load. EXPECT_BACKEND makes the job assert which device
# actually did the work. The Vulkan job sets it, since mesa-vulkan-drivers gives
# that runner a real software device. The CUDA job cannot, as a runner with no
# NVIDIA hardware has nothing for the backend to select.
if [ -n "${EXPECT_BACKEND:-}" ]; then
    echo "== confirming the backend was selected =="
    if printf '%s\n' "$out" | grep -qi "using $EXPECT_BACKEND backend"; then
        printf '%s\n' "$out" | grep -i 'device\|backend' || true
    else
        echo "expected whisper to select the $EXPECT_BACKEND backend, and it did not" >&2
        echo "this means it fell back to CPU, which the transcription alone cannot show" >&2
        printf '%s\n' "$out" | grep -i 'device\|backend' >&2 || true
        status=1
    fi
fi

exit "$status"

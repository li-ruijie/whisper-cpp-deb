#!/usr/bin/env bash
# Verify whisper-audio.sh converts to the format whisper.cpp wants.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
wa="$here/../whisper-audio.sh"

assert_equals() {  # assert_equals <label> <actual> <expected>
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$3" "$2"
        fail=1
    fi
}

assert_contains() {  # assert_contains <label> <haystack> <needle>
    if printf '%s\n' "$2" | grep -qF -- "$3"; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n       expected to find: %s\n' "$1" "$3"
        fail=1
    fi
}

report() {  # report <label> <expected-status> <actual-status>
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected exit %s, got %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

command -v ffmpeg  >/dev/null 2>&1 || { echo "ffmpeg is required to run this test"  >&2; exit 2; }
command -v ffprobe >/dev/null 2>&1 || { echo "ffprobe is required to run this test" >&2; exit 2; }

probe() {  # probe <file> <entry>
    ffprobe -v error -select_streams a:0 -show_entries "stream=$2" \
        -of default=noprint_wrappers=1:nokey=1 "$1"
}

# Deliberately awkward source parameters, so a wrapper that merely copies the
# stream through cannot pass: 44.1 kHz, stereo, and a lossy codec.
ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=440:duration=1:sample_rate=44100" \
    -ac 2 -c:a libmp3lame "$work/sample.mp3"

cd "$work"

# The stdout contract: exactly the path written, nothing else.
out=$("$wa" sample.mp3)
assert_equals "prints the path it wrote" "$out" "sample.wav"
[ -f "$work/sample.wav" ] || { echo "FAIL  no output produced"; exit 1; }

assert_equals "sample rate is 16 kHz"      "$(probe sample.wav sample_rate)" "16000"
assert_equals "downmixed to mono"          "$(probe sample.wav channels)"    "1"
assert_equals "codec is PCM signed 16-bit" "$(probe sample.wav codec_name)"  "pcm_s16le"

# Refusing to clobber is the safe default.
status=0; "$wa" sample.mp3 >/dev/null 2>&1 || status=$?
report "refuses to overwrite without -f" 1 "$status"

status=0; "$wa" -f sample.mp3 >/dev/null 2>&1 || status=$?
report "overwrites with -f" 0 "$status"

# An explicit output path is honoured, including into a subdirectory.
out=$("$wa" sample.mp3 "$work/sub/named.wav")
assert_equals "honours an explicit output path" "$out" "$work/sub/named.wav"
assert_equals "explicit output is 16 kHz" "$(probe "$work/sub/named.wav" sample_rate)" "16000"

# A video container must work, which is the case -map 0:a:0 exists for.
ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc=duration=1:size=64x64:rate=10" \
    -f lavfi -i "sine=frequency=880:duration=1:sample_rate=48000" \
    -c:v libx264 -c:a aac -shortest "$work/clip.mp4"
out=$("$wa" clip.mp4)
assert_equals "extracts audio from a video container" "$out" "clip.wav"
assert_equals "video extraction is 16 kHz" "$(probe clip.wav sample_rate)" "16000"
assert_equals "video extraction is mono"   "$(probe clip.wav channels)"    "1"

# A file with no audio stream must fail loudly and leave nothing behind.
ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc=duration=1:size=64x64:rate=10" -c:v libx264 "$work/silent.mp4"
status=0; "$wa" silent.mp4 >/dev/null 2>&1 || status=$?
report "fails on a file with no audio stream" 1 "$status"
assert_equals "leaves no output behind on failure" \
    "$(ls "$work" | grep -c '^silent\.wav$' || true)" "0"

# No temporary file may survive any of the runs above.
assert_equals "leaves no temporary files" \
    "$(find "$work" -name '.whisper-audio*' | wc -l)" "0"

# Argument validation.
status=0; "$wa" >/dev/null 2>&1 || status=$?
report "no argument exits 2" 2 "$status"

status=0; "$wa" /nonexistent/file.mp3 >/dev/null 2>&1 || status=$?
report "a missing input exits 1" 1 "$status"

status=0; "$wa" sample.mp3 out.mp3 >/dev/null 2>&1 || status=$?
report "a non-wav output is refused" 2 "$status"

# The absent-ffmpeg path must give its own message rather than a bare
# "command not found". Invoke bash by absolute path rather than through the
# shebang: with PATH emptied, /usr/bin/env cannot find bash either, and the
# run would fail for that reason instead of the one under test. Everything
# before the ffmpeg check uses only shell builtins, so an empty PATH is
# survivable up to that point.
mkdir -p "$work/nobin"
err=$(PATH="$work/nobin" /bin/bash "$wa" sample.mp3 2>&1 || true)
assert_contains "names ffmpeg when it is absent" "$err" "ffmpeg is required"
assert_equals "the absent-ffmpeg run blames ffmpeg, not bash" \
    "$(printf '%s\n' "$err" | grep -ci 'env:\|bash' || true)" "0"

exit "$fail"

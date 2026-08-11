#!/usr/bin/env bash
# Convert any file ffmpeg can read into the 16 kHz mono PCM signed 16-bit WAV
# that whisper.cpp uses internally.
#
# whisper.cpp reads flac, mp3, ogg, and wav through its bundled miniaudio and
# stb_vorbis, and the release build links no libavformat, so m4a, opus, wma,
# and every video container are unreadable without this. Converting also lands
# the audio at WHISPER_SAMPLE_RATE, so miniaudio resamples nothing itself.
set -euo pipefail

self=${0##*/}

die() { printf '%s: %s\n' "$self" "$1" >&2; exit "${2:-1}"; }

usage() {
    cat <<USAGE
usage: $self [-f] <input> [output.wav]

Convert <input> to 16 kHz mono PCM signed 16-bit WAV, the format whisper.cpp
uses internally. Any format ffmpeg can read is accepted, including m4a, opus,
and video containers.

  -f    overwrite <output.wav> when it already exists

Without <output.wav> the output is the input's base name with a .wav
extension, written to the working directory. The path written is printed on
stdout, so it chains directly:

  whisper-cli -m "\$(whisper-model path base.en)" -f "\$($self recording.m4a)"
USAGE
}

force=0
while getopts ':fh' opt; do
    case "$opt" in
        f) force=1 ;;
        h) usage; exit 0 ;;
        \?) printf '%s: unknown option: -%s\n\n' "$self" "$OPTARG" >&2; usage >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage >&2
    exit 2
fi

input=$1
[ -f "$input" ] || die "no such file: $input"

command -v ffmpeg >/dev/null 2>&1 \
    || die "ffmpeg is required but is not installed (apt install ffmpeg)"

if [ "$#" -eq 2 ]; then
    output=$2
else
    base=${input##*/}
    output="${base%.*}.wav"
fi

case "$output" in
    *.wav) ;;
    *) die "the output must end in .wav, got '$output'" 2 ;;
esac

if [ -e "$output" ] && [ "$force" -ne 1 ]; then
    die "$output already exists (pass -f to overwrite)"
fi

# Convert into a temporary file in the output's own directory, then rename, so
# an interrupted run cannot leave a truncated WAV that looks complete. The
# temporary name carries no .wav suffix, which is why -f wav is passed
# explicitly rather than letting ffmpeg infer the container from the extension.
outdir=$(dirname "$output")
mkdir -p "$outdir"
tmp=$(mktemp "$outdir/.$self.XXXXXX") || die "could not create a temporary file"
trap 'rm -f "$tmp"' EXIT

# -map 0:a:0 takes the first audio stream, so video containers work and a file
# carrying no audio at all fails cleanly rather than producing an empty WAV.
if ! err=$(ffmpeg -nostdin -hide_banner -loglevel error -y \
        -i "$input" -map 0:a:0 -ar 16000 -ac 1 -c:a pcm_s16le -f wav "$tmp" 2>&1); then
    [ -n "$err" ] && printf '%s\n' "$err" >&2
    die "ffmpeg could not convert $input"
fi

[ -s "$tmp" ] || die "ffmpeg produced an empty file for $input"

mv -f "$tmp" "$output"
trap - EXIT
printf '%s\n' "$output"

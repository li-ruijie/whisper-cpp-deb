#!/usr/bin/env bash
# Verify whisper-model.sh downloads, verifies, updates, and removes models.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"; [ -n "${srv:-}" ] && kill "$srv" 2>/dev/null' EXIT

fail=0

assert_contains() {  # assert_contains <label> <haystack> <needle>
    if printf '%s\n' "$2" | grep -qF -- "$3"; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n       expected to find: %s\n' "$1" "$3"
        fail=1
    fi
}

assert_equals() {  # assert_equals <label> <actual> <expected>
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$3" "$2"
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

# A stub standing in for Hugging Face. It serves the two model repositories the
# test needs and sets X-Linked-ETag to the real SHA-256 of the payload, which is
# what the wrapper's update check reads.
cat > "$work/stub.py" <<'PYEOF'
import hashlib, http.server, json, os, sys

ROOT = sys.argv[1]

REPOS = {
    "ggerganov/whisper.cpp": ["ggml-tiny.bin", "ggml-base.en.bin"],
    "ggml-org/parakeet-GGUF": ["ggml-parakeet-tdt-0.6b-v3-f16.bin"],
    "ggml-org/whisper-vad": ["ggml-silero-v6.2.0.bin"],
    "akashmjn/tinydiarize-whisper.cpp": ["ggml-small.en-tdrz.bin"],
}

def payload(name):
    with open(os.path.join(ROOT, name), "rb") as fh:
        return fh.read()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _route(self):
        path = self.path
        if path.startswith("/api/models/"):
            repo = path[len("/api/models/"):]
            if repo not in REPOS:
                return None
            body = json.dumps(
                {"siblings": [{"rfilename": f} for f in REPOS[repo]]}
            ).encode()
            return ("json", body, None)
        # /<owner>/<name>/resolve/main/<file>
        parts = path.lstrip("/").split("/")
        if len(parts) == 5 and parts[2] == "resolve" and parts[3] == "main":
            name = parts[4]
            if not os.path.exists(os.path.join(ROOT, name)):
                return None
            data = payload(name)
            return ("blob", data, hashlib.sha256(data).hexdigest())
        return None

    def do_HEAD(self):
        r = self._route()
        if r is None:
            self.send_error(404)
            return
        kind, body, sha = r
        self.send_response(200)
        if kind == "blob":
            self.send_header("X-Linked-ETag", '"%s"' % sha)
            self.send_header("X-Linked-Size", str(len(body)))
            self.send_header("X-Repo-Commit", "0" * 40)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()

    def do_GET(self):
        r = self._route()
        if r is None:
            self.send_error(404)
            return
        kind, body, sha = r
        self.send_response(200)
        if kind == "blob":
            self.send_header("X-Linked-ETag", '"%s"' % sha)
            self.send_header("X-Linked-Size", str(len(body)))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
PYEOF

mkdir -p "$work/blobs"
printf 'tiny model payload v1' > "$work/blobs/ggml-tiny.bin"
printf 'base.en model payload' > "$work/blobs/ggml-base.en.bin"
printf 'parakeet payload'      > "$work/blobs/ggml-parakeet-tdt-0.6b-v3-f16.bin"
printf 'silero payload'        > "$work/blobs/ggml-silero-v6.2.0.bin"
printf 'tdrz payload'          > "$work/blobs/ggml-small.en-tdrz.bin"

port=8731
python3 "$work/stub.py" "$work/blobs" "$port" &
srv=$!

# Wait for the stub rather than sleeping blindly.
for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$port/api/models/ggml-org/whisper-vad" >/dev/null 2>&1 && break
    sleep 0.1
done

export WHISPER_HF_ENDPOINT="http://127.0.0.1:$port"
export WHISPER_MODEL_DIR="$work/models"
wm="$here/../whisper-model.sh"

# list reaches every one of the four families, which is what proves the sources
# table is iterated rather than only its first row.
out=$("$wm" list)
assert_contains "list shows whisper models"  "$out" "tiny"
assert_contains "list shows parakeet models" "$out" "parakeet-tdt-0.6b-v3-f16"
assert_contains "list shows vad models"      "$out" "silero-v6.2.0"
assert_contains "list shows tdrz models"     "$out" "small.en-tdrz"

# Identifiers must have the ggml- prefix and .bin suffix stripped.
assert_equals "identifiers are stripped" \
    "$(printf '%s\n' "$out" | grep -c 'ggml-' || true)" "0"

# download writes the model, the sidecar, and no leftover .part file.
"$wm" download tiny >/dev/null
assert_equals "model written" \
    "$(cat "$work/models/ggml-tiny.bin")" "tiny model payload v1"
[ -f "$work/models/ggml-tiny.bin.sha256" ] \
    && printf 'ok    sidecar written\n' \
    || { printf 'FAIL  sidecar written\n'; fail=1; }
assert_equals "no .part left behind" \
    "$(find "$work/models" -name '*.part' | wc -l)" "0"

side=$(cat "$work/models/ggml-tiny.bin.sha256")
expected_sha=$(sha256sum "$work/blobs/ggml-tiny.bin" | cut -d' ' -f1)
assert_contains "sidecar records the hash" "$side" "sha256=$expected_sha"
assert_contains "sidecar records the url"  "$side" "url=http://127.0.0.1:$port/"

# path prints somewhere usable from command substitution.
assert_equals "path prints the model file" \
    "$("$wm" path tiny)" "$work/models/ggml-tiny.bin"

# list marks what is installed.
out=$("$wm" list)
assert_contains "list marks installed models" "$out" "installed"

# verify passes on an intact model and fails on a corrupted one.
status=0; "$wm" verify tiny >/dev/null 2>&1 || status=$?
report "verify passes on an intact model" 0 "$status"

printf 'corrupted' > "$work/models/ggml-tiny.bin"
status=0; "$wm" verify tiny >/dev/null 2>&1 || status=$?
report "verify fails on a corrupted model" 1 "$status"

# Restore, then confirm update is a no-op when the remote has not moved.
"$wm" download tiny >/dev/null 2>&1 || true
rm -f "$work/models/ggml-tiny.bin" "$work/models/ggml-tiny.bin.sha256"
"$wm" download tiny >/dev/null
out=$("$wm" update tiny)
assert_contains "update is a no-op when unchanged" "$out" "up to date"

# Move the remote, then confirm update notices and refetches. This is the whole
# point of the wrapper, and upstream's script cannot do it at all.
printf 'tiny model payload v2 which is longer' > "$work/blobs/ggml-tiny.bin"
out=$("$wm" update tiny)
assert_contains "update refetches a changed model" "$out" "updating"
assert_equals "updated content landed" \
    "$(cat "$work/models/ggml-tiny.bin")" "tiny model payload v2 which is longer"

new_sha=$(sha256sum "$work/blobs/ggml-tiny.bin" | cut -d' ' -f1)
assert_contains "sidecar was rewritten" \
    "$(cat "$work/models/ggml-tiny.bin.sha256")" "sha256=$new_sha"

# A bare update covers every installed model.
"$wm" download silero-v6.2.0 >/dev/null
printf 'silero payload v2' > "$work/blobs/ggml-silero-v6.2.0.bin"
out=$("$wm" update)
assert_contains "bare update reaches the vad family" "$out" "silero-v6.2.0"
assert_equals "bare update refetched it" \
    "$(cat "$work/models/ggml-silero-v6.2.0.bin")" "silero payload v2"

# A missing sidecar must self-heal by rehashing rather than failing.
rm -f "$work/models/ggml-tiny.bin.sha256"
status=0; out=$("$wm" update tiny) || status=$?
report "update survives a missing sidecar" 0 "$status"
assert_contains "missing sidecar is recreated" \
    "$(cat "$work/models/ggml-tiny.bin.sha256")" "sha256="

# remove takes the sidecar with it, so no orphan is left behind.
"$wm" remove tiny >/dev/null
assert_equals "remove deletes the model" \
    "$(ls "$work/models" | grep -c '^ggml-tiny.bin$' || true)" "0"
assert_equals "remove deletes the sidecar" \
    "$(ls "$work/models" | grep -c '^ggml-tiny.bin.sha256$' || true)" "0"

# An unknown identifier must be refused rather than producing a 404 file.
status=0; "$wm" download not-a-real-model >/dev/null 2>&1 || status=$?
report "an unknown model is refused" 1 "$status"
assert_equals "nothing was written for it" \
    "$(find "$work/models" -name '*not-a-real-model*' | wc -l)" "0"

# No subcommand at all should print usage and fail, not succeed silently.
status=0; "$wm" >/dev/null 2>&1 || status=$?
report "no subcommand exits non-zero" 2 "$status"

exit "$fail"

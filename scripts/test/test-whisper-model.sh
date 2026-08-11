#!/usr/bin/env bash
# Verify whisper-model.sh downloads, verifies, updates, and removes models.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
# Every clause ends in || true. set -e is active inside a trap, and kill on an
# already-dead PID is the final command of an && list rather than an exempt
# condition, so without it the shell exits 1 and aborts the trap mid-flight.
# That turned a fully passing run into a failure AND leaked the remaining stub
# servers, whose ports then broke the next run. The two symptoms fed each other.
trap '
    rm -rf "$work" || true
    [ -n "${srv:-}"  ] && { kill "$srv"  2>/dev/null || true; }
    [ -n "${srv2:-}" ] && { kill "$srv2" 2>/dev/null || true; }
    [ -n "${srv3:-}" ] && { kill "$srv3" 2>/dev/null || true; }
    [ -n "${srv4:-}" ] && { kill "$srv4" 2>/dev/null || true; }
    [ -n "${srv5:-}" ] && { kill "$srv5" 2>/dev/null || true; }
    true
' EXIT

# Bind to an ephemeral port and read back what the kernel gave us, rather than
# hardcoding one. A collision on a fixed port produced five seconds of readiness
# retries and then an errexit abort with no assertion output at all.
free_port() {
    python3 -c "
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
"
}

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

port=$(free_port)
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
# Stderr is discarded here too: the download curl call intentionally has no
# -sS, since a real download of a multi-gigabyte model should show progress,
# but that means it writes bare \r progress-meter updates that must not reach
# this suite's own terminal output.
"$wm" download tiny >/dev/null 2>&1
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
# Stdout only here, not 2>&1: cmd_update has a second, stderr-only message
# containing the same "up to date" substring (the size-only fallback), so
# merging streams would let this assertion pass even if ETag extraction broke
# and the wrong branch fired. No download happens on this path either way, so
# there is no progress meter this omission could let through.
"$wm" download tiny >/dev/null 2>&1 || true
rm -f "$work/models/ggml-tiny.bin" "$work/models/ggml-tiny.bin.sha256"
"$wm" download tiny >/dev/null 2>&1
out=$("$wm" update tiny 2>/dev/null)
assert_contains "update is a no-op when unchanged" "$out" "up to date"

# Move the remote, then confirm update notices and refetches. This is the whole
# point of the wrapper, and upstream's script cannot do it at all.
printf 'tiny model payload v2 which is longer' > "$work/blobs/ggml-tiny.bin"
out=$("$wm" update tiny 2>&1)
assert_contains "update refetches a changed model" "$out" "updating"
assert_equals "updated content landed" \
    "$(cat "$work/models/ggml-tiny.bin")" "tiny model payload v2 which is longer"

new_sha=$(sha256sum "$work/blobs/ggml-tiny.bin" | cut -d' ' -f1)
assert_contains "sidecar was rewritten" \
    "$(cat "$work/models/ggml-tiny.bin.sha256")" "sha256=$new_sha"

# A bare update covers every installed model.
"$wm" download silero-v6.2.0 >/dev/null 2>&1
printf 'silero payload v2' > "$work/blobs/ggml-silero-v6.2.0.bin"
out=$("$wm" update 2>&1)
assert_contains "bare update reaches the vad family" "$out" "silero-v6.2.0"
assert_equals "bare update refetched it" \
    "$(cat "$work/models/ggml-silero-v6.2.0.bin")" "silero payload v2"

# A missing sidecar must self-heal by rehashing rather than failing.
rm -f "$work/models/ggml-tiny.bin.sha256"
status=0; out=$("$wm" update tiny 2>&1) || status=$?
report "update survives a missing sidecar" 0 "$status"
assert_contains "missing sidecar is recreated" \
    "$(cat "$work/models/ggml-tiny.bin.sha256")" "sha256="

# remove takes the sidecar with it, so no orphan is left behind.
"$wm" remove tiny >/dev/null
assert_equals "remove deletes the model" \
    "$(ls "$work/models" | grep -c '^ggml-tiny.bin$' || true)" "0"
assert_equals "remove deletes the sidecar" \
    "$(ls "$work/models" | grep -c '^ggml-tiny.bin.sha256$' || true)" "0"

# An unknown identifier must be refused rather than producing a 404 file, and
# with a clean error message. resolve_url's failure must stop cmd_download
# before fetch ever runs curl on an empty URL, so no raw curl error appears.
status=0; err=$("$wm" download not-a-real-model 2>&1 >/dev/null) || status=$?
report "an unknown model is refused" 1 "$status"
assert_contains "unknown model error is clear" "$err" "unknown model"
assert_equals "no raw curl error leaked" \
    "$(printf '%s\n' "$err" | grep -c 'curl:' || true)" "0"
assert_equals "nothing was written for it" \
    "$(find "$work/models" -name '*not-a-real-model*' | wc -l)" "0"

# update of a model that is not installed must fail rather than reporting
# success for work it silently skipped.
status=0; "$wm" update some-typo >/dev/null 2>&1 || status=$?
report "update of an uninstalled model reports failure" 1 "$status"

# No subcommand at all should print usage and fail, not succeed silently.
status=0; "$wm" >/dev/null 2>&1 || status=$?
report "no subcommand exits non-zero" 2 "$status"

# A second stub, independent of the one above, whose repository listing can
# go dark for one family and whose blob route can advertise a checksum that
# disagrees with the bytes it actually serves. Both are read from the
# environment so the handler stays a straight copy of the one above rather
# than diverging logic that could itself hide a bug.
cat > "$work/stub2.py" <<'PYEOF'
import hashlib, http.server, json, os, sys

ROOT = sys.argv[1]
DEAD_REPO = os.environ.get("STUB_DEAD_REPO", "")
BAD_ETAG_FILE = os.environ.get("STUB_BAD_ETAG_FILE", "")
# For a file matching either of these, the header is left off the response
# entirely, rather than sent with a wrong value the way BAD_ETAG_FILE does.
# Both default to "", which never matches a real filename, so leaving them
# unset reproduces the exact original behaviour used by every test above.
NO_ETAG_FILE = os.environ.get("STUB_NO_ETAG_FILE", "")
NO_HEADERS_FILE = os.environ.get("STUB_NO_HEADERS_FILE", "")

REPOS = {
    "ggerganov/whisper.cpp": [
        "ggml-tiny.bin", "ggml-base.en.bin", "ggml-nohdr.bin", "ggml-degraded.bin"
    ],
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
            if repo not in REPOS or repo == DEAD_REPO:
                return None
            body = json.dumps(
                {"siblings": [{"rfilename": f} for f in REPOS[repo]]}
            ).encode()
            return ("json", body, None, False, False)
        # /<owner>/<name>/resolve/main/<file>
        parts = path.lstrip("/").split("/")
        if len(parts) == 5 and parts[2] == "resolve" and parts[3] == "main":
            name = parts[4]
            if not os.path.exists(os.path.join(ROOT, name)):
                return None
            data = payload(name)
            sha = hashlib.sha256(data).hexdigest()
            if name == BAD_ETAG_FILE:
                sha = "0" * 64
            send_etag = name != NO_ETAG_FILE and name != NO_HEADERS_FILE
            send_size = name != NO_HEADERS_FILE
            return ("blob", data, sha, send_etag, send_size)
        return None

    def do_HEAD(self):
        r = self._route()
        if r is None:
            self.send_error(404)
            return
        kind, body, sha, send_etag, send_size = r
        self.send_response(200)
        if kind == "blob":
            if send_etag:
                self.send_header("X-Linked-ETag", '"%s"' % sha)
            if send_size:
                self.send_header("X-Linked-Size", str(len(body)))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()

    def do_GET(self):
        r = self._route()
        if r is None:
            self.send_error(404)
            return
        kind, body, sha, send_etag, send_size = r
        self.send_response(200)
        if kind == "blob":
            if send_etag:
                self.send_header("X-Linked-ETag", '"%s"' % sha)
            if send_size:
                self.send_header("X-Linked-Size", str(len(body)))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
PYEOF

mkdir -p "$work/edge-blobs"
printf 'tiny model payload v1' > "$work/edge-blobs/ggml-tiny.bin"
printf 'base.en model payload' > "$work/edge-blobs/ggml-base.en.bin"
printf 'parakeet payload'      > "$work/edge-blobs/ggml-parakeet-tdt-0.6b-v3-f16.bin"
printf 'silero payload'        > "$work/edge-blobs/ggml-silero-v6.2.0.bin"
printf 'tdrz payload'          > "$work/edge-blobs/ggml-small.en-tdrz.bin"

port2=$(free_port)
STUB_DEAD_REPO="akashmjn/tinydiarize-whisper.cpp" \
STUB_BAD_ETAG_FILE="ggml-tiny.bin" \
    python3 "$work/stub2.py" "$work/edge-blobs" "$port2" &
srv2=$!

for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$port2/api/models/ggml-org/whisper-vad" >/dev/null 2>&1 && break
    sleep 0.1
done

export WHISPER_HF_ENDPOINT="http://127.0.0.1:$port2"
export WHISPER_MODEL_DIR="$work/edge-models"

# One dead repository (tdrz, the personal repository plausibly dormant since
# 2023) must not disable list for the three repositories that still answer.
out=$("$wm" list)
assert_contains "list survives a dead repository: whisper"  "$out" "tiny"
assert_contains "list survives a dead repository: parakeet" "$out" "parakeet-tdt-0.6b-v3-f16"
assert_contains "list survives a dead repository: vad"      "$out" "silero-v6.2.0"

# A healthy family must still be downloadable while a different family's
# repository is entirely dead.
status=0; "$wm" download base.en >/dev/null 2>&1 || status=$?
report "download from a healthy family survives a dead repository" 0 "$status"
assert_equals "the healthy download landed" \
    "$(cat "$work/edge-models/ggml-base.en.bin")" "base.en model payload"

# A wrong X-Linked-ETag must be caught rather than installed, which is the
# entire justification for fetch's verify-then-rename design: download the
# real bytes, hash them locally, and refuse to keep anything that disagrees
# with what the hub advertised.
status=0; "$wm" download tiny >/dev/null 2>&1 || status=$?
report "a bad advertised checksum is refused" 1 "$status"
assert_equals "nothing was installed for the bad checksum" \
    "$(find "$work/edge-models" -name 'ggml-tiny.bin' | wc -l)" "0"
assert_equals "no .part left behind after a bad checksum" \
    "$(find "$work/edge-models" -name '*.part' | wc -l)" "0"

# fetch's own failures (checksum mismatch, not just head_meta being
# unreachable) must not let one model in a bare update prevent the rest from
# being reached. Modelled directly on the reviewer's reproduction: aaa is
# installed but its hub always advertises a wrong checksum, bbb is installed
# and its remote has moved, and one bare update covers both.
mkdir -p "$work/batch-blobs" "$work/batch-models"
printf 'aaa payload'    > "$work/batch-blobs/ggml-aaa.bin"
printf 'bbb payload v1' > "$work/batch-blobs/ggml-bbb.bin"

port3=$(free_port)
STUB_BAD_ETAG_FILE="ggml-aaa.bin" \
    python3 "$work/stub2.py" "$work/batch-blobs" "$port3" &
srv3=$!

for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$port3/x/y/resolve/main/ggml-bbb.bin" >/dev/null 2>&1 && break
    sleep 0.1
done

base3="http://127.0.0.1:$port3/x/y/resolve/main"

# Placed directly rather than through download, since aaa's hub can never
# serve a matching checksum and so download could never have installed it in
# the first place. This stands in for a model whose upstream checksum started
# disagreeing with itself sometime after it was installed.
printf 'aaa payload' > "$work/batch-models/ggml-aaa.bin"
printf 'sha256=%s\nurl=%s/ggml-aaa.bin\n' \
    "$(sha256sum "$work/batch-blobs/ggml-aaa.bin" | cut -d' ' -f1)" "$base3" \
    > "$work/batch-models/ggml-aaa.bin.sha256"
printf 'bbb payload v1' > "$work/batch-models/ggml-bbb.bin"
printf 'sha256=%s\nurl=%s/ggml-bbb.bin\n' \
    "$(sha256sum "$work/batch-blobs/ggml-bbb.bin" | cut -d' ' -f1)" "$base3" \
    > "$work/batch-models/ggml-bbb.bin.sha256"

# Move bbb's remote, so a bare update must actually refetch it to prove it was
# reached and updated, rather than merely iterated past.
printf 'bbb payload v2' > "$work/batch-blobs/ggml-bbb.bin"

export WHISPER_HF_ENDPOINT="http://127.0.0.1:$port3"
export WHISPER_MODEL_DIR="$work/batch-models"

status=0; out=$("$wm" update 2>&1) || status=$?
report "a bare update fails overall when one model's fetch fails" 1 "$status"
assert_contains "the failing model's own reason is reported" "$out" "checksum mismatch"
assert_contains "a bare update still reaches the model after the failing one" "$out" "bbb"
assert_equals "the model after the failing one is actually updated on disk" \
    "$(cat "$work/batch-models/ggml-bbb.bin")" "bbb payload v2"

# When the hub sends NEITHER X-Linked-ETag NOR X-Linked-Size, fetch must
# refuse rather than silently install and record an unverifiable file: doing
# so would write a sidecar hash computed from the downloaded bytes themselves,
# which a later "verify" would then always agree with, making corruption
# permanently undetectable rather than merely undetected. A fourth stub
# instance is used since neither srv2 nor srv3 can pick up the new
# STUB_NO_ETAG_FILE / STUB_NO_HEADERS_FILE flags without restarting with a
# different environment, and stub2.py is reused rather than duplicated again.
mkdir -p "$work/round3-blobs" "$work/round3-models"
printf 'nohdr payload'    > "$work/round3-blobs/ggml-nohdr.bin"
printf 'degraded payload' > "$work/round3-blobs/ggml-degraded.bin"

port4=$(free_port)
STUB_NO_HEADERS_FILE="ggml-nohdr.bin" \
STUB_NO_ETAG_FILE="ggml-degraded.bin" \
    python3 "$work/stub2.py" "$work/round3-blobs" "$port4" &
srv4=$!

for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$port4/api/models/ggerganov/whisper.cpp" >/dev/null 2>&1 && break
    sleep 0.1
done

export WHISPER_HF_ENDPOINT="http://127.0.0.1:$port4"
export WHISPER_MODEL_DIR="$work/round3-models"

# download must refuse outright rather than install a file nothing was ever
# checked against.
status=0; err=$("$wm" download nohdr 2>&1 >/dev/null) || status=$?
report "download refuses when the hub sends no verification headers" 1 "$status"
assert_equals "no model file was created" \
    "$(find "$work/round3-models" -name 'ggml-nohdr.bin' | wc -l)" "0"
assert_equals "no .part file was left behind" \
    "$(find "$work/round3-models" -name '*.part' | wc -l)" "0"
assert_contains "the message names the missing verification" "$err" "X-Linked-ETag"
assert_equals "the message does not falsely claim a size check" \
    "$(printf '%s\n' "$err" | grep -c 'checking size only' || true)" "0"

# update on an already-installed model must leave it untouched rather than
# overwrite it with unverifiable bytes, for a hub that degrades this way
# sometime after the model was installed.
printf 'nohdr payload' > "$work/round3-models/ggml-nohdr.bin"
printf 'sha256=%s\nurl=http://127.0.0.1:%s/ggerganov/whisper.cpp/resolve/main/ggml-nohdr.bin\n' \
    "$(sha256sum "$work/round3-blobs/ggml-nohdr.bin" | cut -d' ' -f1)" "$port4" \
    > "$work/round3-models/ggml-nohdr.bin.sha256"

status=0; "$wm" update nohdr >/dev/null 2>&1 || status=$?
report "update also refuses when the hub sends no verification headers" 1 "$status"
assert_equals "the previously installed file was left untouched" \
    "$(cat "$work/round3-models/ggml-nohdr.bin")" "nohdr payload"

# The degraded path the spec explicitly keeps (X-Linked-Size present but no
# X-Linked-ETag) must still work: refusing what cannot be verified at all
# must not also have broken the weaker, but still real, size-only check.
status=0; "$wm" download degraded >/dev/null 2>&1 || status=$?
report "the size-only degraded path still succeeds" 0 "$status"
assert_equals "the degraded download landed" \
    "$(cat "$work/round3-models/ggml-degraded.bin")" "degraded payload"

# A batch download must reach every identifier named, not stop at the first
# failure. cmd_update got this after its abort was reproduced; cmd_download had
# the identical defect and no test, so it shipped. The first model here cannot
# be verified and must fail, and the second must still be attempted and land.
rm -rf "$work/batch-models"; mkdir -p "$work/batch-models"
export WHISPER_MODEL_DIR="$work/batch-models"

status=0; out=$("$wm" download nohdr degraded 2>&1) || status=$?
report "a batch download reports failure overall" 1 "$status"
assert_equals "the failing model was not installed" \
    "$(find "$work/batch-models" -name 'ggml-nohdr.bin' | wc -l)" "0"
assert_equals "the batch continued past the failure" \
    "$(cat "$work/batch-models/ggml-degraded.bin" 2>/dev/null || echo MISSING)" "degraded payload"

# An unknown identifier must not abort the batch either, since resolve_url
# reports it through a different path than a failed fetch.
rm -rf "$work/batch-models"; mkdir -p "$work/batch-models"
status=0; "$wm" download not-a-real-model degraded >/dev/null 2>&1 || status=$?
report "an unknown identifier does not abort the batch" 1 "$status"
assert_equals "the model after an unknown one still landed" \
    "$(cat "$work/batch-models/ggml-degraded.bin" 2>/dev/null || echo MISSING)" "degraded payload"

# Resume is the reason the .part file exists, and a network failure is the case
# it exists for. The download-failure path must therefore keep the partial
# rather than delete it. A stub that closes the connection partway leaves a
# short .part, which must survive for the next attempt to continue from.
cat > "$work/truncating.py" <<'PYEOF'
import http.server, json, sys

PORT = int(sys.argv[1])
BODY = b"x" * 4096

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    # Only the whisper repository lists this model. Serving the same listing for
    # all four would make the identifier ambiguous across every family, and
    # resolve_url would reject it before a download was ever attempted.
    LISTS = "/api/models/ggerganov/whisper.cpp"

    def do_HEAD(self):
        if self.path.startswith("/api/models/"):
            if self.path != self.LISTS:
                self.send_error(404); return
            self.send_response(200); self.end_headers(); return
        self.send_response(200)
        self.send_header("X-Linked-ETag", '"%s"' % ("0" * 64))
        self.send_header("X-Linked-Size", str(len(BODY)))
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/api/models/"):
            if self.path != self.LISTS:
                self.send_error(404); return
            body = json.dumps({"siblings": [{"rfilename": "ggml-trunc.bin"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        # Promise the full length, send a fraction, then drop the connection.
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY[:512])
        self.wfile.flush()
        self.close_connection = True

http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF

port5=$(free_port)
python3 "$work/truncating.py" "$port5" &
srv5=$!
for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$port5/api/models/ggerganov/whisper.cpp" >/dev/null 2>&1 && break
    sleep 0.1
done

rm -rf "$work/resume-models"; mkdir -p "$work/resume-models"
export WHISPER_HF_ENDPOINT="http://127.0.0.1:$port5"
export WHISPER_MODEL_DIR="$work/resume-models"

status=0; "$wm" download trunc >/dev/null 2>&1 || status=$?
report "a truncated download fails" 1 "$status"
assert_equals "no model file was installed" \
    "$(find "$work/resume-models" -name 'ggml-trunc.bin' | wc -l)" "0"
assert_equals "the partial file is KEPT so the next attempt can resume" \
    "$(find "$work/resume-models" -name 'ggml-trunc.bin.part' | wc -l)" "1"
assert_equals "the partial holds the bytes that did arrive" \
    "$(stat -c%s "$work/resume-models/ggml-trunc.bin.part")" "512"

# An oversized partial must be discarded rather than sending an unsatisfiable
# Range that no amount of retrying can fix.
printf '%*s' 9000 '' > "$work/resume-models/ggml-trunc.bin.part"
status=0; err=$("$wm" download trunc 2>&1) || status=$?
assert_contains "an oversized partial is discarded" "$err" "oversized partial"

exit "$fail"

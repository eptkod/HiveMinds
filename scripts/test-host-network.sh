#!/bin/bash
# End-to-end check of hiveminds-host on the network (docs/LINUX-HOST-SPEC.md §12, phase 3), on macOS or Linux,
# with the hidden test client (`hiveminds-host debug remote`) standing in for the app:
#   pairing (the owner says y in the host's terminal), 3 wrong codes, the owner saying no, a revoked device,
#   a browser's Origin header, a foreign Host header, a pinned identity, an old app, the audit log, the mDNS
#   record (no names), and remote agents with two devices: create, attach, type, take over, answer, changes,
#   delete, history, and "host stopping".
# The agent is a stand-in for Claude Code that writes hook events the same way. Scratch folders only.
# Usage: scripts/test-host-network.sh [--non-private ADDRESS]
#   --non-private: also check that a connection from a non-private address is refused. ADDRESS must be an address
#   of this machine outside the private ranges (e.g. `sudo ip addr add 203.0.113.5/32 dev lo` on Linux).
set -euo pipefail
cd "$(dirname "$0")/.."
NONPRIVATE=""
[ "${1:-}" = "--non-private" ] && NONPRIVATE="${2:?address}"

if [ "$(uname)" = Darwin ] && [ -z "${SDKROOT:-}" ] && ! xcode-select -p | grep -q Xcode.app; then
  export SDKROOT=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
fi
# HIVEMINDS_HOST_BIN tests an already-built binary, such as the one a package installed.
if [ -n "${HIVEMINDS_HOST_BIN:-}" ]; then
  H=$HIVEMINDS_HOST_BIN
else
  if ! out=$(swift build --product hiveminds-host 2>&1); then echo "$out"; exit 1; fi
  H="$(swift build --show-bin-path)/hiveminds-host"
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/hm-net-test.XXXXXX")
export XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data XDG_STATE_HOME=$T/state
unset XDG_RUNTIME_DIR
PORT=$((17000 + RANDOM % 2000))
PASS=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
failed() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
check() { if (set +o pipefail; eval "$2"); then pass "$1"; else failed "$1"; fi; }
cleanup() { [ -n "${SERVE_PID:-}" ] && kill -9 "$SERVE_PID" 2>/dev/null || true; pkill -9 -f "$T/" 2>/dev/null || true; }
trap cleanup EXIT

# Two devices, each with its own identity and tokens.
A() { XDG_STATE_HOME=$T/device-a "$H" debug remote 127.0.0.1:$PORT "$@" --name "Device A" 2>&1; }
B() { XDG_STATE_HOME=$T/device-b "$H" debug remote 127.0.0.1:$PORT "$@" --name "Device B" 2>&1; }
C() { XDG_STATE_HOME=$T/device-c "$H" debug remote 127.0.0.1:$PORT "$@" --name "Device C" 2>&1; }

cat > "$T/claude" <<'EOF'
#!/bin/sh
ev() { printf '%s\n' "$1" >> "$HIVEMINDS_EVENTS"; }
echo "FAKE CLAUDE ready"
ev '{"hook_event_name":"SessionStart"}'
turn() {
  ev "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$1\"}"
  case "$1" in
    *permission*)
      ev '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch allowed.txt"}}'
      printf '  ❯ 1. Yes\n    2. No\n'
      stty -icanon -echo min 1; key=$(dd bs=1 count=1 2>/dev/null); stty icanon echo
      [ "$key" = 1 ] && touch allowed.txt
      echo "KEY $key" ;;
    *) echo hi > hello.txt; echo "DID: $1" ;;
  esac
  ev '{"hook_event_name":"Stop"}'
}
for a; do last=$a; done
case "$last" in *" "*) sleep 0.3; turn "$last" ;; esac
while IFS= read -r line; do
  p=$(printf '%s' "$line" | tr -d '\033' | sed 's/\[200~//; s/\[201~//')
  [ -n "$p" ] && turn "$p"
done
EOF
chmod +x "$T/claude"
export HIVEMINDS_HOST_CLAUDE="$T/claude"
mkdir -p "$T/proj" && (cd "$T/proj" && git init -q -b main && echo "# test" > README.md && git add . \
  && git -c user.email=t@example.com -c user.name=t commit -qm init)
"$H" projects add "$T/proj" --name demo > /dev/null

# serve in a pseudo-terminal, so the owner can answer y/n and press p as a person would.
cat > "$T/run_in_pty.py" <<'PY'
import os, pty, select, sys
log, fifo, cmd = open(sys.argv[1], "wb"), sys.argv[2], sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(cmd[0], cmd)
inp = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
watch = [fd, inp]
while True:
    r, _, _ = select.select(watch, [], [])
    if fd in r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        log.write(data); log.flush()
    if inp in watch and inp in r:
        data = os.read(inp, 1024)
        if data:
            os.write(fd, data)
        else:
            watch.remove(inp)
os.waitpid(pid, 0)
PY
mkfifo "$T/in"
python3 -I "$T/run_in_pty.py" "$T/serve.log" "$T/in" "$H" serve --name test-host --port $PORT > /dev/null 2>&1 &
sleep 0.2
exec 3> "$T/in"
for _ in $(seq 1 100); do "$H" status 2>/dev/null | grep -q "is running" && break; sleep 0.1; done
SERVE_PID=$("$H" status | sed -n 's/.*(process \([0-9]*\),.*/\1/p')
wait_for() { for _ in $(seq 1 $(($2 * 10))); do grep -q "$1" "$T/serve.log" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
code() { tr -d '\r' < "$T/serve.log" | sed -n 's/.*Pairing code: \([0-9]\{3\}\) \([0-9]\{3\}\).*/\1\2/p' | tail -1; }

echo "Listening and discovery"
check "serve is up and shows a pairing code" 'wait_for "Pairing code: " 5'
check "it says where it listens" 'grep -q "local network" "$T/serve.log"'
check "it listens on loopback (and the LAN)" '"$H" status | grep -q "127.0.0.1:$PORT"'
check "it never listens on a public or wildcard address" '! "$H" status | grep -E "Listening on" | grep -qE "0\.0\.0\.0|\[::\]"'
if command -v dns-sd >/dev/null; then
  (dns-sd -L "hiveminds-$(sed -n 's/^\([0-9a-f]\{8\}\).*/\1/p' "$T/data/hiveminds-host/host-id")" _hiveminds._tcp local. > "$T/mdns.txt" 2>&1 &
   p=$!; sleep 3; kill $p 2>/dev/null) || true
elif command -v avahi-browse >/dev/null; then
  (avahi-browse -rpt _hiveminds._tcp > "$T/mdns.txt" 2>&1) || true
fi
if [ -s "${T}/mdns.txt" ]; then
  HOSTID=$(cat "$T/data/hiveminds-host/host-id")
  check "it's announced with the protocol version and its random id" 'grep -q "v=1" "$T/mdns.txt" && grep -q "id=$HOSTID" "$T/mdns.txt"'
  check "the announcement carries no host, user or project name" '! grep -qiE "test-host|demo|$(whoami)" "$T/mdns.txt"'
fi

echo "Pairing"
OUT=$(A hello)
check "an unpaired device is asked to pair, and isn't told the host's name" 'echo "$OUT" | grep -q "PAIRING-REQUIRED noToken" && ! echo "$OUT" | grep -q test-host'
for guess in 000001 000002 000003; do A pair $guess > "$T/guess.txt" || true; done
check "three wrong codes: the third uses the code up" 'grep -q "tooManyTries" "$T/guess.txt"'
OUT=$(A pair "$(code)" || true)
check "after that even the right code is refused" 'echo "$OUT" | grep -q "tooManyTries"'
check "nobody was asked about a wrong code" '! grep -q "Allow \"Device A\"" "$T/serve.log"'
printf p >&3; sleep 0.5
CODE=$(code)
(A pair "$CODE" > "$T/pair-a.txt" || true) &
JOB=$!
check "a right code: the owner is asked, with the device's name and fingerprint" 'wait_for "Allow \"Device A\" (fingerprint" 10'
printf y >&3
wait $JOB
check "the owner said y: the device is paired" 'grep -q "PAIRED with test-host as Device A" "$T/pair-a.txt"'
check "the same code can't pair another device" 'B pair "$CODE" | grep -q "tooManyTries\|noCode"'
printf p >&3; sleep 0.5
(B pair "$(code)" > "$T/pair-b.txt" || true) &
JOB=$!
wait_for "Allow \"Device B\"" 10 || true
printf y >&3
wait $JOB
check "a second device pairs too" 'grep -q "PAIRED" "$T/pair-b.txt"'
printf p >&3; sleep 0.5
(C pair "$(code)" > "$T/pair-c.txt" || true) &
JOB=$!
wait_for "Allow \"Device C\"" 10 || true
printf n >&3
wait $JOB
check "the owner said n: not paired" 'grep -q "notAllowed" "$T/pair-c.txt"'
check "a paired device signs in with its token, and learns the name" 'A hello | grep -q "WELCOME test-host as Device A"'
check "devices list shows both" '"$H" devices list | grep -q "Device A" && "$H" devices list | grep -q "Device B" && ! "$H" devices list | grep -q "Device C"'
check "only token hashes are kept, owner-only" '[ "$(ls -l "$T/data/hiveminds-host/devices.json" | cut -c1-10)" = "-rw-------" ] && ! grep -q "$(sed -n "s/.*\"token\":\"\([^\"]*\)\".*/\1/p" "$T/device-a/hiveminds-host/test-client/hosts.json")" "$T/data/hiveminds-host/devices.json"'
check "the host's key is owner-only" '[ "$(ls -l "$T/data/hiveminds-host/identity/key.pem" | cut -c1-10)" = "-rw-------" ]'

echo "Defences"
check "a request with a browser's Origin header is refused" 'A hello --origin http://evil.example | grep -q "refused(HTTP 403)"'
check "a foreign Host header is refused (DNS rebinding)" 'A hello --host-header evil.example | grep -q "refused(HTTP 403)"'
check "a host whose certificate changed is caught" 'XDG_STATE_HOME=$T/device-a sh -c "sed -i.bak \"s/\\\"fingerprint\\\":\\\"[0-9A-F]*\\\"/\\\"fingerprint\\\":\\\"$(printf "%064d" 0)\\\"/\" $T/device-a/hiveminds-host/test-client/hosts.json" && A hello | grep -q identityChanged; cp $T/device-a/hiveminds-host/test-client/hosts.json.bak $T/device-a/hiveminds-host/test-client/hosts.json'
check "an older app is told to update" 'A hello --protocol 0 | grep -q "INCOMPATIBLE update app"'
check "a newer app is told the host needs updating" 'A hello --protocol 2 | grep -q "INCOMPATIBLE update host"'
check "nothing works before signing in" 'C agents | grep -q "Not signed in"'
if [ -n "$NONPRIVATE" ]; then
  exec 3>&-
  kill -TERM "$SERVE_PID"; for _ in $(seq 1 50); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 0.1; done
  "$H" serve --listen "$NONPRIVATE" --port $PORT > "$T/serve-np.log" 2>&1 &
  NP=$!
  sleep 2
  check "a connection from a non-private address is refused" 'XDG_STATE_HOME=$T/device-a "$H" debug remote $NONPRIVATE:$PORT hello --name "Device A" | grep -q "ERROR"'
  check "and logged" '"$H" log | grep -q "refused.*address isn.t on the local network"'
  kill -TERM $NP; wait $NP 2>/dev/null || true
  rm -f "$T/in"; mkfifo "$T/in"
  python3 -I "$T/run_in_pty.py" "$T/serve.log" "$T/in" "$H" serve --name test-host --port $PORT > /dev/null 2>&1 &
  sleep 0.2; exec 3> "$T/in"
  for _ in $(seq 1 100); do "$H" status 2>/dev/null | grep -q "is running" && break; sleep 0.1; done
  SERVE_PID=$("$H" status | sed -n 's/.*(process \([0-9]*\),.*/\1/p')
fi

echo "Remote agents, two devices"
OUT=$(A create demo --task "make hello" --own-branch)
ID=$(echo "$OUT" | sed -n 's/^CREATED \([0-9A-F-]*\) .*/\1/p')
check "device A creates an agent on its own branch" '[ -n "$ID" ] && echo "$OUT" | grep -q "hive/"'
for _ in $(seq 1 50); do A agents | grep -q "${ID:0:8} done" && break; sleep 0.2; done
check "hook events reach the device: it's done, started by A" 'A agents | grep -q "${ID:0:8} done .*startedBy=Device A"'
(B attach "$ID" --seconds 15 > "$T/b-watch.txt") &
JOB=$!
sleep 1.5
(A take "$ID" --cols 90 --rows 25 --type "please ask permission" --seconds 8 > "$T/a-take.txt") &
AJOB=$!
for _ in $(seq 1 50); do grep -q TYPED "$T/a-take.txt" 2>/dev/null && break; sleep 0.1; done
check "A takes control and the terminal takes A's size" 'grep -q "CONTROLLING Device A 90x25" "$T/a-take.txt"'
check "B, not controlling, can't type: it's refused, naming A" 'B type "$ID" "hello from B" | grep -q "notController.*Device A is typing"'
for _ in $(seq 1 50); do A agents | grep -q "${ID:0:8} needsYou" && break; sleep 0.2; done
check "the agent asks permission, everyone sees it" 'B agents | grep -q "${ID:0:8} needsYou"'
check "B takes over (and keeps it while answering)" 'B take "$ID" | grep -q "CONTROLLING Device B"'
wait $AJOB
check "A was told B took over" 'grep -q "CONTROLLER Device B (took over from Device A)" "$T/a-take.txt"'
check "and answers it: allowed" 'B answer "$ID" allow | grep -q "ANSWERED Allowed"'
check "a second answer to the same prompt gets notAsking" 'B answer "$ID" allow | grep -q "notAsking"'
wait $JOB
check "B saw the screen from before it attached (the snapshot) and live after" 'grep -q "DID: make hello" "$T/b-watch.txt" && grep -q "KEY 1" "$T/b-watch.txt"'
check "B saw the resize and the take-over as they happened" 'grep -q "RESIZED 90x25" "$T/b-watch.txt" && grep -q "CONTROLLER Device B (took over from Device A)" "$T/b-watch.txt"'
check "and saw who resolved the prompt" 'grep -q "RESOLVED by Device B" "$T/b-watch.txt"'
WT=$(git -C "$T/proj" worktree list | sed -n "s/^\([^ ]*\) .*hive\/.*/\1/p" | head -1)
check "the permission really was granted (the agent's file exists)" '[ -f "$WT/allowed.txt" ]'
check "Changes come from the host" 'A changes "$ID" | grep -q "hello.txt"'
check "deleting it works and it moves to history" 'A delete "$ID" | grep -q "DELETED" && A history | grep -q "${ID:0:8}"'

echo "Revoking, the audit log, stopping"
(A attach "$(A create demo --task "make hello" | sed -n 's/^CREATED \([0-9A-F-]*\) .*/\1/p')" --seconds 4 > "$T/a-revoked.txt") &
JOB=$!
sleep 1.5
"$H" devices revoke "Device A" > /dev/null
wait $JOB
check "a revoked device is disconnected at once" 'grep -q "CLOSED" "$T/a-revoked.txt"'
check "and can't come back with its token" 'A hello | grep -q "PAIRING-REQUIRED unknownToken"'
check "the audit log has who paired, signed in, created, took control, answered, deleted and was revoked" '"$H" log > "$T/audit.txt"; for e in "paired" "signed in" "created agent" "took control" "answered" "deleted agent" "revoked" "wrong pairing code" "pairing not allowed" "refused"; do grep -q "$e" "$T/audit.txt" || { echo "missing: $e"; exit 1; }; done'
check "nothing typed is in the log" '! grep -q "please ask permission\|hello from B" "$T/audit.txt"'
(B attach "$(B agents | sed -n "s/^AGENT \([0-9A-F]*\) .*/\1/p" | head -1)" --seconds 5 > "$T/b-stop.txt") &
JOB=$!
sleep 1.5
kill -TERM "$SERVE_PID"
wait $JOB
check "stopping the host tells connected devices first" 'grep -q "HOST-STOPPING systemStop" "$T/b-stop.txt"'
for _ in $(seq 1 50); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 0.1; done
check "and nothing is left running" '! kill -0 "$SERVE_PID" 2>/dev/null && ! pgrep -f "$T/data" >/dev/null'

echo
[ $FAIL = 0 ] && echo "ALL $PASS PASSED" || echo "$FAIL FAILED, $PASS passed"
[ $FAIL = 0 ]

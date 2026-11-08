#!/bin/bash
# End-to-end check of the Mac app as a client of HiveMinds Host (docs/LINUX-HOST-SPEC.md §12, phase 4), on this Mac:
# a local `hiveminds-host serve` with a stand-in for Claude Code, the debug app (scratch support folder and hosts file,
# never the real app's data or Keychain) and the host's test client as a second device. The app pairs (the owner says
# y in the host's terminal), sees the host's projects, starts an agent, watches its terminal, takes control, types,
# is asked permission, is refused while the other device has control, takes over and answers, reads the changes and
# quits; the agent keeps running. A second run finds it again, deletes it, finds it in the host's history and shows
# the host stopping. The app's window opens briefly. Usage: [KEEP=1] [SNAP=/path/prefix] scripts/test-app-remote.sh
# (KEEP keeps the logs; SNAP saves window captures as <prefix>-<step>.png)
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname)" = Darwin ] || { echo "macOS only (it runs the app)"; exit 1; }
if [ -z "${SDKROOT:-}" ] && ! xcode-select -p | grep -q Xcode.app; then
  export SDKROOT=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
fi
if ! out=$(swift build --product hiveminds-host 2>&1 && swift build --product HiveMinds 2>&1); then echo "$out"; exit 1; fi
BIN="$(swift build --show-bin-path)"
H="$BIN/hiveminds-host"

T=$(mktemp -d "${TMPDIR:-/tmp}/hm-app-test.XXXXXX")
export XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data XDG_STATE_HOME=$T/state
unset XDG_RUNTIME_DIR
PORT=$((19000 + RANDOM % 2000))
PASS=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
failed() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
check() { if (set +o pipefail; eval "$2"); then pass "$1"; else failed "$1"; fi; }
cleanup() {
  [ -n "${APP_PID:-}" ] && kill -9 "$APP_PID" 2>/dev/null || true
  [ -n "${SERVE_PID:-}" ] && kill -9 "$SERVE_PID" 2>/dev/null || true
  pkill -9 -f "$T/" 2>/dev/null || true
}
trap cleanup EXIT

B() { XDG_STATE_HOME=$T/device-b "$H" debug remote 127.0.0.1:$PORT "$@" --name "Device B" 2>&1; }
# The app, with everything it keeps in scratch places.
app() {
  local name=$1; shift
  env HIVEMINDS_SUPPORT_DIR=$T/app HIVEMINDS_HOSTS_FILE=$T/app/hosts.json HIVEMINDS_TEST_REMOTE=127.0.0.1:$PORT \
    HIVEMINDS_TEST_REMOTE_SIGNALS=$T/signals ${SNAP:+HIVEMINDS_TEST_REMOTE_SNAP=$SNAP HIVEMINDS_SNAPSHOT=$SNAP} "$@" "$BIN/HiveMinds" > "$T/app-$name.log" 2>&1 &
  APP_PID=$!
}
app_wait() { for _ in $(seq 1 $(($2 * 10))); do grep -q "$1" "$T/app-$3.log" 2>/dev/null && return 0; grep -q "REMOTE-FAIL\|REMOTE-TIMEOUT" "$T/app-$3.log" 2>/dev/null && return 1; sleep 0.1; done; return 1; }
line() { grep "$1" "$T/app-$2.log" | tail -1; }
mkdir -p "$T/app" "$T/signals"

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
wait_for "Pairing code: " 5

echo "Pairing"
B_CODE=$(code)
(B pair "$B_CODE" > "$T/pair-b.txt" || true) &
JOB=$!
wait_for 'Allow "Device B"' 10 && printf y >&3
wait $JOB
check "the second device (the test client) pairs" 'grep -q "PAIRED with test-host" "$T/pair-b.txt"'
printf p >&3; sleep 0.5
app pair HIVEMINDS_TEST_REMOTE_PHASE=pair HIVEMINDS_TEST_REMOTE_CODE="$(code)"
check "the app connects and asks for the code" 'app_wait REMOTE-CODE-ASKED 20 pair'
FP=$(tr -d '\r' < "$T/serve.log" | sed -n 's/.*Fingerprint: \([0-9A-F ]*\).*/\1/p' | head -1 | sed 's/ *$//')
check "the fingerprint the app shows is the one the host shows" '[ -n "$FP" ] && line REMOTE-CODE-ASKED pair | grep -qF "$FP"'
check "the owner is asked about this Mac" 'for _ in $(seq 1 150); do [ "$(grep -c "Allow \"" "$T/serve.log")" -ge 2 ] && break; sleep 0.1; done; [ "$(grep -c "Allow \"" "$T/serve.log")" -ge 2 ]'
printf y >&3
check "the owner said y: the app is paired and keeps the pairing" 'app_wait REMOTE-PAIRED 15 pair && grep -q test-host "$T/app/hosts.json" && [ -s "$T/app/hosts.device.json" ]'
check "the token isn't in the app's settings or state" '! grep -rq "$(sed -n "s/.*\"token\":\"\([^\"]*\)\".*/\1/p" "$T/app/hosts.json")" "$T/app" --exclude=hosts.json'

echo "An agent on the host"
check "the app sees the host's projects" 'app_wait "REMOTE-CONNECTED projects=demo" 15 pair'
check "it starts an agent there, on its own branch, started by this Mac" 'app_wait REMOTE-DONE 30 pair && line REMOTE-DONE pair | grep -q "branch=hive/"'
ID=$(line REMOTE-DONE pair | awk '{print $2}')
check "the agent runs on the host, in its project" '[ -n "$ID" ] && B agents | grep -q "${ID:0:8} done"'
check "its terminal shows what happened before it was opened (the snapshot)" 'app_wait REMOTE-SCREEN 20 pair'
check "taking control sizes the host's terminal to the app's view" 'app_wait REMOTE-CONTROLLER 20 pair && B agents | grep "${ID:0:8}" | grep -qv "controller=-"'
check "typing reaches it, and it asks permission" 'app_wait REMOTE-ASKED 20 pair'
check "the host sees it asking too" 'B agents | grep -q "${ID:0:8} needsYou"'
check "and the app is watching" 'B agents | grep "${ID:0:8}" | grep -q "viewers=\[\"[^]]"'
(B take "$ID" --seconds 20 > "$T/b-take.txt") &
BTAKE=$!
for _ in $(seq 1 50); do grep -q CONTROLLING "$T/b-take.txt" && break; sleep 0.1; done
touch "$T/signals/took-over"
check "the app sees the other device take over" 'app_wait "REMOTE-OTHER-CONTROLLER Device B" 15 pair'
check "answering while the other device has control is refused, with a way out" 'app_wait REMOTE-REFUSED 15 pair && line REMOTE-REFUSED pair | grep -q "Device B" && line REMOTE-REFUSED pair | grep -qi "take over"'
check "the app takes over again and allows it: the tool runs" 'app_wait REMOTE-ALLOWED 20 pair && [ -n "$(find "$T" -name allowed.txt -print -quit)" ]'
check "the other device was told it lost control" 'grep -q "CONTROLLER .*took over from Device B" "$T/b-take.txt"'
check "Changes and a diff come from the host" 'app_wait REMOTE-DIFF 15 pair && line REMOTE-CHANGES pair | grep -q hello.txt'
check "the app quits" 'app_wait REMOTE-QUIT 10 pair && for _ in $(seq 1 50); do kill -0 $APP_PID 2>/dev/null || break; sleep 0.1; done; ! kill -0 $APP_PID 2>/dev/null'
kill $BTAKE 2>/dev/null || true; wait $BTAKE 2>/dev/null || true
sleep 0.5
check "quitting the app leaves the host's agent running" 'B agents | grep "${ID:0:8}" | grep -q "running=true"'

echo "Coming back, and the host stopping"
app again HIVEMINDS_TEST_REMOTE_PHASE=again
check "the app reconnects on its own and finds the agent" 'app_wait "REMOTE-RESTORED $ID" 20 again'
check "nothing from the host was saved as this Mac's own" 'line REMOTE-RESTORED again | grep -q "local=0" && ! grep -q "$ID" "$T/app/state.json" 2>/dev/null'
check "deleting it from the app deletes it on the host and it's in the host's history" 'app_wait "REMOTE-HISTORY has it" 20 again && ! B agents | grep -q "${ID:0:8}"'
app_wait REMOTE-WAITING-FOR-STOP 10 again || true
kill -TERM "$SERVE_PID"
check "stopping the host is shown in the app" 'app_wait REMOTE-HOST-STOPPED 20 again'
line REMOTE-HOST-STOPPED again | sed 's/^/        /'
for _ in $(seq 1 50); do kill -0 $APP_PID 2>/dev/null || break; sleep 0.1; done

echo
if [ $FAIL -eq 0 ]; then echo "ALL $PASS PASSED"; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"; else echo "$FAIL FAILED, $PASS passed (left in $T)"; exit 1; fi

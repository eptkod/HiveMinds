#!/bin/bash
# End-to-end check of hiveminds-host (docs/LINUX-HOST-SPEC.md §12, phase 2), on macOS or Linux:
# projects, serve, status, starting an agent with the hidden debug command, hook status changes, typing,
# a restart that resumes the conversation, Ctrl+C (asks, "no" carries on, "yes" stops everything),
# Ctrl+C twice (forces), and SIGTERM (stops without asking). Nothing may be left running afterwards.
#
# Usage: scripts/test-host.sh [--real]
#   By default the agent is a stand-in for Claude Code that writes hook events the same way, so this runs
#   anywhere. --real uses the real `claude` with Haiku (needs Claude Code logged in; costs a little).
# Everything happens in a scratch folder; your real host settings are not touched.
set -euo pipefail
cd "$(dirname "$0")/.."
REAL=0
[ "${1:-}" = "--real" ] && REAL=1

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

T=$(mktemp -d "${TMPDIR:-/tmp}/hm-host-test.XXXXXX")
export XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data XDG_STATE_HOME=$T/state
unset XDG_RUNTIME_DIR
PASS=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
failed() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
check() { if (set +o pipefail; eval "$2"); then pass "$1"; else failed "$1"; fi; }
cleanup() {
  [ -n "${SERVE_PID:-}" ] && kill -9 "$SERVE_PID" 2>/dev/null || true
  pkill -9 -f "$T/" 2>/dev/null || true
}
trap cleanup EXIT

# A stand-in for Claude Code: writes hook events to $HIVEMINDS_EVENTS as its hooks would.
cat > "$T/claude" <<'EOF'
#!/bin/sh
ev() { printf '%s\n' "$1" >> "$HIVEMINDS_EVENTS"; }
[ -n "$FAKE_STUBBORN" ] && trap '' TERM
echo "FAKE CLAUDE $*"
turn() {
  ev "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$1\"}"
  ev '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$PWD"'/hello.txt"}}'
  echo hi > hello.txt
  echo "DID: $1"
  ev '{"hook_event_name":"Stop"}'
}
ev '{"hook_event_name":"SessionStart"}'
# Like Claude Code, the first request can come as the last argument (it has spaces; flag values don't).
for a; do last=$a; done
case "$last" in *" "*) sleep 0.5; turn "$last" ;; esac
while IFS= read -r line; do
  prompt=$(printf '%s' "$line" | tr -d '\033' | sed 's/\[200~//; s/\[201~//')
  [ -n "$prompt" ] && turn "$prompt"
done
EOF
chmod +x "$T/claude"
if [ $REAL = 0 ]; then export HIVEMINDS_HOST_CLAUDE="$T/claude"; fi

mkdir -p "$T/proj" && (cd "$T/proj" && git init -q -b main && echo "# test" > README.md && git add . \
  && git -c user.email=t@example.com -c user.name=t commit -qm init)

echo "Projects"
check "status with no host says so" '"$H" status | grep -q "isn.t running"'
check "a missing folder is refused" '! "$H" projects add "$T/nope" 2>/dev/null'
check "add a project" '"$H" projects add "$T/proj" --name demo | grep -q "Added demo"'
check "adding it again is harmless" '"$H" projects add "$T/proj" | grep -q "already a project"'
check "list it" '"$H" projects list | grep -q "^demo"'
check "config is owner-only" '[ "$(ls -ld "$T/config/hiveminds-host" | cut -c1-10)" = "drwx------" ] && [ "$(ls -l "$T/config/hiveminds-host/config.json" | cut -c1-10)" = "-rw-------" ]'

# Runs `serve` in a pseudo-terminal (so Ctrl+C asks), logging what it prints, with what we type coming from a fifo.
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
start_serve() {
  rm -f "$T/in"; mkfifo "$T/in"
  : > "$T/serve.log"
  python3 -I "$T/run_in_pty.py" "$T/serve.log" "$T/in" "$H" serve --name test-host > /dev/null 2>&1 &
  SCRIPT_PID=$!
  sleep 0.2
  exec 3> "$T/in"
  for _ in $(seq 1 100); do "$H" status 2>/dev/null | grep -q "is running" && break; sleep 0.1; done
  SERVE_PID=$("$H" status | sed -n 's/.*(process \([0-9]*\),.*/\1/p')
}
wait_for() { # pattern, seconds
  for _ in $(seq 1 $(($2 * 10))); do grep -q "$1" "$T/serve.log" 2>/dev/null && return 0; sleep 0.1; done; return 1
}
gone() { ! kill -0 "$1" 2>/dev/null; }
wait_gone() { for _ in $(seq 1 $(($2 * 10))); do gone "$1" && return 0; sleep 0.1; done; return 1; }

echo "Serve, status, an agent"
start_serve
check "serve is running" '[ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID"'
# (If the first one weren't running, this would start one: so it's killed after a moment either way.)
("$H" serve > "$T/second.log" 2>&1 & p=$!; sleep 2; kill -9 $p 2>/dev/null) || true
check "a second serve is refused" 'grep -q "already running" "$T/second.log"'
check "the banner says where it listens and how to pair" 'wait_for "Pairing code: " 5 && grep -q "local network\|isn.t on a local network" "$T/serve.log"'
TASK="Create hello.txt containing the word hi, and nothing else."
OUT=$("$H" debug start demo --task "$TASK" --model haiku --own-branch --trust --follow --timeout 120 2>&1 || true)
echo "$OUT" | sed 's/^/        /'
ID=$(echo "$OUT" | sed -n 's/^Started \([0-9A-F-]*\) .*/\1/p')
check "the agent started on its own branch" 'echo "$OUT" | grep -q "on hive/"'
check "hook events moved it to Working" 'echo "$OUT" | grep -q "STATE working"'
check "and then to Done" 'echo "$OUT" | grep -q "STATE done"'
WT=$("$H" status >/dev/null; echo "$OUT" | sed -n 's/^Started [0-9A-F-]* in \(.*\) on .*/\1/p')
check "it did the work in its worktree" '[ -f "$WT/hello.txt" ]'
check "status lists it as running and done" '"$H" status | grep -q "${ID:0:8}.*Done"'
check "the host printed its status changes" 'wait_for "Done" 5'
AGENT_PID=$(pgrep -f -n "session-id.*$T/data" || true)
check "its CLI runs in its own process group" '[ -n "$AGENT_PID" ] && [ "$(ps -o pgid= -p "$AGENT_PID" | tr -d " ")" = "$AGENT_PID" ]'
if [ $REAL = 0 ]; then
  "$H" debug type "$ID" "and once more" >/dev/null
  check "typing reaches it" 'for _ in $(seq 1 50); do "$H" debug screen "$ID" | grep -q "DID: and once more" && break; sleep 0.1; done; "$H" debug screen "$ID" | grep -q "DID: and once more"'
fi

echo "Ctrl+C"
kill -INT "$SERVE_PID"
check "Ctrl+C with an agent running asks first" 'wait_for "1 agent is running. Stop it and shut down?" 5'
echo n >&3
check "no carries on" 'wait_for "Carrying on." 5 && kill -0 "$SERVE_PID"'
kill -INT "$SERVE_PID"; sleep 0.5
echo y >&3
check "yes stops the agent and the host" 'wait_gone "$SERVE_PID" 10'
check "its CLI stopped too" '[ -z "$AGENT_PID" ] || wait_gone "$AGENT_PID" 5'
check "it said so" 'wait_for "The host has stopped." 2'
SOCK=$("$H" debug paths | sed -n 's/^socket	//p')
check "the socket and lock are gone" '[ -n "$SOCK" ] && [ ! -e "$SOCK" ] && [ ! -e "$T/state/hiveminds-host/serve.lock" ]'
exec 3>&-; wait "$SCRIPT_PID" 2>/dev/null || true

echo "Restart resumes its conversation; SIGTERM stops without asking"
start_serve
"$H" debug restart "$ID" --trust >/dev/null
check "the restarted agent resumes its conversation (--resume)" 'for _ in $(seq 1 100); do pgrep -f "resume [0-9a-f-]* .*$T/data" >/dev/null && break; sleep 0.2; done; pgrep -f "resume [0-9a-f-]* .*$T/data" >/dev/null'
AGENT_PID=$(pgrep -f -n "resume.*$T/data" || true)
kill -TERM "$SERVE_PID"
check "SIGTERM stops the host" 'wait_gone "$SERVE_PID" 10'
check "and its agent" '[ -z "$AGENT_PID" ] || wait_gone "$AGENT_PID" 5'
check "without asking" '! grep -q "Stop it and shut down" "$T/serve.log"'
exec 3>&-; wait "$SCRIPT_PID" 2>/dev/null || true

if [ $REAL = 0 ]; then
  echo "Ctrl+C twice forces"
  export FAKE_STUBBORN=1
  start_serve
  OUT=$("$H" debug start demo --task "x" --trust 2>&1)
  ID2=$(echo "$OUT" | sed -n 's/^Started \([0-9A-F-]*\) .*/\1/p')
  for _ in $(seq 1 50); do "$H" debug screen "$ID2" 2>/dev/null | grep -q "FAKE CLAUDE" && break; sleep 0.1; done
  AGENT_PID=$(pgrep -f -n "session-id.*$T/data" || true)
  kill -INT "$SERVE_PID"
  wait_for "Stop it and shut down" 5 || true
  kill -INT "$SERVE_PID"
  check "a second Ctrl+C stops at once" 'wait_gone "$SERVE_PID" 3'
  check "even an agent that ignores SIGTERM" '[ -z "$AGENT_PID" ] || wait_gone "$AGENT_PID" 3'
  exec 3>&-; wait "$SCRIPT_PID" 2>/dev/null || true
  unset FAKE_STUBBORN
fi

check "nothing of the host is left running" '! pgrep -f "$T/" >/dev/null'
echo
[ $FAIL = 0 ] && echo "ALL $PASS PASSED" || echo "$FAIL FAILED, $PASS passed"
[ $FAIL = 0 ]

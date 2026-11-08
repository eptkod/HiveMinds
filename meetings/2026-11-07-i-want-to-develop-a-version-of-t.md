# Decision: CachyOS version and host mode

## Question
Is a CachyOS (Arch Linux) version of HiveMinds feasible, and how? Also: can HiveMinds run as a **host** that other HiveMinds clients connect to, so the work and files stay on the host machine while people work remotely?

## Options considered
1. **Port the app to Linux.** Rejected. SwiftUI, AppKit, Liquid Glass, the blur window, dictation and SwiftTerm's UI have no Linux equivalent. A port means a second UI, which is a rewrite.
2. **Linux native app (GTK/Qt) on a shared core.** Deferred. It costs a second UI track and isn't needed to reach Linux.
3. **Host daemon plus thin clients (chosen).** A headless daemon owns the repos, worktrees and Claude Code processes. A browser UI served by the daemon is the Linux client (and works from a Mac or phone too). The Mac app gains a remote mode later.
4. **Daemon language.** Swift, to share the agent and meeting logic, only if the logic proves separable from the views. Otherwise a small new daemon (Swift, Go or Rust) that runs `claude` in a PTY.

## Decision
Feasible, but as a **split, not a port**. Build the host first; Linux support comes from the daemon plus a web client.

- **Daemon** (`hiveminds` host, name to be settled): opt-in, off by default, a separate process (keeps idle CPU at 0%).
- **Protocol**: structured events (agent state, plan pending, question asked) plus a PTY stream as one channel. Versioned, with a handshake, because the Mac app and daemon ship separately.
- **Sessions**: the daemon owns the PTYs and a scrollback buffer. Clients attach and detach. One writer at a time; others watch. A read-only role is in v1.
- **Local Mac mode** stays in-process (same protocol shape, no network hop).
- **v1 scope**: terminal, diffs, agent list, plan approval and prompt answers. No file editing, no dictation or region check in the browser. Remote means view, diff and drive agents, not open files in local apps.
- **Web client is the reference client**; new features land there first. Mac remote mode comes last.
- **Security**: the host runs arbitrary commands, so a leaked token is remote code execution. Reach it only over Tailscale/WireGuard or an SSH tunnel; bind to localhost or the tunnel interface, never a wildcard. Per-client pairing tokens sent in headers or cookies (not URLs), Origin checks against cross-site WebSocket hijacking and DNS rebinding, an audit log. TLS if not on a tunnel.
- **Claude Code auth** stays on the host. Clients never hold credentials. Users on one host share its account and rate limits.

## Why
- One piece of work delivers both asks; a Linux port alone would still lack remote.
- The browser avoids a second native UI and replaces SwiftTerm with xterm.js.
- The riskiest assumptions (Swift on Arch, PTY streaming, a separable core) get tested before big commitments.

## Disagreement left
Only ordering, and it's mostly resolved: Chair and Debater 2 initially put Mac remote mode before the web client; Debaters 3 and 4 put the web client first, and all now agree. Remaining open point: whether the daemon is Swift or another language, which depends on the audit result.

## Next steps
1. **Gate (about 1 day):** audit the code for how much agent/PTY state lives in views. If deeply tangled, take the fallback (a new small daemon that shells out to `claude`) rather than refactor first.
2. **Spike (about 2 days) on CachyOS:** a daemon running one Claude Code PTY, streamed to a browser via xterm.js, with detach and reattach. Confirms the Swift toolchain, `Process`/PTY and file watching on Linux.
3. **Write the versioned protocol spec.**
4. **Daemon plus web client**, with pairing, tokens, Origin checks, audit log and read-only role.
5. **Core extraction** from the SwiftUI app, if the gate says it's worthwhile.
6. **AUR/PKGBUILD package** for CachyOS.
7. **Mac remote mode** last.
8. Ethan confirms before anything is exposed beyond a tunnel. Record the decision in `HANDOFF.md`.

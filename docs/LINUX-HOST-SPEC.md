# HiveMinds Host: specification

Status: agreed with Ethan on 2026-11-07. Phase 0 done and accepted (`docs/HOST-PHASE0-REPORT.md`); phase 1 (HiveMindsCore) done 2026-11-07; phase 2 (headless host) and phase 3 (protocol and security, `docs/HOST-PROTOCOL.md`) done 2026-11-08; phase 4 (the app as client) done 2026-11-08 (checked against a local host; the CachyOS run is Ethan's); phase 5 (packaging) built 2026-11-08 and tested on Arch x86_64 in a chroot, not published; the check on real CachyOS is still to do.
Background: the two meeting notes from 2026-11-07 in `meetings/` (`…-i-want-to-develop-a-version-of-t.md` and `…-i-want-to-implement-a-feature-wh.md`). Where those notes disagree with this file, this file wins.

Read `CLAUDE.md` and `HANDOFF.md` before starting. Every rule there still applies: rebuild the app after each change, log progress in `HANDOFF.md`, no Claude attribution in git, idle CPU 0%, settings follow the `Settings.swift` pattern.

---

## 1. What we're building, in one paragraph

A small program, `hiveminds-host`, that you start from a terminal on a Linux machine (CachyOS first). It has no window and no web page. It runs the projects, agents and Claude Code on that machine. The normal HiveMinds Mac app finds it on the local network, pairs with it once, and from then on connects automatically and shows that machine's projects and agents next to "This Mac". Several people can watch the same agent at once and take turns typing. Nothing is a web page and nothing is reachable from outside the local network.

## 2. Decisions (do not change without asking Ethan)

1. **Not a Linux port of the app.** Linux runs only the headless host. The HiveMinds Mac app is the only client. No browser UI, no GTK/Qt app.
2. **The host is a separate install** on Linux (AUR package), started from a terminal, optionally at boot.
3. **Same app, no separate client.** Remote hosts appear inside the normal HiveMinds app.
4. **Local network only.** The host announces itself on the LAN so clients find it without typing an address. It never listens on the open internet.
5. **Pair once per device, then connect automatically** whenever the app opens.
6. **Team use.** Many devices can watch the same agent live. One person types at a time; the others see who.
7. **Closing means closing.**
   - Agents on **This Mac** keep running inside the app, as today. Quitting the app stops them. Nothing about local use changes.
   - Closing the app while connected to a remote host only disconnects that device. The host's agents keep running, because they belong to the host and teammates may be watching.
   - Stopping the host (Ctrl+C or `systemctl stop`) stops its agents. Nothing keeps running secretly anywhere.
8. **Easy install on CachyOS**: `yay -S hiveminds-host-bin`, then `hiveminds-host serve`.
9. **Credentials stay on the host.** Agents use the host's Claude Code login and its git, `gh` and SSH keys. Clients never receive them.

## 3. How it works for the user

### On the Linux machine
```
yay -S hiveminds-host-bin           # or paru
claude                              # log in to Claude Code once, if not already
hiveminds-host projects add ~/code/my-game
hiveminds-host serve
```
`serve` prints something like:
```
HiveMinds host "cachyos-desktop" is on the local network (192.168.1.20:7420).
To pair a device, open HiveMinds on it and pick this host. Pairing code: 482 913 (valid 60 s, press p for a new one)
```
When a device asks to pair:
```
Allow "Ethan's MacBook Pro" (fingerprint 7F3A-…) to use this host? [y/N]
```
Ctrl+C with agents running asks first:
```
3 agents are running. Stop them and shut down? [y/N]   (Ctrl+C again to force)
```
To run at boot: `systemctl --user enable --now hiveminds-host` (and `loginctl enable-linger $USER` so it starts without logging in). The install prints this hint.

### On the Mac
- The sidebar gets a host level: **This Mac** first, then each paired or discovered host. Projects sit under their host.
- An unpaired host found on the network shows as "cachyos-desktop · Pair…". Clicking it opens a small sheet asking for the code from the host's terminal. After the host's owner presses `y`, it's paired.
- Paired hosts connect automatically at launch and reconnect by themselves after a drop (backoff, no polling while idle).
- Everything about an agent works the same as local in v1 scope (section 7): New Agent, terminal, status, plan approval, questions, permission prompts, Changes, delete, history.
- Remote agents carry a small host label on tiles, cards and tabs, plus who's watching and who's typing.
- If the host goes away, its tiles stay with the last screen, greyed, with "cachyos-desktop is offline, reconnecting…". If the host was stopped on purpose, the message says so.
- Settings gets a **Hosts** tab (section 9).

## 4. Architecture

```
Package
├── HiveMindsCore      (library; Foundation only, builds on macOS and Linux)
│     projects, agents, worktrees, launching claude/codex, hook events,
│     status, plan/question/permission detection, history, changes (git diff)
├── HiveMindsProtocol  (library; Codable message types + version)
├── hiveminds-host     (executable; Core + network server + PTYs, macOS and Linux)
└── HiveMinds          (the app; SwiftUI; uses Core for This Mac, Protocol for remote hosts)
```

- **HiveMindsCore** must not import SwiftUI, AppKit or SwiftTerm's views. It's extracted from `Store.swift`, `Models.swift`, `Terminals.swift` (the parts that aren't views), `Shell.swift`, `Changes.swift`, `AgentHistory.swift` and friends. Use `#if canImport(AppKit)` only at the edges.
- **This Mac** keeps running agents in-process through Core. That keeps decision 7 (quit = stop) and leaves local behaviour unchanged.
- **Remote hosts**: the app talks to them through a `RemoteHost` client that speaks the protocol. The UI uses one interface (`AgentHost`, say) with two implementations: `LocalHost` (calls Core directly) and `RemoteHost`. Keep both thin over the same Core types so they can't drift; any logic belongs in Core, not in either adapter.
  - Considered and set aside: the app always launching a local `hiveminds-host` child over a Unix socket (one code path). It's cleaner but forces every local feature through the protocol before anything ships. Revisit once v1 works.
- **Terminals on the host.** The host owns each agent's PTY and keeps a headless terminal-state model (SwiftTerm's non-UI `Terminal` class if it builds on Linux, see spike 0c). On attach, a client gets a snapshot of the screen and scrollback, then the live byte stream. On the Mac, remote agents render in a plain SwiftTerm `TerminalView` fed from the stream, not a `LocalProcessTerminalView`.
- **Status and prompts.** The host uses the same Claude Code hooks file approach as today (`--settings`, JSON lines, watched file). Plan/question/permission menus are read from the host's terminal model (today's `Terminals.menuOptions`, moved into Core) and sent to clients as structured events.
- **Terminal size with many viewers.** The PTY is sized to whoever is typing. Viewers render at that size, scaled or letterboxed, and never resize the PTY.

## 5. Protocol

- One TLS connection per client: a WebSocket carrying JSON control messages and binary PTY frames (agent id + bytes). Plus small request/response calls (file reads for Changes, history) on the same socket as JSON messages, so there's one port. This is a transport only; nothing is served to a browser.
- **Handshake first:** protocol version, host id, host name (after auth only), device token. On a version mismatch the app shows "This host needs updating" (or "Update HiveMinds") and doesn't connect.
- **Messages (v1), roughly:**
  - Client → host: `listProjects`, `listAgents`, `createAgent`, `deleteAgent`, `stopAgent`, `restartAgent`, `attach(agentId)`, `detach`, `input(agentId, bytes)`, `takeControl(agentId)`, `answer(agentId, choice | text)`, `changes(agentId)`, `history`.
  - Host → client: `snapshot(agentId, screen, scrollback)`, `output(agentId, bytes)`, `agentUpdated(agent)`, `agentRemoved`, `prompt(agentId, kind, options)`, `promptResolved(agentId, by)`, `viewers(agentId, [device])`, `controller(agentId, device?)`, `hostStopping(reason)`.
- Every message that changes state is attributed to a device in the audit log.
- Keep the spec in `docs/HOST-PROTOCOL.md`, written in phase 3, with the version number.

## 6. Security

The host runs arbitrary commands. A paired device can do anything an agent can. So authentication carries the security, not the Wi-Fi.

- **Listening:** off unless `serve` is running. Binds only to private LAN interfaces (RFC 1918, link-local, IPv6 ULA), never `0.0.0.0` by default. `--listen <addr>` overrides. Rejects connections from non-private addresses. Default port 7420.
- **Discovery:** Bonjour/Avahi service `_hiveminds._tcp`. The record carries a random host id and protocol version only, no machine, user or project names. The friendly name is shown only after pairing (before pairing, the sheet shows the IP and the host's fingerprint).
- **TLS always.** The host makes a self-signed certificate on first run. The client pins its fingerprint at pairing and refuses a different one later ("This host's identity changed" with a re-pair option).
- **Pairing:**
  - The code is 6 digits, valid 60 s, single-use, 3 tries, then a new code is needed.
  - The code must be **bound to the TLS channel**, so someone in the middle can't relay it. Use a PAKE (e.g. SPAKE2 via swift-crypto) or an HMAC of the code over both certificate fingerprints. The implementer picks one and documents it.
  - The host owner then confirms the device in the terminal (`y`).
  - On success the host issues a random 256-bit device token. The host stores only its hash.
- **Every connection** must present a valid token. Tokens can be revoked (`hiveminds-host devices revoke <name>`) and expire after 90 days of not being used.
- **Browser defences:** reject any request carrying a browser `Origin` header, and check `Host`. No cookies. This blocks DNS rebinding and cross-site WebSocket tricks.
- **Secrets on disk:** on the Mac, tokens and pinned fingerprints go in the Keychain. On Linux, the host's key, cert and token hashes go in `~/.local/share/hiveminds-host/` with 0600 permissions (directory 0700). libsecret is optional, since a headless box usually has no keyring.
- **Limits:**
  - The host only exposes registered project folders. Every paired device can use all of them; there are no per-device project limits (Ethan, 2026-11-07).
  - An audit log (`~/.local/state/hiveminds-host/audit.log`) records who connected, paired, started, typed into, approved or deleted what.
  - Say plainly in docs and the pairing prompt that this isn't a sandbox: an agent has shell access to the host.

## 7. Scope

**v1 (remote):**
- Projects: list, and add on the host with `hiveminds-host projects add`. Also add from GitHub through the app, cloned on the host with the host's `gh`.
- Agents: create (provider, model, effort, access level, plan mode, own branch, first task), terminal, status, stop, restart, delete, history.
- Prompts: plan approval, questions, permission prompts. They show for everyone watching; the first answer wins, and the others see "Approved by …".
- Changes view (diff computed on the host).
- Watching and typing control.
- Dictation works unchanged, since it just types into the focused terminal.

**Later:** meetings, Split up, shell tabs, GitHub issues and PR pages against the host, the usage meter for the host's account, the Mac app acting as a host (Settings > Host), the region check for hosts.

**Never in this project:** a web UI, a native Linux UI, exposure to the internet. Ethan would have to decide otherwise.

## 8. Team use details

- **Viewers:** any number of paired devices can attach to an agent. Each tile shows the watchers' initials.
- **Typing:** one controller per agent. The first device to type gets control. Others press **Take Over**, and the previous controller sees "Alex took over". Control is released after 30 s with no typing, or on disconnect.
- **Names:** each client sets a display name in Settings > Hosts (default: the Mac's name). It's shown to others and written in the audit log.
- **Agents show who started them.**

## 9. App settings (Settings > Hosts)

Follow the `Settings.swift` pattern: a grouped `Form`, a one-line explanation under each control, keys in `SettingKey`, defaults in `SettingDefault`.

| Setting | Key | Default | Note |
|---|---|---|---|
| Find hosts on my network | `hosts.discover` | on | Turning it off stops the Bonjour browser. |
| Connect to paired hosts at launch | `hosts.autoConnect` | on | |
| Your name | `hosts.displayName` | Mac's name | Shown to teammates and in host logs. |
| Paired hosts | (Keychain) | none | Each row shows status and has Forget. |

## 10. Host CLI

```
hiveminds-host serve [--listen ADDR] [--port 7420] [--name NAME]
hiveminds-host projects add|list|remove PATH
hiveminds-host devices list | revoke NAME
hiveminds-host status                 # running agents, connected devices
hiveminds-host log [--follow]         # audit log
hiveminds-host --version
```
- **Config:** `~/.config/hiveminds-host/config.json` (no extra dependencies).
- **Data:** `~/.local/share/hiveminds-host/`. It follows XDG paths and also works on macOS.

## 11. Install and release

- **AUR `hiveminds-host-bin`:** a prebuilt x86_64 binary built with `--static-swift-stdlib`, so users don't need a Swift toolchain. Depends on `git` and `avahi`. Optionally depends on `github-cli` and Claude Code. Ships a systemd **user** unit and prints the enable/linger hint after install.
- **Optional AUR `hiveminds-host` (from source):** for people who want to build it. Lower priority.
- **Releases:** every release ships a new build of anything that changed: the app (DMG and zip, as now) and the host. When the host changed, the GitHub release also attaches `hiveminds-host-<version>-linux-x86_64.tar.gz`, which the `-bin` PKGBUILD downloads. Add this to the release protocol in `CLAUDE.md` once it exists. Building the Linux binary needs a Linux machine or a container. Document how in `README.md`.
- The PKGBUILD lives in `packaging/aur/`. Publishing it to the AUR is public: ask Ethan first.

## 12. Build order

Each phase ends with the app rebuilt, `HANDOFF.md` updated, and the listed checks done.

**Phase 0: spikes (go/no-go, about 3 days total). Report results to Ethan before phase 1.**
- **0a. Coupling audit:** how much agent, PTY and status logic lives in views (`Terminals.swift` owns PTYs inside `LocalProcessTerminalView`). Estimate the extraction. If it's very tangled, propose the fallback: a fresh small Core for the host only, with the app untouched until later.
- **0b. Dependencies:** swift-nio, swift-nio-ssl (or NIO + `Network.framework` on the client), swift-crypto and swift-certificates must build with **Command Line Tools only** on the Mac (macOS 26.x SDK, SwiftTerm pinned 1.11.2) and on CachyOS. If not, revisit the stack before going on.
- **0c. Linux terminal:** on CachyOS, run `claude` in a PTY from Swift, keep a headless SwiftTerm `Terminal`, stream it to a Mac over a socket, then detach and reattach and get the same screen back.

**Phase 1: Core extraction.** Move non-UI logic into `HiveMindsCore`. The app must behave exactly as before.
- Check: every item in the current "Next, in order" smoke list that touches agents still works. The README demo run still works.

**Phase 2: Headless host, no network.** `hiveminds-host serve` runs agents from Core on Mac and Linux, with projects, the CLI and Ctrl+C handling.
- Check: start an agent with a hidden debug command, see hook status change, stop cleanly.

**Phase 3: Protocol and security.** Write `docs/HOST-PROTOCOL.md`, then build the listener, TLS, pairing, tokens, Origin/Host checks, audit log, private-address checks and discovery.
- Check: pair from a test client, reject a wrong code 3×, reject a revoked token, reject a request with an `Origin` header, reject a non-private peer, and see no names in the mDNS record (`dns-sd -B` / `avahi-browse`).

**Phase 4: App client.**
- Hosts in the sidebar, the pairing sheet, auto-connect and reconnect.
- Remote agents across the sidebar, Canvas, Overview and agent tabs, with host labels.
- Prompts, Changes, watchers and Take Over.
- Settings > Hosts.
- Check:
  - Two Macs (or one Mac with two app copies under scratch support folders) watching the same agent on a CachyOS host. Type, take over, and approve a plan from the second one.
  - Quit the app: the host's agent keeps running.
  - Stop the host: both clients say it stopped.
  - Quit the app with local agents: they stop, as before.

**Phase 5: Packaging.** Linux build script, tarball, PKGBUILD, systemd user unit, and README and GUIDE sections.
- Check: on a clean CachyOS install, `yay -S` from a local PKGBUILD (`makepkg -si`), `serve`, pair and run an agent.

**Phase 6 (later, ask Ethan first):** the items under "Later" in section 7.

## 13. Done means (end state, phases 0–5)

Stop after phase 0 and report to Ethan; continue only on his go-ahead. Never publish to the AUR, push or make a GitHub release without asking.

**Code**
- `Package.swift` with four targets: `HiveMindsCore`, `HiveMindsProtocol`, `hiveminds-host`, `HiveMinds` (app).
- `hiveminds-host` builds and runs on macOS and CachyOS. It provides:
  - the commands `serve`, `projects`, `devices`, `status`, `log` and `--version`
  - TLS with a self-signed certificate, pairing with a confirm prompt, device tokens and revoke
  - the audit log, LAN-only listening and Bonjour/Avahi discovery
  - the Ctrl+C confirm
- In the app:
  - hosts in the sidebar, the pairing sheet, and auto-connect with reconnect
  - remote agents in the sidebar, Canvas, Overview and tabs, with host labels
  - prompts, Changes, history, watchers and Take Over
  - Settings > Hosts
- Local agents on This Mac behave exactly as before, and quitting still stops them.

**Docs**
- `docs/HOST-PROTOCOL.md` (versioned protocol).
- `README.md`: how to install and run the host, and how to build the Linux binary.
- `docs/GUIDE.md`: using hosts, pairing and team use.
- `CLAUDE.md` release protocol: the host tarball step.
- `HANDOFF.md`: progress for each phase, and next steps.

**Packaging**
- A Linux build script in `scripts/` that makes `hiveminds-host-<version>-linux-x86_64.tar.gz`.
- `packaging/aur/hiveminds-host-bin/PKGBUILD` with a systemd user unit and the post-install hint.

**Verified**
- Every phase's checks in §12 have passed, and the results are written in `HANDOFF.md`.
- The release build of `build/HiveMinds.app` is rebuilt and running.

## 14. Answered questions (2026-11-07)

- **Port 7420:** fine. A port is just the number that tells the Mac which program on the host's local IP to talk to; it stays on the local network and isn't opened to the internet (the router doesn't forward it). If 7420 is taken, `--port` picks another.
- **Per-device project limits:** not needed. Every paired device can use every registered project. Pairing is still required.
- **Release cadence:** each release ships new builds of whatever changed, the app and/or the host.

# Decision: HiveMinds host + remote clients

## Question
Can HiveMinds get a "host" (backend) that owns projects, files, database and agents, so other HiveMinds clients on the local Wi-Fi can spin up agents on it remotely? It must work on Linux and be secure, not exposed to the open web.

## Options considered
1. **Headless daemon + thin clients (chosen).** Host owns agents, projects, files, DB. Clients only display.
2. **`AgentBackend` Local/Remote switch** (D2, D4 first proposals). Two implementations behind one protocol. Rejected as the end state: two code paths drift.
3. **Embedded loopback TCP host** (Chair, D3). Right idea, but a Unix socket is better locally: no TLS, auth by file permissions.
4. **SSH tunnelling** (D3). Secure, but poor pairing and discovery, no per-device control. Not the main path.
5. **Noise/mTLS** transport. Rejected: more custom crypto and cert handling than needed.

## Decision
Build a headless **Swift daemon (`hiveminds-host`)**, UI-free so it builds on macOS and Linux. The existing app becomes a client of it.

- **One code path.** The app talks to a local daemon over a **Unix socket**. A remote host is the same API over the network.
- **Protocol:** WebSocket (JSON control + binary PTY frames) plus REST for files. Versioned; the handshake negotiates version and shows "update host" on skew.
- **Agents live on the host.** They survive client disconnects. Reconnect replays state through a **headless terminal-state tracker** on the host, not just a raw byte buffer.
- **Network:** LAN interface only, never `0.0.0.0` by default, reject non-private peers, off by default behind a Settings toggle. Discovery by Bonjour/Avahi plus manual host:port. No device or project names in mDNS records.
- **Auth carries the security, not the network:**
  - TLS always, self-signed host cert, fingerprint pinned at pairing.
  - Pairing code is short-lived (~60 s), single-use, rate-limited (3 tries), and **bound to the channel** (fingerprint in the QR, or PAKE). Host shows an "Allow device X?" prompt.
  - Per-device token, revocable, with expiry/rotation. Required on every connection; check `Origin`/`Host`; no cookie auth (DNS rebinding/CSRF).
  - Keys in Keychain / libsecret, 0600 files as Linux fallback.
- **Host-side limits:** file API only exposes registered project roots, per-device project scope, audit log with who spawned what. State plainly that scoping is advisory, not a sandbox: an agent has shell access.
- **Credentials:** agents use the host's Claude login, git and SSH keys. Clients never receive them; the UI says so and the audit log attributes usage per device.
- **Stays client-side:** SwiftTerm rendering, dictation, window appearance. Plan approvals and questions route to the client.

## Why
Agents run where files and credentials live, laptops can sleep, one code path means remote bugs show up locally, and a UI-free Swift core keeps the Linux port cheap. A paired device is remote code execution by design, so the defence is authentication plus visibility, not the Wi-Fi.

## Disagreement left
- None on direction; all four settled. One sequencing nuance: D3 wants the `AgentBackend` seam first as a cheap coupling probe; the others went straight to daemon-over-socket. Resolved below: the seam is an internal step with one implementation, not two backends.
- Linux client UI (SwiftUI port vs web) is unresolved and out of scope here.

## Next steps
0. **Two spikes (go/no-go):** (a) how entangled agent code is with the UI; (b) can NIO + swift-certificates build on Linux and with the Command-Line-Tools-only build and pinned SwiftTerm. If (b) fails, revisit the stack before going on.
1. Extract the agent/project core behind a single internal protocol (no second backend).
2. Daemon over Unix socket; the app launches or attaches to it. Announce that quitting the app no longer kills agents.
3. LAN listener, TLS pinning, channel-bound pairing, device list, audit log, Settings > Host (off by default).
4. File API, DB, mDNS/Avahi discovery.
5. Linux packaging (systemd unit) and a decision on the Linux client UI.

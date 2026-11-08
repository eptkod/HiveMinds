# HiveMinds Host protocol, version 1

How the HiveMinds app (the client) talks to `hiveminds-host` (the host) on the local network. The spec it implements is `docs/LINUX-HOST-SPEC.md` (§5 protocol, §6 security, §8 team use). The code is `Sources/HiveMindsProtocol` (messages), `Sources/HiveMindsNet` (TLS, WebSocket, pairing, discovery) and `Sources/hiveminds-host`.

The protocol version is **1** (`HostProtocol.version`). A change that an older peer can't handle (a removed or renamed message or field, a changed meaning) needs a new version. Adding an optional field or a new event that older clients can ignore doesn't.

## 1. Transport

- **TCP**, default port **7420** (`serve --port`). The host listens only on private addresses (§6.1).
- **TLS 1.3 only**, both ways. Each side has a long-lived P-256 key and a self-signed certificate:
  - the host makes its own on first run (`~/.local/share/hiveminds-host/identity/`, 0600);
  - each client device makes one (the app keeps it in the Keychain).
  - A certificate is known by its **fingerprint**: SHA-256 of its DER encoding, as 64 uppercase hex digits. People see it grouped as `7F3A-91C2-…` (the first 16 digits in groups of 4).
  - The client verifies the host's certificate by fingerprint only (pinned at pairing). The host accepts any client certificate during TLS; who the device is gets decided by its token and fingerprint (§3).
- Then **WebSocket** (RFC 6455) over that TLS connection: `GET /hiveminds/v1` with `Host: hiveminds`. The host refuses the upgrade (HTTP 403, then closes) when:
  - the request has an `Origin` header (only browsers send one: this blocks cross-site WebSocket tricks);
  - `Host` isn't exactly `hiveminds` (blocks DNS rebinding);
  - it has a `Cookie` header.
  Any other path gets 404. Nothing is ever served over HTTP.
- **Text frames** carry JSON messages, one object per frame, UTF-8.
- **Binary frames** carry terminal bytes:

  | Bytes | Meaning |
  |---|---|
  | 0 | kind: `0x01` output (host → client), `0x02` snapshot (host → client), `0x03` input (client → host) |
  | 1–16 | the agent's id (UUID, 16 bytes, big-endian as in RFC 4122) |
  | 17… | the bytes |

  A **snapshot** rebuilds the agent's whole screen and scrollback in a fresh terminal of the agent's current size (`TerminalSnapshot`); it always starts with `ESC c`. **Output** is what the agent drew since. **Input** is what someone typed, as raw bytes.
- Limits: a message may be at most 16 MiB. A connection must finish `hello` within 10 s, and pairing within 120 s; otherwise it's closed. At most 64 connections, of which 8 may be unauthenticated.

## 2. Messages

Every JSON message has a `type`. Requests from the client also have an `id` (any string the client picks); the host answers each with exactly one `reply` or `error` carrying the same `id`. Messages without an `id` are events.

```json
{"type": "listAgents", "id": "7"}
{"type": "reply", "id": "7", "agents": [ … ]}
{"type": "error", "id": "7", "code": "noSuchAgent", "message": "That agent isn't on this host any more."}
```

`message` is plain words for a person; `code` is for the program. Unknown fields must be ignored; an unknown event type must be ignored; an unknown request type gets `error` `unknownRequest`.

### 2.1 Shared shapes

- **Device**: `{"id": "d1b2…", "name": "Ethan's MacBook Pro"}`. `id` is the host's id for the pairing (16 hex digits), not the fingerprint.
- **Project**: `{"id": UUID, "name": String, "isGitRepo": Bool, "repo": "owner/name"?}`.
- **Agent**:

  ```json
  {"id": UUID, "projectId": UUID, "title": String, "provider": "claude"|"codex", "model": String,
   "effort": "low"|…|"max"?, "access": "auto"|"manual"|"unrestricted"?, "branch": String?,
   "createdAt": Number (seconds since 1970), "startedBy": Device?,
   "status": "asleep"|"starting"|"idle"|"working"|"needsYou"|"done", "activity": String,
   "ask": Ask?, "running": Bool, "cols": Int, "rows": Int,
   "viewers": [Device], "controller": Device?}
  ```

- **Ask** (what an agent is waiting on):
  - `{"kind": "permission", "tool": String, "detail": String}`
  - `{"kind": "questions", "questions": [{"header": String, "question": String, "options": [String], "multiSelect": Bool}]}`
  - `{"kind": "plan", "plan": String}`

### 2.2 Handshake

The client's first message must be `hello`:

```json
{"type": "hello", "protocol": 1, "client": "HiveMinds 1.8.0", "device": {"name": "Ethan's MacBook Pro"}, "token": "…"?}
```

The host answers with one of:

- `welcome`: the token is valid for this device's certificate. Everything in §2.4 and §2.5 is now allowed.
  `{"type": "welcome", "protocol": 1, "hostId": String, "hostName": String, "hostVersion": String, "device": Device}`
- `pairingRequired`: no token, or one this host doesn't accept (unknown, revoked, expired, or paired with a different certificate). Only pairing (§2.3) is allowed.
  `{"type": "pairingRequired", "protocol": 1, "hostId": String, "reason": "noToken"|"unknownToken"}`
- `incompatible`, then the host closes: the versions differ. `update` says which side is older.
  `{"type": "incompatible", "protocol": 1, "update": "host"|"app", "message": String}`
  The app shows "This host needs updating" or "Update HiveMinds", and doesn't retry until one of them changes.

The host name is only sent after a valid token or a successful pairing.

### 2.3 Pairing

Pairing proves that the person at the client has the 6-digit code shown on the host, over this exact TLS connection, and lets the host's owner say yes. It uses **SPAKE2** (BoringSSL's, on Curve25519: the method Android uses for wireless debugging pairing):

- The client is SPAKE2's *Alice*, with its identity `hiveminds-v1 client <clientFP>`; the host is *Bob*, with `hiveminds-v1 host <hostFP>`. Each side uses the fingerprints **as it saw them in this TLS handshake**. The password is the code's 6 ASCII digits.
- So someone relaying the connection (with certificates of their own) ends up with keys that don't match on either side, even if they know the code. Each relayed attempt is one guess at the code, and a code allows 3.

Steps:

1. Client → `{"type": "pairStart", "spake": base64 (32 bytes), "device": {"name": String}}`
2. Host → `{"type": "pairChallenge", "spake": base64}`, or `error` with `noCode` (no code is showing: "Press p on the host for a pairing code"), `tooManyTries` (the code is used up), or `busy` (another device is pairing).
3. Client → `{"type": "pairConfirm", "proof": base64}`, where `proof = HMAC-SHA256(key, "hiveminds-pair-v1|client|<clientFP>|<hostFP>")` and `key` is the SPAKE2 result.
4. Host checks the proof. If it's wrong: `error` `wrongCode` with `"triesLeft": Int`. The connection stays open for another `pairStart` while tries are left. On the third wrong try the code is used up. If it's right, the code is used up (single use) and the host asks its owner, in its terminal (or in `hiveminds-host pair`):
   `Allow "Ethan's MacBook Pro" (fingerprint 7F3A-91C2-04BE-5D10) to use this host? [y/N]`
   and sends `{"type": "pairWaiting"}`.
5. If the owner says yes: `{"type": "paired", "token": String, "hostProof": base64, "device": Device}`, then `welcome`. `hostProof = HMAC-SHA256(key, "hiveminds-pair-v1|host|<clientFP>|<hostFP>")`. The client must check it before trusting anything: it shows the host knew the code too. It then keeps the token and the host's fingerprint (pinned from now on).
   If the owner says no, or doesn't answer within 60 s: `error` `notAllowed`, then the host closes.

The **token** is 32 random bytes, base64url without padding. The host stores only its SHA-256, with the device's name and certificate fingerprint. A token works only with the certificate it was paired with. Tokens that go unused for 90 days expire; `hiveminds-host devices revoke NAME` removes one at once and closes that device's connections (it gets `deviceRevoked` first).

### 2.4 Requests (after `welcome`)

| Request | Fields | Reply |
|---|---|---|
| `listProjects` | | `projects: [Project]` |
| `listAgents` | | `agents: [Agent]` |
| `createAgent` | `projectId`, `provider`, `model`, `effort`, `access`, `planMode`, `role`, `task`, `ownBranch` | `agent: Agent` (it's starting) |
| `startAgent` | `agentId` | `agent` (starts an asleep agent; picks up its conversation) |
| `stopAgent` | `agentId` | `agent` |
| `restartAgent` | `agentId` | `agent` |
| `deleteAgent` | `agentId` | `keptFolder: Bool` (its worktree is kept if it has uncommitted changes; its branch always stays) |
| `attach` | `agentId` | `cols`, `rows`, then a snapshot frame, then output frames as it draws |
| `detach` | `agentId` | (empty) |
| `takeControl` | `agentId`, `cols`, `rows` | `agent` (you type now; its terminal takes your size) |
| `resize` | `agentId`, `cols`, `rows` | (empty), controller only |
| `typeText` | `agentId`, `text` | (empty): types it as one paste, then Return |
| `answer` | `agentId`, `action`: `allow`/`decline`/`approvePlan`/`keepPlanning`/`answer`, `feedback`?, `answers`? (`[{"option": Int}` or `{"text": String}]`) | `activity` |
| `changes` | `agentId` | `base`, `baseRef`, `onlyItsOwn`, `files: [{"path", "added"?, "removed"?, "untracked"}]` |
| `diff` | `agentId`, `path`, `baseRef`, `untracked` | `lines: [{"kind": "added"|"removed"|"context"|"hunk", "text"}]`, `cut: Bool` |
| `history` | | `agents: [Agent]` (deleted agents, newest first, with `endedAt`) |

Errors include: `noSuchProject`, `noSuchAgent`, `notRunning`, `notController` (with `controller: Device`), `notAsking`, `planChoicesNotFound`, `cantCreate`, `badRequest`, `unknownRequest`, `shuttingDown`.

### 2.5 Typing and control (team use)

- Any number of devices can `attach` to an agent; they're its **viewers**.
- One device at a time is its **controller**. Typing (`0x03` input frames, `typeText`, `answer`) from a device that isn't the controller:
  - makes it the controller if there's none;
  - is refused if someone else is controlling it: input frames are dropped and the host sends `inputRefused`; requests get `notController`. The app then offers Take Over.
- `takeControl` always works; the previous controller gets a `controller` event naming who took over.
- Control is released after 30 s without typing from the controller, or when it disconnects or detaches.
- The agent's terminal (its PTY) is sized to its controller: `takeControl` and the controller's `resize` change it, and the host sends `resized` to every viewer, followed by a fresh snapshot (the screen reflows). Viewers draw at that size, scaled or letterboxed, and never resize it.
- Answers are first come, first served: the first `answer` wins; everyone gets `promptResolved` saying by whom; a later `answer` to the same prompt gets `notAsking`.

### 2.6 Events (host → client)

| Event | Fields | To |
|---|---|---|
| `agentUpdated` | `agent: Agent` | every authenticated client, whenever anything in it changes (status, activity, ask, title, viewers, controller, size) |
| `agentRemoved` | `agentId` | every client |
| `projectsChanged` | `projects: [Project]` | every client |
| `promptResolved` | `agentId`, `by: Device`, `activity` | every client |
| `viewers` | `agentId`, `viewers: [Device]` | every client |
| `controller` | `agentId`, `controller: Device?`, `tookOverFrom: Device?` | every client |
| `resized` | `agentId`, `cols`, `rows` | the agent's viewers (a snapshot follows) |
| `inputRefused` | `agentId`, `controller: Device` | the device that typed |
| `detached` | `agentId`, `reason` | a viewer, when the agent was deleted |
| `deviceRevoked` | | the revoked device, just before the host closes |
| `hostStopping` | `reason`: `stopped`/`systemStop`, `message` | every client, just before the host closes |

After `hostStopping` the app shows "<host> was stopped" and waits for the host to come back (it stops retrying fast; discovery tells it when the host is back). After a dropped connection without it, the app shows "<host> is offline, reconnecting…" and retries with backoff.

## 3. Who may do what

- Every connection is unauthenticated until `welcome`. Before that, only `hello`, `pairStart` and `pairConfirm` are accepted; anything else gets `error` `notAuthenticated` and the connection is closed.
- A paired device may do anything an agent can: run commands, change files, use the host's Claude Code login. **The host isn't a sandbox.** Every paired device can use every registered project (Ethan, 2026-11-07).
- Every connection, pairing, revocation and every request that changes something (create, start, stop, restart, delete, take control, answer, typing) is written to the **audit log** with the device: `~/.local/state/hiveminds-host/audit.log`, one JSON object per line. Typing is logged once per burst (when a device starts typing into an agent), not per key, and never with what was typed.

## 4. Discovery

The host announces `_hiveminds._tcp` on the local network with Bonjour (macOS) or Avahi (Linux, through its `libdns_sd` compatibility library):

- service name: `hiveminds-<first 8 digits of the host id>`
- TXT: `v=1` (the protocol version) and `id=<host id>` (16 random hex digits, made once)
- no machine, user or project names.

The service record points at the machine's own `.local` name, which the system already announces for itself on the network. HiveMinds adds nothing to it. The app uses the host id to match a discovered host with a paired one, and shows the address and fingerprint (not a name) for hosts it hasn't paired with.

## 5. Security notes

- **The network is not trusted.** The host listens only on private addresses (RFC 1918, link-local, IPv6 unique local and link-local, and loopback) unless `--listen` says otherwise, and refuses connections whose peer address isn't private, even on `--listen`.
  - It leaves out interfaces that reach past the local network even with a private address: point-to-point links (VPN tunnels such as `utun`), Apple's peer-to-peer Wi-Fi (`awdl`, `llw`, used by AirDrop), and IPv6 link-local addresses on interfaces that have no other private address.
  - It follows address changes (a new Wi-Fi network, DHCP) through the system's routing events (a routing socket on macOS, netlink on Linux), without polling.
- A passive listener sees only TLS. Someone able to sit in the middle of the connection can't pair (SPAKE2, §2.3) and can't impersonate a paired host (pinned fingerprint) or device (a token is bound to its certificate).
- Web pages can't reach the host: browsers can't present the client certificate a device was paired with, can't set `Host: hiveminds`, and always send `Origin` on WebSocket.
- Pairing codes are 6 digits, valid 60 s, single use, 3 tries. An attacker gets at most 3 guesses per code the owner shows, and each code still needs the owner's `y`.
- Secrets on disk: the host's key, certificate and token hashes are 0600 in a 0700 folder. Tokens are never stored, only their hashes.

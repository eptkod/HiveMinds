# HiveMinds Host: phase 0 report (2026-11-07)

Phase 0 of `docs/LINUX-HOST-SPEC.md` §12: three go/no-go spikes. **Recommendation: go**, with the changes under "What phase 1 onwards should do differently" below. Nothing in the app changed in this phase.

The spike code is in `spikes/host-phase0/` (see its README). It isn't part of the app's package.

## Where it ran

- **Mac:** this Mac (Apple M2), Command Line Tools only, Swift 6.4.0, macOS 26.5 SDK (as `scripts/build-app.sh` picks it).
- **Linux:** Ethan's CachyOS PC wasn't ready, so a Lima VM on this Mac stood in: Ubuntu 26.04 arm64, Swift 6.4.2 from swiftly. It proves the Linux code paths (glibc, epoll, PTYs, BoringSSL). It doesn't prove CachyOS x86_64 specifically; that check is still owed (see "Still to check").
  - The VM is `hiveminds-linux` (`limactl shell hiveminds-linux`). `brew install lima` was the only thing installed on the Mac.

## 0b. Dependencies: pass, with one pin

swift-nio 2.105.0 (NIOCore, NIOPosix, NIOHTTP1, NIOWebSocket), swift-nio-ssl 2.37.6, swift-crypto 3.15.1, swift-certificates 1.21.1, swift-asn1 1.7.4, plus SwiftTerm 1.11.2.

- **Mac, Command Line Tools only:** builds, after one fix. swift-collections 1.4 and later gate code on `#if compiler(>=6.4)` and then use standard-library types that only exist in the macOS 27 SDK, so with CLT's 6.4 compiler and the 26.5 SDK they fail (`cannot find type 'BorrowingIteratorProtocol'`). Pinning `swift-collections` to `"1.1.0"..<"1.4.0"` (resolves to 1.3.0) fixes it; NIO is happy with that. Clean debug build of everything: about 75 s.
- **Linux:** builds first time, debug and `-c release --static-swift-stdlib`. The static binary needs only glibc, libstdc++, libgcc_s and libm (all always present on Arch/CachyOS).
  - Size: 132 MB unstripped, 70 MB stripped (arm64). Most of that is Foundation's ICU data; using `FoundationEssentials` in the host can likely cut it a lot (phase 5).
  - Idle: 47 MB RSS, 0 s CPU over 20 s idle with a server listening and an agent running.

## 0c. Linux terminal: pass, after fixing three things

What was built: the host runs the program in a PTY and feeds its output into a headless SwiftTerm `Terminal`. Viewers connect over TLS + WebSocket. On attach a viewer gets a **snapshot** (bytes that rebuild the screen, scrollback, colours, wraps, links, cursor and terminal modes), then the live stream. A "sync" message checks a viewer's state equals the host's at that moment.

Tests (all pass on the Mac and on Linux):
- Scenarios: 300 lines of coloured output with wrapped lines, wide characters (CJK, emoji, combining marks), a hyperlink, coloured erases and gaps; a full-screen program on the alternate screen with mouse, paste and cursor modes and a scroll region; and real **Claude Code**.
- In each, viewer A watches from before the program starts (sees every byte) and viewer B joins late, detaches, misses output while A types, then reattaches into a brand new terminal. B must equal the host (snapshot compare) and A, **cell by cell** (character, width, colours, style, link, empty vs space, wraps, cursor, modes).
- **Across machines:** host in the Linux VM running Claude Code, two viewers on the Mac over the network: pairing, both viewers, typing, detach/reattach. All pass.

Fixed along the way (each would have shown as a bug in the real thing):
1. **SwiftTerm misreads Claude Code's start-up.** Claude Code sends `ESC[?u` (asking whether the terminal speaks the kitty keyboard protocol). SwiftTerm 1.11.2 ignores the `?` and treats it as "restore cursor", so drawing jumps to an old position and the welcome screen comes out garbled. Found by recording Claude Code's raw output and replaying the same bytes into SwiftTerm and into tmux: tmux was clean, SwiftTerm wasn't, and stepping through showed the cursor jump at exactly that sequence. Patched so only a plain `CSI u` restores the cursor; afterwards SwiftTerm's screen matches tmux. **The Mac app has the same bug.** It likely goes unnoticed there because the app resizes the terminal as it lays out, which makes Claude Code redraw everything; a headless host never resizes, so it stays garbled. Not yet confirmed in the app itself.
2. **SwiftTerm hides state a snapshot needs:** whether a line wraps, the normal screen while the full-screen one is up, cursor visibility, keypad/origin/wrap/focus modes, mouse encoding, and empty vs written cells. Fixed with one added file of read-only accessors (`HiveMindsAccess.swift`) and one `private` → `internal`.
3. **Empty cells came back as spaces.** Invisible, but they change copied text and how lines rewrap on resize. The snapshot now skips empty runs with cursor moves (and recreates coloured empty cells with ECH), and the comparison treats empty and space as different.

The patched SwiftTerm is kept as a patch file plus a script that rebuilds it from 1.11.2 (`spikes/host-phase0/Vendor/`); checked that it reproduces the tested copy exactly.

Found and not yet fixed (design input for phase 2):
- **SwiftTerm's `LocalProcess` isn't fit for the host on Linux.** It never reports that the program exited (that call is commented out, and only macOS has a process monitor), so a finished agent would look alive and never be reaped. Its fork also passes the host's open files to the agent: on Linux, `ss` showed the host's listening socket open inside `claude`. The host should have its own small PTY layer: `forkpty`, close every descriptor above 2 in the child, exit monitoring (DispatchSource on macOS, `pidfd` on Linux), and `waitpid`.
- One spike run in about 33 hung (a test harness wait around `LocalProcess`), and 31 further runs didn't reproduce it. The PTY layer above replaces that code, but phase 2 should run its tests in a loop to catch hangs.
- **Viewers must not answer the program.** Each viewer's terminal would answer queries like "where's the cursor?" too, and those answers would arrive as typing. The spike drops them. On the Mac, the remote terminal view will need a small hook to tell keystrokes from terminal replies.

## Pairing: SPAKE2, like Android's wireless debugging

The spec asks for the 6-digit code to be bound to the TLS channel and leaves the method open. An HMAC of the code over both fingerprints is **not** enough: a relay in the middle sees one HMAC and can try all 1,000,000 codes offline in milliseconds. That's what a PAKE prevents.

Chosen: **SPAKE2** (BoringSSL's curve25519 version, the same one Android uses to pair wireless ADB with a 6-digit code). Each side's identity in the exchange is its own certificate fingerprint as seen in TLS, and both then prove the key with an HMAC over both fingerprints. A relay with its own certificate gets a different key even if it knows the code, and it gets one guess per run (3 per code). The spike tests: same code pairs; wrong code fails; 3 wrong tries burn the code; the code is single-use; the host proves it knew the code too; a relay fails.

How it's called: swift-crypto doesn't offer SPAKE2, but swift-nio-ssl already links a full BoringSSL, so a 15-line C header declares its SPAKE2 functions. Those are internal to swift-nio-ssl, so this relies on its exact version (pin it, and a test guards it). The alternative is copying BoringSSL's SPAKE2 and curve25519 C sources into the repo (several thousand lines).

Also tested in the spike: self-signed P-256 certificates both ways (TLS 1.3 only), fingerprint pinning (a different host certificate is refused), a request with an `Origin` header refused with 403, a wrong `Host` header refused.

## 0a. Coupling audit: moderate, extraction is worth doing

The logic sits in two places, with clear seams:
- **`Store.swift` (933 lines)**, an `@MainActor @Observable` class, mixes UI state (selection, sheets, picking, meetings UI), persistence (`state.json`), agent lifecycle (create, worktree, delete), the hook-event state machine (`apply(event:)`), prompt answering (`allow`, `decline`, `approvePlan`, `keepPlanning`, `answer`: key sequences), and UI side effects (sounds, dock badge, `NSApp.requestUserAttention`, `NSWorkspace`).
- **`Terminals.swift`** owns each agent's PTY inside a `LocalProcessTerminalView` (an AppKit view). It also builds the `claude`/`codex` command line (`start`), reads menus off the screen (`menuOptions`), and holds the "couldn't resume, start fresh" rule (`processTerminated`).
- Elsewhere: `Models.swift` imports SwiftUI only for `AgentStatus.color`. `Shell.swift`/`Tools` are Foundation only. `Changes.swift`'s git logic is an `AppStore` extension that needs `tools.git`, project lookup and the spend transcripts. `SignIn` (API keys) uses the Keychain; the host uses its own Claude login, so it doesn't need it. `AgentDefaults` reads UserDefaults; on the host those values come with each request.
- Not portable as written: `EventTail` uses `O_EVTONLY` and `DispatchSource.makeFileSystemObjectSource`, neither of which exists on Linux (checked). It needs an inotify version.
- Views use the store directly in about 300 places (`store.state` 52, `store.agents` 36, ...). Phase 1 doesn't need to touch them.

Proposed `HiveMindsCore` (Foundation + the non-UI SwiftTerm `Terminal`), each piece moved out, not rewritten:
| Piece | From | Effort |
|---|---|---|
| Models (Provider, Effort, Access, AgentStatus minus colour, Project, Agent, PendingAsk, AskQuestion, …) | Models.swift | 0.5 day |
| `LaunchPlan`: the exact `claude`/`codex` arguments and environment for an agent | Terminals.start | 0.5 day |
| `HookInterpreter`: hook event + state → new state + effects (title, has-started, type pending input, turn ended) | Store.apply(event:) | 1 day |
| Prompt answers: key sequences for allow/decline/approve/keep planning/answer, and `menuOptions` reading a `Terminal` | Store, Terminals | 0.5 day |
| Hooks/status-line settings files | Store.writeHooksFile | 0.25 day |
| Git: worktrees, exclude, changes, diffs, EditedFiles | Store, Changes.swift | 1 day |
| `EventTail` for macOS (as now) and Linux (inotify) | Terminals.swift | 0.5 day |
| Snapshot, PTY process layer (host only) | spike | phase 2 |

About **4 to 5 days** including checking the app behaves exactly as before. The app keeps `LocalProcessTerminalView` for This Mac (decision 7), but the command line, hook handling and prompt answers come from Core, so local and remote can't drift. The fallback (a separate small core for the host only) isn't needed.

For phase 4, rather than making every view talk to an `AgentHost` protocol, the store can merge each host's agents into its lists with a host tag, and route actions (start, stop, answer, type) through `LocalHost` or `RemoteHost` for that agent. The terminal slot picks a local or a remote terminal view. That keeps the ~300 view call sites as they are.

## What phase 1 onwards should do differently from the spec

1. **Vendor SwiftTerm 1.11.2 with the patch** into the repo instead of the URL pin. It's still 1.11.2 (and still needs no Metal), and it also fixes the start-up glitch in the app.
2. **Pin swift-collections below 1.4** while building with Command Line Tools (needed once NIO comes in, phase 2/3). Add it to CLAUDE.md's build constraints.
3. **The host gets its own PTY layer**, not SwiftTerm's `LocalProcess` (exit detection on Linux, no leaked descriptors, reaping).
4. **Pairing uses SPAKE2** as above. Write it into `docs/HOST-PROTOCOL.md` in phase 3.
5. **Hook events on Linux** use inotify.

## Still to check

- On real CachyOS x86_64: build, the static binary, the PTY test with a logged-in Claude Code, and Avahi. The VM proved the Linux code but not that machine.
- Claude Code logged in on the host (the VM's Claude Code wasn't logged in, so the tests used its first-run screens: theme picker and trust prompt).
- Whether the start-up glitch shows in the Mac app today.

## Decisions for Ethan

1. Go ahead with phase 1 (Core extraction)?
2. OK to vendor SwiftTerm 1.11.2 with the small patch? (It changes the app's dependency, and it also fixes the app.)
3. OK with SPAKE2 for pairing, called through swift-nio-ssl's BoringSSL with an exact version pin?

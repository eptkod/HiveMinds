# HiveMinds Host, phase 0 spike

Throwaway test program for the go/no-go spikes in `docs/LINUX-HOST-SPEC.md` §12. Results: `docs/HOST-PHASE0-REPORT.md`. Not part of the app; nothing here ships. Kept for the network and pairing code (phase 3 reuses it) and as a record of how phase 0 was tested.

What's in it:
- `Sources/Spike/Snapshot.swift`: turns a headless SwiftTerm `Terminal` into bytes that rebuild it exactly, and a strict cell-by-cell comparison.
- `Sources/Spike/Net.swift`: self-signed certificates, TLS 1.3 both ways with fingerprint pinning, WebSocket with Origin/Host checks, SPAKE2 pairing.
- `Sources/Spike/Agent.swift`: a program in a PTY feeding a headless terminal.
- `Sources/CSpake`: declarations for BoringSSL's SPAKE2, which swift-nio-ssl already links.
- It builds against the repo's vendored SwiftTerm (`../../Vendor/SwiftTerm`, see `Vendor/README.md`). The snapshot code has since moved into `HiveMindsCore` as `TerminalSnapshot`.

## Run it

```
export SDKROOT=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk | sort -V | tail -1)   # Mac with Command Line Tools
swift build
.build/debug/Spike selftest [path/to/claude]   # everything on this machine
```

Across two machines (host on Linux, viewers on the Mac):
```
.build/debug/Spike serve 7420 123456 ~/.local/bin/claude    # on the host: port, pairing code, program
.build/debug/Spike watch HOST 7420 123456 '\e[B'            # on the Mac: pairs, attaches two viewers, types Down
```

Also: `Spike replay FILE COLS ROWS` prints the screen a recorded byte stream produces, and `Spike trace FILE COLS ROWS` prints the cursor after each chunk (used to find the `ESC[?u` bug by comparing with tmux/pyte).

`serve` listens on every interface and has no tokens: spike only, don't leave it running on a real network.

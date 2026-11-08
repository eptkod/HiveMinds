# Vendored code

## SwiftTerm 1.11.2 (`SwiftTerm/`)

The terminal emulator, MIT licensed (`SwiftTerm/LICENSE`), by Miguel de Icaza. It's pinned to 1.11.2 because newer versions need Xcode's Metal compiler. It's kept here, not fetched, because HiveMinds needs a few small changes, all in `swiftterm-1.11.2-hiveminds.patch`:

- **Kitty keyboard fix** (`EscapeSequenceParser.swift`): only a plain `CSI u` restores the cursor. Claude Code sends `CSI ? u` at start-up, which 1.11.2 took as "restore cursor" and garbled its first screen. `CSI ? s` (XTSAVE) is likewise no longer "save cursor".
- **Read-only accessors** (`HiveMindsAccess.swift`, new): terminal modes, both screen buffers, line wraps and empty cells, for HiveMinds Host's screen snapshots.
- `Terminal.mouseProtocol` is `internal` instead of `private`, for the accessors.
- `Package.swift` builds only the library (no fuzzers, benchmarks or their dependencies).

Everything else is upstream, minus tests, docs and sample apps. `setup.sh` rebuilds the folder from upstream plus the patch; to check the checked-in copy matches:

```
mv Vendor/SwiftTerm /tmp/swiftterm-old && Vendor/setup.sh && diff -r /tmp/swiftterm-old Vendor/SwiftTerm
```

To change SwiftTerm: edit `Vendor/SwiftTerm`, then regenerate the patch against a clean 1.11.2 checkout and note the change above.

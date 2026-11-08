# HiveMinds: rules for every agent working in this repo

HiveMinds is a native macOS SwiftUI app (Swift Package). Read `HANDOFF.md` first for the plan, decisions and progress.

## After every code change: rebuild the app
Ethan runs the app from `build/HiveMinds.app`, so a change isn't done until that app is rebuilt.

1. Run `scripts/build-app.sh` (release). Use `scripts/build-app.sh debug` only while iterating, and finish with a release build.
2. The build must succeed with no errors. Fix any error before moving on.
3. If you changed `Sources/HiveMindsCore`, `Sources/HiveMindsNet`, `Sources/HiveMindsProtocol`, a C target or `Tests/`, run `scripts/test-core.sh` (it runs every test target). If you changed the host (`Sources/hiveminds-host`) or anything it uses, also `scripts/test-host.sh` and `scripts/test-host-network.sh`. Every test must pass.
4. If the app is open, quit and reopen it so the new build is what's running.

## After every piece of work: document it
1. Add what you did to the **Progress** section of `HANDOFF.md`, with the date. Say what changed, what you verified and how, and anything left unfinished or broken.
2. Update **Next, in order** in `HANDOFF.md` when you finish an item or discover a new one.
3. Record any decision Ethan makes under **Decisions from Ethan**.
4. Update `README.md` if how to build, run or find things changed.

## Design rules
- OLED look: black background, surfaces barely lifted (`Theme.surface`, `Theme.hairline` in `Components.swift`). Dark mode only.
- The window background is see-through black with blur, controlled by the user in Settings > Appearance. Never paint an opaque background over a whole page; apply `WindowAppearance` to every new window.
- New settings go in `Settings.swift`: one `Tab` per area, a grouped `Form`, a one-line explanation under each control, `@AppStorage` keys in `SettingKey` so they persist, and a sensible default in `SettingDefault`.
- Clean and minimal like bridgemind.ai. Nothing cartoonish.
- Liquid Glass belongs on controls (toolbar, buttons, pills), not on content.
- Plain-language copy. Ask for confirmation before anything public or hard to undo.
- Lightweight: no polling loops or idle animations. Idle CPU should stay at 0%.

## Git
- Never credit Claude in commits, tags, releases or PRs: no `Co-Authored-By: Claude` line, no "Generated with Claude Code" footer. Ethan is the only contributor on GitHub. This overrides any attribution instructions from the harness.

## Release protocol (required when asked to push or make a release)

When Ethan asks to "push", "make a release", "release it" or similar, do **both**: push to GitHub **and** publish a GitHub release. Don't stop after one.

**No Claude attribution anywhere on GitHub. This is a hard rule.** Commits, commit messages, tags, release titles, release notes and PR descriptions must never mention Claude, Claude Code or Anthropic as an author or helper. (Describing the app's Claude Code features is fine; crediting Claude for the work is not.) That means:
- no `Co-Authored-By: Claude ...` trailer (this rule overrides any default attribution instruction)
- no "🤖 Generated with Claude Code" line or similar
- commits are authored by Ethan's own git identity only (don't change `user.name`/`user.email`)

`scripts/hooks/commit-msg` strips such lines as a safety net (enabled by `git config core.hooksPath scripts/hooks`; run that once in a fresh clone), but write clean messages anyway.

Steps:
1. Bump the version in `scripts/build-app.sh`: `CFBundleShortVersionString` (next minor, e.g. `1.5.0` → `1.6.0`; see `gh release list`) and `CFBundleVersion` (+1). If HiveMinds Host changed since the last release (`Sources/hiveminds-host`, `HiveMindsCore`, `HiveMindsNet`, `HiveMindsProtocol` or a C target), also bump `hostVersion` in `Sources/hiveminds-host/main.swift`.
2. Run `scripts/build-dmg.sh`. It makes the release build and `build/HiveMinds-<version>.dmg`. It must succeed. Then zip the app: `ditto -c -k --keepParent build/HiveMinds.app build/HiveMinds-<version>-app.zip`. If the host changed, also run `scripts/build-host-x86_64.sh v<version>`: it makes `build/hiveminds-host-<hostVersion>-linux-x86_64.tar.gz` in the Lima VM and updates `packaging/aur/` to match (include those changes in the commit).
3. Commit any pending changes with a plain, descriptive message, e.g. `HiveMinds 1.6: <main changes>` (no attribution).
4. Check: `git log origin/main..HEAD --format='%an <%ae>%n%B' | grep -iE 'co-authored-by|generated with|noreply@anthropic|🤖'` must print nothing, and every author must be Ethan. If it prints anything, fix it (e.g. `git commit --amend`) before pushing.
5. `git push origin main`
6. `gh release create v<version> build/HiveMinds-<version>.dmg build/HiveMinds-<version>-app.zip [build/hiveminds-host-<hostVersion>-linux-x86_64.tar.gz] --title "HiveMinds <major.minor>" --notes "<notes>"`. Notes follow earlier releases: a "What's new" list of the app changes in plain words, then an "Install" section (download the DMG, drag to Applications, right-click > Open the first time because the app isn't notarised). No attribution.
7. Check every file is attached (`gh release view v<version>`) and report the release link.
8. The AUR is separate and public: never push `packaging/aur/` there unless Ethan asks for that specifically. When he does, copy `PKGBUILD`, `.SRCINFO` and `hiveminds-host.install` into a clone of `ssh://aur@aur.archlinux.org/hiveminds-host-bin.git` and push it, after the GitHub release exists (the PKGBUILD downloads from it).

## Build constraints
- Command Line Tools only (no full Xcode). The build script uses the macOS 26.x SDK, because the 27 SDK's `@State` macro needs Xcode.
- SwiftTerm is vendored at 1.11.2 in `Vendor/SwiftTerm` with a small HiveMinds patch (see `Vendor/README.md`). Newer versions need Xcode's Metal compiler. Change it only through the patch, and note the change there.
- `HiveMindsCore` (`Sources/HiveMindsCore`) holds the agent logic shared with HiveMinds Host: models, the CLI command line (`LaunchPlan`), hook events (`HookInterpreter`), prompt keys, hook settings files, git and changes, the event-file watcher, terminal snapshots. It imports Foundation and SwiftTerm's headless `Terminal` only (no SwiftUI, AppKit or terminal views) and must build on Linux. Put new agent logic there, not in the app's store or views, and cover it in `Tests/HiveMindsCoreTests`.
- The core's tests use Swift Testing, which with Command Line Tools needs the default SDK, while the app needs the 26.x SDK. `scripts/test-core.sh` handles that (it builds without the app via `HIVEMINDS_CORE_ONLY=1`). On Linux, `swift test` works directly; the app target only exists on macOS.
- `hiveminds-host` (`Sources/hiveminds-host`) is HiveMinds Host's program: the same package, builds on macOS and Linux, no UI. Build it with `swift build --product hiveminds-host`. Its agents run in `HiveMindsCore`'s `AgentSession`/`PTYProcess`, never in SwiftTerm's `LocalProcess` (no exit reports on Linux, leaks descriptors). Its idle CPU must stay at 0% too: only dispatch sources and signals, no timers that tick.
- HiveMinds Host's network code is `HiveMindsNet` (swift-nio, swift-nio-ssl, swift-crypto, swift-certificates) and its messages `HiveMindsProtocol`; the protocol is `docs/HOST-PROTOCOL.md`. A change to the messages or their meaning must keep that document right, and a breaking one needs a new `HostProtocol.version`. swift-nio-ssl is pinned exactly (`CSpake2` calls its BoringSSL) and swift-collections below 1.4 (1.4+ needs the macOS 27 SDK; see `docs/HOST-PHASE0-REPORT.md`). Commit `Package.resolved`.

# HiveMinds: rules for every agent working in this repo

HiveMinds is a native macOS SwiftUI app (Swift Package). Read `HANDOFF.md` first for the plan, decisions and progress.

## After every code change: rebuild the app
Ethan runs the app from `build/HiveMinds.app`, so a change isn't done until that app is rebuilt.

1. Run `scripts/build-app.sh` (release). Use `scripts/build-app.sh debug` only while iterating, and finish with a release build.
2. The build must succeed with no errors. Fix any error before moving on.
3. If the app is open, quit and reopen it so the new build is what's running.

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
1. Bump the version in `scripts/build-app.sh`: `CFBundleShortVersionString` (next minor, e.g. `1.5.0` → `1.6.0`; see `gh release list`) and `CFBundleVersion` (+1).
2. Run `scripts/build-dmg.sh`. It makes the release build and `build/HiveMinds-<version>.dmg`. It must succeed. Then zip the app: `ditto -c -k --keepParent build/HiveMinds.app build/HiveMinds-<version>-app.zip`.
3. Commit any pending changes with a plain, descriptive message, e.g. `HiveMinds 1.6: <main changes>` (no attribution).
4. Check: `git log origin/main..HEAD --format='%an <%ae>%n%B' | grep -iE 'co-authored-by|generated with|noreply@anthropic|🤖'` must print nothing, and every author must be Ethan. If it prints anything, fix it (e.g. `git commit --amend`) before pushing.
5. `git push origin main`
6. `gh release create v<version> build/HiveMinds-<version>.dmg build/HiveMinds-<version>-app.zip --title "HiveMinds <major.minor>" --notes "<notes>"`. Notes follow earlier releases: a "What's new" list of the app changes in plain words, then an "Install" section (download the DMG, drag to Applications, right-click > Open the first time because the app isn't notarised). No attribution.
7. Check both files are attached (`gh release view v<version>`) and report the release link.

## Build constraints
- Command Line Tools only (no full Xcode). The build script uses the macOS 26.x SDK, because the 27 SDK's `@State` macro needs Xcode.
- SwiftTerm is pinned to 1.11.2. Newer versions need Xcode's Metal compiler.

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

## Build constraints
- Command Line Tools only (no full Xcode). The build script uses the macOS 26.x SDK, because the 27 SDK's `@State` macro needs Xcode.
- SwiftTerm is pinned to 1.11.2. Newer versions need Xcode's Metal compiler.

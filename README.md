<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo/wordmark-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="branding/logo/wordmark-light.svg">
    <img src="branding/logo/wordmark-dark.svg" alt="HiveMinds" width="420">
  </picture>
</p>

<p align="center">A calm, native macOS app for running Claude Code and Codex agents across your projects.</p>

<p align="center">
  <img src="branding/icon/icon-1024.png" alt="HiveMinds app icon" width="128">
</p>

HiveMinds is a personal remake of Agent Office with a minimal, OLED-black Liquid Glass interface. Every project gets a Canvas showing all of its agents' terminals and browser tabs at once, and agents can work on their own branches, open pull requests and hold meetings with each other.

## Features

- **Projects and agents:** run many agents across many projects, each with a short title, a model, an effort level and an access level (Auto review, Manual review or Unrestricted).
- **Canvas:** every agent terminal and browser tab in a project, side by side, usable in place. Drag tiles by their title bar to rearrange them.
- **Own branches and pull requests:** an agent can work in its own git worktree. HiveMinds drafts the pull request and opens it with `gh` once you confirm.
- **Meetings:** several agents debate or review a topic in their own worktree and write up the outcome.
- **GitHub in a couple of clicks:** sign in through the GitHub CLI, then clone repos into a projects folder you pick once.
- **Usage at a glance:** the Claude plan's 5-hour and weekly limits, a token and cost estimate on every tab, and Overview charts of your activity.
- **Lightweight:** native SwiftUI, no idle animations, see-through black window with adjustable blur.

## Install

Download `HiveMinds-<version>.dmg` from the [latest release](https://github.com/eptkod/HiveMinds/releases/latest), open it and drag HiveMinds into Applications.

The app isn't notarised, so the first time macOS may block it. Right-click HiveMinds in Applications and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/HiveMinds.app
```

Requires macOS 26 or later, [Claude Code](https://docs.claude.com/en/docs/claude-code) (and optionally Codex), and the [GitHub CLI](https://cli.github.com) (`gh`).

## Build from source

Swift with the Command Line Tools is enough; full Xcode isn't needed.

```sh
scripts/build-app.sh          # release build into build/HiveMinds.app
open build/HiveMinds.app
scripts/build-dmg.sh          # release build packaged as build/HiveMinds-<version>.dmg
```

For development, `scripts/build-app.sh debug` builds a debug app. The build uses the macOS 26.x SDK, and SwiftTerm is pinned to 1.11.2.

## Where things live

- Settings: Cmd+comma. Saved in UserDefaults (`com.ethan.hiveminds`), so they survive restarts.
- App data: `~/Library/Application Support/HiveMinds/` holds `state.json` (projects, agents, browser tabs), the Claude settings files agents start with (`claude-hooks.json`, plus `claude-hooks-api-key.json` and `claude-api-key.json` for API-key sign-in), `statusline.sh` and `usage.json` for the plan usage meter, and per-agent event logs.
- Project workspace: pick a project's "Canvas" row to see every agent's terminal and every browser tab at once, each usable in place (drag a tile by its title bar to move it). Tabs along the top switch between agents, browser tabs and meetings (Cmd+T for a new browser tab, Cmd+G for the Canvas). Each of the project's meetings shows on the Canvas as a chat of what its seats say and write, then its outcome once it's finished; its X only takes it off the Canvas.
- API keys: Settings > Accounts lets Claude Code and Codex each sign in with an API key instead of your plan. Keys are kept in the macOS Keychain ("HiveMinds API key"), never in a file.
- Projects cloned from GitHub: `<projects folder>/<repo>`. HiveMinds asks for the folder the first time and remembers it; change it in Settings > Projects. An existing checkout (including Agent Office's) is reused.
- Branding (logo, app icon, colours): `branding/`. Change `branding/scripts/render.swift`, run `branding/scripts/render.sh`, then rebuild the app.
- Agents on their own branch: `<project>/.hiveminds/worktrees/<title-slug>-<id>`.
- Pull requests: an agent on its own branch has a pull-request button in its header. It drafts a title and description, then pushes the branch and opens the PR with `gh` only when you confirm. PRs an agent opens itself are picked up after its turn ends.
- Meetings (the Meetings switch in the toolbar, or Shift+Cmd+N): each runs in its own worktree, `<project>/.hiveminds/worktrees/meeting-<topic>-<id>` on branch `hive/meeting-…`. Turn notes go in `.hiveminds/meetings/<date>-<topic>/` inside it, and the outcome in `docs/decisions/<date>-<topic>.md` (a review panel's combined review stays in the notes folder). Meeting defaults are in Settings > Meetings.
- Usage history of deleted agents, kept for the Overview charts: `~/Library/Application Support/HiveMinds/history.json`.
- Per-agent status line snapshots (cost and tokens, used for meeting totals): `~/Library/Application Support/HiveMinds/status/<agent id>.json`.
- Token badges (tokens used and the API-price estimate, top right of every agent, meeting and Canvas header): code in `Sources/HiveMinds/TokenUsage.swift`. Each agent's cost and transcript paths are saved in `~/Library/Application Support/HiveMinds/spend.json`; tokens are counted from Claude Code's transcripts.
- Testing a meeting without touching your real state (debug build): `HIVEMINDS_SUPPORT_DIR=/tmp/x HIVEMINDS_TEST_MEETING=/path/to/git/repo build/HiveMinds.app/Contents/MacOS/HiveMinds` runs a short Haiku debate and prints its progress. The repo must be in a folder Claude Code already trusts.

## Branding

The logo, app icon and colours live in `branding/`; see `branding/README.md` for how to use them. Honey (`#F5B53D`) is the single accent on an ink-black base.

See `HANDOFF.md` for the plan, decisions and progress.

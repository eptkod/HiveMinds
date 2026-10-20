# Decision: chat and computer use with Claude and ChatGPT in HiveMinds

## Question
Is it feasible to add plain chat (not code agents) with Claude and ChatGPT, plus computer use, to HiveMinds?

## Options considered
1. **Wrap the existing CLIs** (`claude -p`, `codex exec`) as a chat mode. Cheap and uses existing logins, but the CLIs behave like code agents. Codex isn't general ChatGPT chat. Per-turn startup is slow, and there are no real attachments or model picker. **Rejected** as the default.
2. **Direct API chat client** (Anthropic Messages, OpenAI Responses, streamed over `URLSession`) behind a small `ChatProvider` protocol. Real chat feel, and it reuses the 1.1 API-key sign-in. The cost is API billing, so subscribers get nothing. **Chosen.**
3. **Computer use** (screenshot, action, CGEvent loop). Highest value and highest risk. **Not committed.**

## Decision
**Feasible. Build in phases, chat first, computer use only if a spike passes.**
- **Phase 1:** a direct API chat tile, Claude first, with a `ChatProvider` seam for OpenAI.
  - Off by default behind a setting. The copy says plainly that it bills separately from subscriptions.
  - Chats are stored locally with the same care as the API key, since they may contain secrets.
  - Build order: API key from 1.1, then a streaming client, then the tile, then history.
- **Phase 2:** attach files only, with a confirmation on every attach, because contents go to a third party. Web search and other tools are not planned.
- **Phase 3 (computer use):** no commitment. First a one-day spike to see whether Screen Recording and Accessibility grants survive a rebuild of the CLT-only build. If they don't, it's a no. If they do, prototype Anthropic-only, off by default, with per-action confirmation, a visible Stop button and a spend cap.
- **Trial measure:** if Ethan opens chat on fewer than 3 days in the first two weeks, remove it. The 3-day figure is the Chair's proposal and Ethan can change it.

## Why
- The app already has key storage, tiles and history, so chat is mostly a streaming client and a view.
- Computer use is a different risk class: cost, prompt injection, irreversible actions and macOS permissions.

## Disagreement left
- **Debater 2** marked "not settled". Their open point is whether Ethan has API keys for both vendors, which could change the plan. They'd run a half-day CLI spike only if he has none. The other two accept that as a fallback, not the plan.
- **Ethan decides first:** does he want chat in HiveMinds at all, and if so, agent-focused chat or a general chat app?

## Next steps
1. Ask Ethan the two questions above (API keys for both vendors, and whether chat belongs here). Record the answers under Decisions from Ethan in `HANDOFF.md`.
2. If yes, build Phase 1 behind a setting, then rebuild with `scripts/build-app.sh` and log it in `HANDOFF.md`.
3. Run the one-day computer-use permissions spike in parallel.
4. Review after two weeks against the trial measure.

# Docs Index (Claude HUD Debugging)

Use this map to select the smallest set of docs needed for the issue. Prefer internal docs for current behavior, and Claude Code docs for hook payload schema and CLI behavior.

## Core Internal Docs

- `.claude/docs/state-detection-map.md` — Current state detection behavior, truth tables, and open questions; start here for state anomalies.
- `.claude/docs/hook-operations.md` — Hook state machine, sessions.json schema, debug commands, and troubleshooting.
- `.claude/docs/debugging-guide.md` — General debugging commands and common fixes.
- `.claude/docs/development-workflows.md` — Build/test steps and hook modification guidance. Note: references to hook-state-machine/hook-prevention-checklist are legacy.
- `.claude/docs/architecture-overview.md` — High-level system orientation; verify file lists against current code.
- `.claude/docs/agent-sdk-migration-guide.md` — Differences between SDK hooks and CLI hooks.

## Claude Code Docs (Repo)

- `docs/claude-code/hooks.md` — Authoritative hook payloads, matcher behavior, and CLI hook execution details.
- `docs/claude-code/troubleshooting.md` — Installation/configuration issues that can mimic HUD problems.
- `docs/claude-code/setup.md` — Setup and health checks for Claude Code.
- `docs/claude-code/plugins.md` — Plugin hook behavior when plugins are involved.
- `docs/claude-code-artifacts.md` — Disk artifact inventory (debug logs, transcripts, shell snapshots).

## Secondary Docs (as needed)

- `docs/claude-code/statusline.md` — Statusline hooks and output behavior.
- `docs/claude-code/plugin-marketplaces.md` — Marketplace/plugin distribution details.

## Doc Drift Guardrails

- Treat doc guidance as a starting point; confirm with current code and real logs.
- Call out any mismatches between docs and observed behavior.
- If a referenced doc or path does not exist, mark it as legacy and rely on the current codepath.

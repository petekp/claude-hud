# Automated Demo Vertical Slice (Project Flow v1)

This runbook generates a deterministic 30-45s demo MP4 for the Swift macOS app using real Accessibility (AX) interactions.

## Preconditions

- macOS host with GUI session unlocked.
- `ffmpeg` and `ffprobe` installed.
- Ghostty installed if you plan to use `--with-ghostty`.
- Accessibility permission granted for:
  - Terminal (or the shell host running the script)
  - `osascript` / System Events automation
  - Swift process that executes `scripts/demo/ax_runner.swift`
- Build/runtime dependencies already configured (`./scripts/dev/setup.sh` completed at least once).

## One-command run

```bash
./scripts/demo/run-vertical-slice.sh
```

Record side-by-side with Ghostty (for visible session switching):

```bash
./scripts/demo/run-vertical-slice.sh --with-ghostty
```

State-focused reel (Ready/Working/Waiting/Compacting transitions):

```bash
./scripts/demo/run-vertical-slice.sh \
  --with-ghostty \
  --scenario ./scripts/demo/scenarios/project_flow_states_v1.json \
  --record-seconds 22 \
  --click-mode visible
```

Save your current Capacitor + Ghostty arrangement so future runs reuse it:

```bash
./scripts/demo/save-window-layout.sh
```

Use your own project roster (including hidden section placement):

```bash
./scripts/demo/run-vertical-slice.sh \
  --with-ghostty \
  --projects-file ./scripts/demo/fixtures/project-roster.example.json
```

The command will:

1. Back up host state files used by the debug app.
2. Set demo env vars via `launchctl` (including `CAPACITOR_CHANNEL=alpha`).
3. Launch/rebuild the debug app via `./scripts/dev/restart-app.sh --alpha`.
4. Start bounded-window recording (`screencapture`).
5. Execute AX scenario steps from the selected scenario JSON file.
6. Convert MOV to MP4 with `ffmpeg`.
7. Validate output duration and non-zero frame count.
8. Restore backups and clear demo env vars.

When `--with-ghostty` is set, the runner:

1. Launches/focuses Ghostty.
2. Applies saved layout from `artifacts/demo/window-layout.env` when present (otherwise auto-tiles windows).
3. Records the union of both windows.
4. Defaults `CAPACITOR_DEMO_DISABLE_SIDE_EFFECTS=0` so project-card clicks can trigger real terminal activation.

To force click behavior:

- Scenario-driven (default): `--click-mode scenario`
- Always AXPress (no mouse events): `--click-mode ax`
- Always visible synthetic mouse clicks: `--click-mode visible`

## Output contract

- MP4 artifact:
  - `artifacts/demo/<scenario-name>-<timestamp>.mp4`
- Companion log:
  - `artifacts/demo/<scenario-name>-<timestamp>.log`

## Expected visible flow

- App settles with fixture-backed project list.
- Fixture includes a larger project list plus a populated `HIDDEN` section.
- Card 1 interaction.
- Navigate to project details, then back to list.
- Switch to dock layout (`Cmd+2`).
- Card 2 interaction.
- Switch back to vertical layout (`Cmd+1`).
- Final outro hold.
- In `project_flow_states_v1`, cards visibly rotate through `Ready`, `Working`, `Waiting`, and `Compacting`.
- In demo mode, the header feedback button is hidden for a cleaner capture.
- To customize visible/hidden projects, pass `--projects-file` (or set `CAPACITOR_DEMO_PROJECTS_FILE`).

Projects file JSON schema:

```json
{
  "projects": [
    {
      "name": "Capacitor",
      "path": "/absolute/path/to/project",
      "displayPath": "/optional/custom/display/path",
      "taskCount": 12,
      "hidden": false,
      "initialState": "working"
    }
  ],
  "hiddenProjectPaths": ["/absolute/path/to/project"]
}
```

`initialState` supports: `ready`, `working`, `waiting`, `compacting`, `idle`.

`project_flow_v1.json` marks click steps with `"visible": true`, so the cursor/click can be shown in capture.

## Common failures and fixes

- `Accessibility permission is required for AX automation`
  - Fix: grant Accessibility access in System Settings -> Privacy & Security -> Accessibility.
- `Timed out waiting ... for AX identifier ...`
  - Fix: confirm app is in demo mode and identifiers exist in current build; rerun after `./scripts/dev/restart-app.sh --alpha`.
- `No window found for process`
  - Fix: ensure app launch succeeded and no modal sheet blocks initial window.
- `No window found for Ghostty process`
  - Fix: open Ghostty once manually, grant Accessibility permissions, then rerun with `--with-ghostty`.
- `Failed to launch Ghostty (open -a Ghostty)`
  - Fix: install Ghostty or run without `--with-ghostty`.
- `Duration check failed`
  - Fix: verify scenario timings and avoid manually interrupting recording.
- `Library not loaded: @rpath/libhud_core.dylib` during `swift test`
  - Fix: stage the dylib before test runs:

```bash
cargo build -p hud-core --release
install_name_tool -id "@rpath/libhud_core.dylib" target/release/libhud_core.dylib
cp target/release/libhud_core.dylib apps/swift/.build/arm64-apple-macosx/debug/
```

## Notes

- The script always attempts host cleanup (env restore + file restore), including failure paths.
- This vertical slice is local-first and intentionally does not include CI integration.

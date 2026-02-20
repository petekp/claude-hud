# Channel + Profile Workflow

## Why this exists

Capacitor now separates:

- **Channel**: distribution audience (`alpha`, `beta`, `prod`, etc.)
- **Profile**: feature posture for local dev (`stable` or `frontier`)

For public alpha polishing, local dev/debug workflows should stay on **`alpha` channel** while still allowing a **frontier** posture for feature exploration.

## Runtime precedence

### Channel resolution

1. `CAPACITOR_CHANNEL` environment variable
2. `CapacitorChannel` in app `Info.plist`
3. `~/.capacitor/config.json` channel
4. Build default

### Profile resolution

1. `CAPACITOR_PROFILE` environment variable
2. `CapacitorProfile` in app `Info.plist`
3. Default: `stable`

## Profiles

| Profile | Intent | Default feature posture |
| --- | --- | --- |
| `stable` | Daily alpha polish and reliability | Alpha-safe defaults (gated features off) |
| `frontier` | Internal planning and feature exploration | All current feature flags on |

Environment feature overrides still apply last:

- `CAPACITOR_FEATURES_ENABLED`
- `CAPACITOR_FEATURES_DISABLED`

## Canonical commands

```bash
# Default: keep working in whatever context is currently active
./scripts/dev/restart-current.sh

# Daily work: alpha + stable
./scripts/dev/restart-alpha-stable.sh

# Frontier work: alpha + frontier
./scripts/dev/restart-alpha-frontier.sh
```

Advanced explicit launch:

```bash
./scripts/dev/restart-app.sh --channel alpha --profile stable
./scripts/dev/restart-app.sh --channel alpha --profile frontier
```

Current context is persisted at:

`~/.capacitor/runtime-context.env`

That means agents can keep using `./scripts/dev/restart-current.sh` and will stay in the active channel/profile unless explicitly switched.

## Alpha-only guardrails in dev/debug

Dev/debug startup blocks non-alpha channels by default.

If you intentionally need non-alpha for debugging:

```bash
CAPACITOR_ALLOW_NON_ALPHA=1 ./scripts/dev/restart-app.sh --channel prod --profile stable
```

The recommended day-to-day command remains:

```bash
./scripts/dev/restart-current.sh
```

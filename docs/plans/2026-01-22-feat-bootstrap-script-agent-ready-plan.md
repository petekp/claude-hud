---
title: "feat: Bootstrap Script for Agent-Ready Development"
type: feat
date: 2026-01-22
status: ready
deepened: 2026-01-22
---

# Bootstrap Script for Agent-Ready Development

## Enhancement Summary

**Deepened on:** 2026-01-22
**Research agents used:** 8 (bash-best-practices, rustup-research, security-sentinel, code-simplicity-reviewer, architecture-strategist, rust-skill, unix-macos-engineer, agent-native-reviewer)

### Key Improvements from Research

1. **Simplified scope** — Removed `--check` mode, Rosetta detection, Homebrew Rust detection, smoke test (YAGNI)
2. **Agent-native output** — Added `--json` flag and semantic exit codes (10-31)
3. **Security hardening** — Download rustup script first, verify, then execute
4. **Better error handling** — `set -Eeuo pipefail` with ERR trap for context
5. **Timeout protection** — Configurable timeouts prevent hung builds

### New Considerations Discovered

- `curl | sh` pattern has security risks—download-verify-execute is safer
- Headless Xcode CLI install possible via `softwareupdate` command
- Exit codes should be semantic (12 = Rust missing) not just 0/1
- Colors should auto-disable when stdout is not a TTY

---

## Overview

Create a single-command bootstrap experience (`scripts/bootstrap.sh`) that validates the macOS environment, installs missing toolchains, builds the project, and verifies success. This addresses the "agent-ready" evaluation finding that Claude HUD scored 64% due to lacking a reproducible environment setup.

**Goal:** Any developer or autonomous agent can go from fresh clone to working app with one command.

## Problem Statement

Currently, setting up Claude HUD requires:
1. Reading CLAUDE.md to understand requirements
2. Manually checking macOS, Rust, Swift, and Xcode versions
3. Installing missing tools via separate commands
4. Running the correct build sequence with `install_name_tool` fix
5. Hoping nothing was missed

This creates friction for:
- **New contributors** who don't know the requirements
- **Autonomous agents** that need deterministic environment validation
- **CI troubleshooting** when builds fail due to environment drift

## Proposed Solution

A `scripts/bootstrap.sh` that:
1. Validates platform (macOS 14+, architecture)
2. Checks/installs Xcode CLI tools
3. Checks/installs Rust 1.77.2+ via rustup
4. Validates Swift 5.9+ (comes with Xcode)
5. Builds Rust core with dylib fix
6. Regenerates UniFFI bindings
7. Builds Swift app
8. Runs cargo tests

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Rust installation | rustup (not Homebrew) | Consistent upgrade path, MSRV support |
| Xcode CLI in CI | Use `softwareupdate` headless install | Avoids GUI dialog |
| Swift too old | Fail with upgrade guidance | Can't upgrade Swift independently |
| Rust too old | Auto-upgrade via rustup | Safe, reversible operation |
| UniFFI bindings | Regenerate always | Prevents checksum mismatch crashes |
| Output format | Human default, `--json` for agents | Both audiences supported |

### Research Insights

**Bash Best Practices:**
- Use `set -Eeuo pipefail` (not just `set -e`) for comprehensive error handling
- Add ERR trap to show failed command and line number
- Use `sort -V` for semantic version comparison (portable to macOS)
- Respect `NO_COLOR` environment variable standard

**Security Considerations:**
- Download rustup script to temp file, then execute (not `curl | sh`)
- Verify `~/.cargo/env` is a regular file before sourcing
- Use `pkill -x "ClaudeHUD"` (exact match) not `pkill -f` (pattern match)
- Clear `DYLD_INSERT_LIBRARIES` to prevent injection

**Agent-Native Patterns:**
- `--json` flag outputs structured events for parsing
- Semantic exit codes (10-31) enable branching on specific failures
- Timeout wrappers prevent hung builds from blocking agents
- Auto-disable colors when stdout is not a TTY

## Technical Approach

### Architecture

```
scripts/bootstrap.sh
├── Section 1: Prerequisites
│   ├── Check macOS version (sw_vers -productVersion)
│   ├── Check architecture (uname -m)
│   ├── Check/install Xcode CLI tools
│   └── Validate Swift version
├── Section 2: Rust Toolchain
│   ├── Check rustc version
│   ├── If missing: install via rustup (download-verify-execute)
│   └── If old: upgrade via rustup update
├── Section 3: Build
│   ├── Kill existing ClaudeHUD processes
│   ├── cargo build -p hud-core --release --locked
│   ├── install_name_tool -id "@rpath/..."
│   ├── Regenerate UniFFI bindings
│   └── swift build
└── Section 4: Verify
    └── cargo test -p hud-core --release --locked
```

### Implementation Phases

#### Phase 1: Script Foundation (~40 lines)

- [ ] Create `scripts/bootstrap.sh` with secure header:
  ```bash
  #!/usr/bin/env bash
  set -Eeuo pipefail
  umask 077
  unset DYLD_INSERT_LIBRARIES
  ```
- [ ] Implement ERR trap with context:
  ```bash
  on_error() {
      echo "ERROR at line $1: ${BASH_COMMAND}" >&2
  }
  trap 'on_error $LINENO' ERR
  ```
- [ ] Implement color setup with auto-detection:
  ```bash
  if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
      RED='\033[0;31m' GREEN='\033[0;32m' # ...
  else
      RED='' GREEN='' # ...
  fi
  ```
- [ ] Add `--help` and `--json` argument parsing

**Success criteria:** Script runs, handles errors gracefully, respects NO_COLOR

#### Phase 2: Prerequisites (~60 lines)

- [ ] macOS version check:
  ```bash
  version=$(sw_vers -productVersion)
  major=${version%%.*}
  (( major >= 14 )) || { error "Requires macOS 14+"; exit 10; }
  ```
- [ ] Architecture detection (informational):
  ```bash
  arch=$(uname -m)
  echo "Architecture: $arch"
  ```
- [ ] Xcode CLI tools with headless support:
  ```bash
  if ! xcode-select -p &>/dev/null; then
      if is_headless; then
          # Use softwareupdate for headless install
          touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
          pkg=$(softwareupdate -l | grep "Command Line Tools" | head -1)
          softwareupdate -i "$pkg"
      else
          xcode-select --install
          # Wait for completion
      fi
  fi
  ```
- [ ] Swift version validation:
  ```bash
  swift_version=$(swift --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
  version_ge "$swift_version" "5.9" || { error "Swift 5.9+ required"; exit 14; }
  ```

**Success criteria:** Validates all prerequisites, installs Xcode CLI headlessly in CI

#### Phase 3: Rust Toolchain (~50 lines)

- [ ] Secure rustup installation (download-verify-execute):
  ```bash
  if ! command -v rustc &>/dev/null; then
      RUSTUP_SCRIPT=$(mktemp)
      trap 'rm -f "$RUSTUP_SCRIPT"' EXIT
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$RUSTUP_SCRIPT"
      sh "$RUSTUP_SCRIPT" -y --default-toolchain stable --profile minimal --no-modify-path
      export PATH="$HOME/.cargo/bin:$PATH"
  fi
  ```
- [ ] Version comparison using `sort -V`:
  ```bash
  version_ge() {
      printf '%s\n%s' "$2" "$1" | sort -V -C
  }
  ```
- [ ] Auto-upgrade if below MSRV:
  ```bash
  current=$(rustc --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if ! version_ge "$current" "$REQUIRED_RUST_VERSION"; then
      rustup update stable --no-self-update
  fi
  ```

**Success criteria:** Rust installed/upgraded securely, PATH configured

#### Phase 4: Build (~40 lines)

- [ ] Kill existing processes safely:
  ```bash
  pkill -x "ClaudeHUD" 2>/dev/null || true
  sleep 1
  ```
- [ ] Build with timeout and locked deps:
  ```bash
  CARGO_TIMEOUT=${CARGO_TIMEOUT:-600}
  timeout "$CARGO_TIMEOUT" cargo build -p hud-core --release --locked
  ```
- [ ] Fix dylib install_name:
  ```bash
  install_name_tool -id "@rpath/libhud_core.dylib" target/release/libhud_core.dylib
  ```
- [ ] Regenerate UniFFI bindings (call existing script or inline):
  ```bash
  cargo run --bin uniffi-bindgen generate \
      --library target/release/libhud_core.dylib \
      --language swift \
      --out-dir apps/swift/bindings
  cp apps/swift/bindings/hud_core.swift apps/swift/Sources/ClaudeHUD/Bridge/
  ```
- [ ] Swift build:
  ```bash
  cd apps/swift && swift build
  ```

**Success criteria:** Full build completes, bindings regenerated

#### Phase 5: Verify & Summary (~30 lines)

- [ ] Run cargo tests:
  ```bash
  cargo test -p hud-core --release --locked --quiet
  ```
- [ ] Print summary with next steps:
  ```bash
  echo "Bootstrap complete!"
  echo "Next: ./scripts/dev/restart-app.sh"
  ```
- [ ] JSON output if requested:
  ```bash
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo '{"status":"success","exit_code":0}'
  fi
  ```

**Success criteria:** Tests pass, clear guidance provided

## Acceptance Criteria

### Functional Requirements
- [ ] `./scripts/bootstrap.sh` works from any directory
- [ ] `./scripts/bootstrap.sh --help` shows usage
- [ ] `./scripts/bootstrap.sh --json` outputs machine-readable results
- [ ] Script installs Rust via rustup if missing
- [ ] Script upgrades Rust via rustup if version < 1.77.2
- [ ] Script fails clearly if Swift < 5.9 with upgrade guidance
- [ ] Script fails clearly if macOS < 14.0
- [ ] Script handles paths with spaces (quoted variables)
- [ ] Script is idempotent (safe to run multiple times)

### Non-Functional Requirements
- [ ] Follows existing script patterns (colors, helpers, sections)
- [ ] Semantic exit codes (see table below)
- [ ] Completes in < 5 minutes on warm cache
- [ ] Works in CI (GitHub Actions macos-14 runner)
- [ ] Respects `NO_COLOR` environment variable

### Quality Gates
- [ ] Script passes shellcheck
- [ ] Script tested on fresh macOS 14 environment
- [ ] Documentation added to CLAUDE.md

## Exit Codes

| Code | Meaning | Auto-Fixable? |
|------|---------|---------------|
| 0 | Success | N/A |
| 1 | Unknown/generic error | No |
| 10 | macOS version too old | No |
| 11 | Xcode CLI tools missing | Yes (in interactive mode) |
| 12 | Rust missing | Yes |
| 13 | Rust version too old | Yes |
| 14 | Swift version too old | No (requires Xcode update) |
| 20 | Cargo build failed | No |
| 21 | Swift build failed | No |
| 22 | UniFFI binding generation failed | No |
| 30 | Cargo test failed | No |

## Success Metrics

| Metric | Target |
|--------|--------|
| Time from clone to running app | < 10 minutes (first run) |
| Time for subsequent runs | < 2 minutes (cached) |
| Agent success rate | 100% on macos-14 runner |
| Manual intervention required | 0 steps after bootstrap |

## Dependencies & Prerequisites

**Required:**
- macOS 14.0+ host (Sonoma)
- Internet connection (for rustup, SPM dependencies)
- ~5GB disk space (toolchains + build artifacts)

**Not Required:**
- Developer certificate (only for distribution)
- Xcode.app (CLI tools sufficient)

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Xcode CLI GUI dialog blocks CI | High | High | Use `softwareupdate` for headless install |
| rustup installation modifies shell | Medium | Low | Use `--no-modify-path`, explicit PATH export |
| Network failure during install | Medium | Medium | Let rustup retry; configurable timeout |
| Rust/Swift version drift | Low | High | Pin versions from Cargo.toml/Package.swift |
| Path spaces break script | Low | Medium | Quote all path variables |
| Hung build blocks agent | Medium | High | Timeout wrappers with `CARGO_TIMEOUT` |

## Alternative Approaches Considered

### Docker/Devcontainer
**Rejected because:** GitHub Codespaces doesn't support macOS, and Docker can't run macOS due to licensing.

### `--check` Validation-Only Mode
**Rejected because:** Script is idempotent—if everything is installed, it completes in seconds. A dry-run mode adds complexity for no benefit.

### Rosetta Detection
**Rejected because:** Low value. The build works regardless of translation layer. YAGNI.

### Homebrew Rust Detection
**Rejected because:** Preemptive defense against a possible issue. If Homebrew Rust causes problems, users will discover it. Solve problems when they occur.

### Smoke Test (Launch App)
**Rejected because:** Duplicates `verify-app-bundle.sh` functionality. Bootstrap builds and tests; launch verification is a separate concern.

## Documentation Plan

Add to CLAUDE.md "Commands" section:

```markdown
## First-Time Setup

```bash
# Full bootstrap (validates + installs + builds)
./scripts/bootstrap.sh

# Machine-readable output for CI/agents
./scripts/bootstrap.sh --json
```
```

## References & Research

### Internal References
- Script patterns: `scripts/release/verify-app-bundle.sh:11-33`
- Build sequence: `.github/workflows/ci.yml:59-70`
- Version requirements: `Cargo.toml:11`, `apps/swift/Package.swift:1,6`
- Existing restart: `scripts/dev/restart-app.sh`

### External References
- [Bash Error Handling with Trap](https://citizen428.net/blog/bash-error-handling-with-trap/)
- [Rustup Installation Options](https://rust-lang.github.io/rustup/installation/other.html)
- [NO_COLOR Standard](https://no-color.org/)
- [sysexits.h Exit Codes](https://www.baeldung.com/linux/status-codes)

### Gotchas (from CLAUDE.md)
- UniFFI bindings must be regenerated after Rust API changes
- install_name_tool required for dylib linking
- Bundle.module doesn't work in distributed builds

## Edge Cases Checklist

From SpecFlow analysis—each must be handled:

- [ ] Fresh macOS with nothing installed → Full install flow
- [ ] Intel Mac (x86_64) → Works, informational message
- [ ] Rust version too old → Auto-upgrade via rustup
- [ ] Swift version too old → Fail with Xcode upgrade guidance (exit 14)
- [ ] macOS version too old → Fail immediately (exit 10)
- [ ] Running in CI ($CI env var set) → Use headless Xcode install
- [ ] Running headless (no TTY) → Auto-disable colors, skip interactive prompts
- [ ] ClaudeHUD already running → Kill with `pkill -x` first
- [ ] Project path contains spaces → All variables quoted
- [ ] Network failure during rustup → Let timeout handle, provide retry message
- [ ] Re-run on already-bootstrapped system → Fast completion, idempotent

## Appendix: Complete Script Template

```bash
#!/usr/bin/env bash
#
# Bootstrap development environment for Claude HUD
# Usage: ./scripts/bootstrap.sh [--help] [--json]
#
# Options:
#   --help     Show this help message
#   --json     Output machine-readable JSON (for CI/agents)
#
# Exit Codes:
#   0   Success
#   10  macOS version too old
#   11  Xcode CLI tools missing (interactive install needed)
#   12  Rust missing (auto-installable)
#   13  Rust version too old (auto-upgradable)
#   14  Swift version too old (Xcode update needed)
#   20  Cargo build failed
#   21  Swift build failed
#   22  UniFFI binding generation failed
#   30  Cargo test failed

set -Eeuo pipefail

# Security hardening
umask 077
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH

# Version requirements (from Cargo.toml and Package.swift)
readonly REQUIRED_RUST_VERSION="1.77.2"
readonly REQUIRED_SWIFT_VERSION="5.9"
readonly REQUIRED_MACOS_VERSION="14"

# Configurable timeouts
CARGO_TIMEOUT=${CARGO_TIMEOUT:-600}

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Output format
OUTPUT_FORMAT="human"

# Colors (auto-detect TTY and NO_COLOR)
setup_colors() {
    if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        CYAN='\033[0;36m'
        NC='\033[0m'
    else
        RED='' GREEN='' YELLOW='' CYAN='' NC=''
    fi
}

# Helpers
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1" >&2; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
info() { echo -e "${CYAN}→${NC} $1"; }

# Error trap with context
on_error() {
    local exit_code=$?
    fail "Command failed at line $1 with exit code $exit_code"
    fail "Command: ${BASH_COMMAND}"
    exit $exit_code
}
trap 'on_error $LINENO' ERR

# Version comparison (returns 0 if $1 >= $2)
version_ge() {
    printf '%s\n%s' "$2" "$1" | sort -V -C
}

# Headless detection
is_headless() {
    [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ ! -t 0 ]]
}

# JSON output helper
emit_json() {
    [[ "$OUTPUT_FORMAT" == "json" ]] && echo "$1"
}

# Usage
show_help() {
    sed -n '3,16p' "$0" | sed 's/^# //'
    exit 0
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) show_help ;;
            --json) OUTPUT_FORMAT="json" ;;
            *) fail "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
}

# Main sections follow...
# (Implementation as described in phases above)

main() {
    setup_colors
    parse_args "$@"

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Claude HUD Bootstrap${NC}"
    echo -e "${GREEN}========================================${NC}"

    # Section 1: Prerequisites
    # Section 2: Rust Toolchain
    # Section 3: Build
    # Section 4: Verify

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Bootstrap complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Next steps:"
    echo "  Run the app:     ./scripts/dev/restart-app.sh"
    echo "  Sync hooks:      ./scripts/sync-hooks.sh --force"

    emit_json '{"status":"success","exit_code":0}'
}

main "$@"
```

# Contributing to Capacitor

Thanks for your interest in contributing! This guide covers everything you need to get a development environment running.

## Prerequisites

- **Apple Silicon Mac** (arm64) — Intel and Rosetta are not supported
- **macOS 14+** (Sonoma or later)
- **Xcode Command Line Tools** — `xcode-select --install`
- **Rust toolchain** — installed automatically by setup if missing

## Getting Started

```bash
git clone https://github.com/petekp/capacitor.git
cd capacitor
./scripts/dev/setup.sh
```

This runs the full bootstrap: validates your environment, installs missing toolchains, builds the Rust core, generates UniFFI bindings, builds the Swift app, and installs pre-commit hooks.

When setup completes, launch the app:

```bash
./scripts/dev/restart-app.sh
```

## Development Workflow

The main iteration loop is:

```bash
./scripts/dev/restart-app.sh
```

This rebuilds Rust and Swift, regenerates bindings, assembles a debug app bundle, and launches it. It's the most common command you'll run.

Useful flags:

- `--swift-only` / `-s` — skip the Rust build (faster when only changing Swift)
- `--force` / `-f` — force full rebuild (invalidates Swift incremental cache)
- `--channel <name>` — set runtime channel (`dev`, `alpha`, `beta`, `prod`)

For Rust-only changes, you can also use cargo directly:

```bash
cargo build -p hud-core --release
cargo build -p hud-hook --release
```

## Testing & Linting

Run the full test suite:

```bash
./scripts/dev/run-tests.sh          # all checks (Rust + Swift)
./scripts/dev/run-tests.sh --quick  # skip Swift tests
```

Or run individual checks:

```bash
cargo fmt             # format Rust code (required before commits)
cargo clippy -- -D warnings  # Rust linting
cargo test            # Rust tests
```

Pre-commit hooks run `cargo fmt --check` and `cargo test` automatically.

## Project Structure

```
capacitor/
├── core/hud-core/        # Rust business logic, UniFFI bindings
├── core/hud-hook/        # Rust CLI hook handler
├── core/daemon/          # Background daemon
├── core/daemon-protocol/ # Daemon wire protocol
├── apps/swift/           # SwiftUI app
└── scripts/              # Dev, CI, and release scripts
```

See [CLAUDE.md](CLAUDE.md) for the full architecture reference, key files, and detailed conventions.

## Submitting Changes

1. Open an issue first for non-trivial changes
2. Fork the repo and create a feature branch
3. Make your changes
4. Ensure all checks pass: `cargo fmt`, `cargo clippy -- -D warnings`, `cargo test`
5. Open a pull request against `main`

### Key conventions

- `cargo fmt` is enforced by pre-commit hooks — run it before committing
- Rust core builds in release mode; Swift links against the release dylib
- After Rust API changes, bindings are regenerated automatically by `restart-app.sh`
- See [CLAUDE.md](CLAUDE.md) and `.claude/docs/gotchas.md` for additional gotchas

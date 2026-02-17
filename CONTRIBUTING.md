# Contributing

## Prerequisites

- Apple Silicon Mac (Intel/Rosetta won't work)
- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- Rust toolchain (setup will install it if you don't have it)

## Getting started

```bash
git clone https://github.com/petekp/capacitor.git
cd capacitor
./scripts/dev/setup.sh
```

Setup validates your environment, installs what's missing, builds everything, and sets up pre-commit hooks.

Once that's done:

```bash
./scripts/dev/restart-app.sh
```

This rebuilds Rust + Swift, regenerates UniFFI bindings, assembles a debug bundle, and launches the app. It's the command you'll run most.

## Development workflow

`restart-app.sh` is the main loop. Some useful flags:

- `--swift-only` / `-s` — skip the Rust build when you're only changing Swift
- `--force` / `-f` — force a full rebuild
- `--channel <name>` — set runtime channel (`dev`, `alpha`, `beta`, `prod`)

For Rust-only work, cargo works fine:

```bash
cargo build -p hud-core --release
cargo build -p hud-hook --release
```

## Testing

```bash
./scripts/dev/run-tests.sh          # everything
./scripts/dev/run-tests.sh --quick  # skip Swift tests
```

Or individually:

```bash
cargo fmt                         # format (required before commits)
cargo clippy -- -D warnings       # lint
cargo test                        # test
```

Pre-commit hooks run `cargo fmt --check` and `cargo test` automatically, so you'll catch issues before pushing.

## Project structure

```
capacitor/
├── core/hud-core/        # Rust business logic, UniFFI bindings
├── core/hud-hook/        # Rust CLI hook handler
├── core/daemon/          # Background daemon
├── core/daemon-protocol/ # Daemon wire protocol
├── apps/swift/           # SwiftUI app
└── scripts/              # Dev, CI, and release scripts
```

[CLAUDE.md](CLAUDE.md) has the full architecture reference, key files, and gotchas.

## Submitting changes

1. Open an issue first for anything non-trivial
2. Fork and branch
3. Make sure `cargo fmt`, `cargo clippy -- -D warnings`, and `cargo test` all pass
4. Open a PR against `main`

`cargo fmt` is enforced by pre-commit hooks. Rust core builds in release mode and Swift links against the release dylib. After Rust API changes, bindings get regenerated automatically by `restart-app.sh`.

See `.claude/docs/gotchas.md` for things that might trip you up.

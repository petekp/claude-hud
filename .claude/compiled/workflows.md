<!-- @task:build-run @load:workflows -->
# Build + Run Workflows

## Quick Dev Loop
```bash
./scripts/dev/restart-app.sh
```

## Rust Core
```bash
cargo fmt
cargo clippy -- -D warnings
cargo test
cargo build -p hud-core --release
```

## Swift App
```bash
cd apps/swift
swift build
swift run
```

## UniFFI Regen (after Rust API changes)
```bash
cargo build -p hud-core --release
cargo run --bin uniffi-bindgen generate --library target/release/libhud_core.dylib --language swift --out-dir apps/swift/bindings
cp apps/swift/bindings/hud_core.swift apps/swift/Sources/Capacitor/Bridge/
```

## Daemon Health
```bash
launchctl print gui/$(id -u)/com.capacitor.daemon
printf '{"protocol_version":1,"method":"get_health","id":"health","params":null}\n' | nc -U ~/.capacitor/daemon.sock
tail -50 ~/.capacitor/daemon/daemon.stderr.log
```

## Hook Build + Install
```bash
cargo build -p hud-hook --release
ln -sf target/release/hud-hook ~/.local/bin/hud-hook
./scripts/sync-hooks.sh --force
```


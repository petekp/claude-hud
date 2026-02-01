//! Fixture-driven tests for Claude adapter resilience.

use hud_core::agents::{AgentAdapter, ClaudeAdapter};
use hud_core::storage::StorageConfig;
use std::path::PathBuf;

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/agents/claude")
        .join(name)
}

/// Creates a ClaudeAdapter for fixture testing.
/// Fixtures use the same directory for both capacitor and claude roots.
fn adapter_for_fixture(name: &str) -> ClaudeAdapter {
    let path = fixture_path(name);
    // Use same dir for both roots (fixtures only validate adapter behavior now).
    let storage = StorageConfig::with_roots(path.clone(), path);
    ClaudeAdapter::with_storage(storage)
}

#[test]
fn test_daemon_only_returns_empty_without_daemon() {
    let adapter = adapter_for_fixture("v2-working");
    let sessions = adapter.all_sessions();

    assert!(sessions.is_empty());
}

#[test]
fn test_corrupted_state_file_returns_empty() {
    let adapter = adapter_for_fixture("corrupted");
    let sessions = adapter.all_sessions();

    assert!(sessions.is_empty());
}

#[test]
fn test_empty_state_file_returns_empty() {
    let adapter = adapter_for_fixture("empty");
    let sessions = adapter.all_sessions();

    assert!(sessions.is_empty());
}

#[test]
fn test_nonexistent_fixture_returns_empty() {
    let adapter = adapter_for_fixture("does-not-exist");
    let sessions = adapter.all_sessions();

    assert!(sessions.is_empty());
}

#[test]
fn test_adapter_id_is_lowercase_no_spaces() {
    let adapter = adapter_for_fixture("v2-working");

    let id = adapter.id();
    assert_eq!(id, id.to_lowercase());
    assert!(!id.contains(' '));
}

#[test]
fn test_is_installed_does_not_panic() {
    let adapter = adapter_for_fixture("v2-working");
    let _ = adapter.is_installed();

    let adapter_missing = adapter_for_fixture("does-not-exist");
    let _ = adapter_missing.is_installed();
}

#[test]
fn test_detect_session_with_nonexistent_path_returns_none() {
    let adapter = adapter_for_fixture("v2-working");
    assert!(adapter.detect_session("/nonexistent/path/12345").is_none());
}

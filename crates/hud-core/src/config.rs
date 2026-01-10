//! Configuration loading and saving utilities.
//!
//! Handles paths and persistence for:
//! - HUD configuration (pinned projects)
//! - Statistics cache

use crate::types::{HudConfig, StatsCache};
use std::fs;
use std::path::PathBuf;

/// Returns the path to the Claude directory (~/.claude).
pub fn get_claude_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".claude"))
}

/// Returns the path to the HUD configuration file.
pub fn get_hud_config_path() -> Option<PathBuf> {
    get_claude_dir().map(|d| d.join("hud.json"))
}

/// Loads the HUD configuration, returning defaults if file doesn't exist.
pub fn load_hud_config() -> HudConfig {
    get_hud_config_path()
        .and_then(|p| fs::read_to_string(&p).ok())
        .and_then(|c| serde_json::from_str(&c).ok())
        .unwrap_or_default()
}

/// Saves the HUD configuration to disk.
pub fn save_hud_config(config: &HudConfig) -> Result<(), String> {
    let path = get_hud_config_path().ok_or("Could not find config path")?;
    let content = serde_json::to_string_pretty(config)
        .map_err(|e| format!("Failed to serialize config: {}", e))?;
    fs::write(&path, content).map_err(|e| format!("Failed to write config: {}", e))
}

/// Returns the path to the statistics cache file.
pub fn get_stats_cache_path() -> Option<PathBuf> {
    get_claude_dir().map(|d| d.join("hud-stats-cache.json"))
}

/// Loads the statistics cache, returning empty cache if file doesn't exist.
pub fn load_stats_cache() -> StatsCache {
    get_stats_cache_path()
        .and_then(|p| fs::read_to_string(&p).ok())
        .and_then(|c| serde_json::from_str(&c).ok())
        .unwrap_or_default()
}

/// Saves the statistics cache to disk.
pub fn save_stats_cache(cache: &StatsCache) -> Result<(), String> {
    let path = get_stats_cache_path().ok_or("Could not find cache path")?;
    let content =
        serde_json::to_string(cache).map_err(|e| format!("Failed to serialize cache: {}", e))?;
    fs::write(&path, content).map_err(|e| format!("Failed to write cache: {}", e))
}

/// Resolves a symlink to its canonical path.
pub fn resolve_symlink(path: &PathBuf) -> Option<PathBuf> {
    if path.exists() {
        fs::canonicalize(path).ok()
    } else {
        None
    }
}

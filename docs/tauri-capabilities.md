# Tauri Capabilities Reference

This document describes what's possible in Tauri for terminal management, process detection, and system automation.

## Terminal Window Detection (via AppleScript)

On macOS, we can detect terminal windows by querying window titles via System Events AppleScript. This approach doesn't require Full Disk Access permissions.

**How it works:**
- Query window titles from terminal apps (Warp, iTerm2, Terminal)
- Window titles typically contain the current working directory
- Match project path or name against window titles

**Usage:**
```rust
let script = r#"tell application "System Events"
    if exists process "Warp" then
        tell process "Warp"
            get name of every window
        end tell
    else
        return {}
    end if
end tell"#;

let output = std::process::Command::new("osascript")
    .arg("-e")
    .arg(&script)
    .output()?;

let titles = String::from_utf8_lossy(&output.stdout);
// titles contains window names like "~/Code/my-project"
```

**Supported terminals:**
- Warp
- iTerm2
- Terminal.app

## Previous Approach: Process Detection (via sysinfo crate)

We previously tried using the `sysinfo` crate to detect terminal working directories via `process.cwd()`. However, this requires Full Disk Access on macOS, which cannot be granted programmatically. The AppleScript window title approach above is preferred.

## Shell Plugin (@tauri-apps/plugin-shell)

The Tauri shell plugin allows spawning and managing child processes.

**Capabilities:**
- Spawn child processes with captured stdout/stderr
- Write to process stdin
- Kill spawned processes
- Execute shell commands

**Limitations:**
- Requires explicit permission configuration in capabilities
- Commands must be pre-configured in allowlist
- Cannot interact with processes spawned outside the app

**Configuration (capabilities/default.json):**
```json
{
  "permissions": [
    "shell:allow-execute",
    "shell:allow-kill",
    "shell:allow-spawn",
    "shell:allow-stdin-write"
  ]
}
```

## Window Focus (macOS)

On macOS, use AppleScript via `osascript` to focus application windows.

**Basic focus:**
```rust
std::process::Command::new("osascript")
    .arg("-e")
    .arg(r#"tell application "Warp" to activate"#)
    .spawn()?;
```

**Supported terminals:**
- Warp
- iTerm / iTerm2
- Terminal.app
- Alacritty
- Kitty

**Note:** More granular window control (focusing specific windows/tabs) requires more complex AppleScript.

## Implementation: Terminal Detection

Claude HUD uses AppleScript to detect existing terminals for a project:

1. **Query window titles** from terminal apps via System Events
2. **Match project path/name** against window titles
3. **Focus existing window** if found, otherwise launch new terminal

```rust
fn find_terminal_for_project(project_path: &str) -> Option<String> {
    let project_name = PathBuf::from(project_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();

    for terminal in ["Warp", "iTerm2", "Terminal"] {
        let script = format!(
            r#"tell application "System Events"
                if exists process "{}" then
                    tell process "{}"
                        get name of every window
                    end tell
                end if
            end tell"#,
            terminal, terminal
        );

        if let Ok(output) = std::process::Command::new("osascript")
            .arg("-e")
            .arg(&script)
            .output()
        {
            let titles = String::from_utf8_lossy(&output.stdout);
            if titles.contains(project_path) || titles.contains(&project_name) {
                return Some(terminal.to_string());
            }
        }
    }
    None
}
```

## Future: Dev Server Detection

Dev server detection could use:
- **lsof**: Find processes with files open in project directory
- **Port scanning**: Check if common dev server ports (3000, 5173, 8080) are in use
- **ps/pgrep**: Search for node/vite/next processes

## Platform Considerations

| Feature | macOS | Linux | Windows |
|---------|-------|-------|---------|
| Window title detection | AppleScript ✅ | wmctrl/xdotool | Windows API |
| Window focus | AppleScript ✅ | wmctrl/xdotool | Windows API |
| Shell script launch | open -a ✅ | xdg-open | start |

**Cross-platform support would require:**
- Linux: `wmctrl` or `xdotool` commands
- Windows: Windows API calls or PowerShell

## Dependencies

No special crate dependencies needed for the AppleScript approach - it uses `std::process::Command` to invoke `osascript`.

## References

- [AppleScript Language Guide](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/)
- [Tauri Shell Plugin](https://v2.tauri.app/plugin/shell/)
- [Tauri Process Plugin](https://v2.tauri.app/plugin/process/)

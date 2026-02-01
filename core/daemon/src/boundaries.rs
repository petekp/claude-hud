//! Project boundary detection for activity attribution.
//!
//! Walks up from a file path to find the nearest project boundary,
//! identified by markers like CLAUDE.md, .git, package.json, etc.
//!
//! This enables accurate attribution of file activity to projects,
//! especially in monorepo scenarios where Claude runs from the repo
//! root but edits files in specific packages.
//! Boundary detection is intentionally conservative to avoid mis-attribution.

use std::path::Path;

/// Maximum depth to walk up when searching for boundaries.
/// Prevents runaway traversal in deeply nested or misconfigured paths.
pub const MAX_BOUNDARY_DEPTH: usize = 20;

/// Directories that should be skipped during boundary detection.
/// These are typically generated/vendored code, not project roots.
pub const IGNORED_DIRECTORIES: &[&str] = &[
    "node_modules",
    "vendor",
    ".git",
    "__pycache__",
    "target",
    "dist",
    "build",
    ".next",
    ".output",
    "venv",
    ".venv",
    "env",
    ".turbo",
    ".cache",
];

/// Project markers in priority order.
/// Lower number = higher priority.
/// CLAUDE.md is explicit intent, package markers beat repo root, .git is fallback.
pub const PROJECT_MARKERS: &[(&str, u8)] = &[
    ("CLAUDE.md", 1),    // Priority 1 (highest) - explicit project marker
    ("package.json", 2), // Priority 2 - package markers
    ("Cargo.toml", 2),
    ("pyproject.toml", 2),
    ("go.mod", 2),
    ("pubspec.yaml", 2), // Dart/Flutter
    ("Project.toml", 2), // Julia
    ("deno.json", 2),    // Deno
    (".git", 3),         // Priority 3 - repository root
    ("Makefile", 4),     // Priority 4 (lowest) - build markers
    ("CMakeLists.txt", 4),
];

/// Paths that are too broad to be meaningful project boundaries.
/// Pinning these would encompass many unrelated projects.
#[allow(dead_code)]
pub const DANGEROUS_PATHS: &[&str] = &["/", "/Users", "/home", "/var", "/tmp", "/opt"];

/// Represents a detected project boundary.
#[derive(Debug, Clone, PartialEq)]
pub struct ProjectBoundary {
    /// Absolute path to the project root
    pub path: String,
    /// The marker file/directory that identified this as a project
    pub marker: String,
    /// Priority of the marker (lower = higher priority)
    pub priority: u8,
}

/// Finds the nearest project boundary by walking up from the given path.
///
/// # Arguments
/// * `file_path` - Path to a file or directory to start from
///
/// # Returns
/// * `Some(ProjectBoundary)` if a boundary is found
/// * `None` if no boundary is found within MAX_BOUNDARY_DEPTH
///
/// # Algorithm
/// 1. Start from the parent of the given path (or the path itself if it's a directory)
/// 2. Walk up, checking for markers at each level
/// 3. Track the highest-priority boundary found so far
/// 4. When we encounter an ignored directory, discard any boundary found so far
///    (it was inside the ignored subtree)
/// 5. CLAUDE.md at any level (outside ignored dirs) immediately wins (priority 1)
/// 6. Otherwise, return the nearest boundary found
/// 7. Stop at root, home directory, or max depth
pub fn find_project_boundary(file_path: &str) -> Option<ProjectBoundary> {
    let path = Path::new(file_path);

    // If path doesn't exist, we can't traverse it
    if !path.exists() {
        return None;
    }

    // Start from the path itself if it's a directory, otherwise its parent
    let start = if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent()?.to_path_buf()
    };

    let mut current = Some(start);
    let mut depth = 0;
    let mut best_boundary: Option<ProjectBoundary> = None;

    // Get home directory for stopping condition
    let home_dir = dirs::home_dir();

    while let Some(dir) = current {
        // Stop conditions
        if depth >= MAX_BOUNDARY_DEPTH {
            break;
        }

        // Check if this directory is ignored (node_modules, vendor, etc.)
        // If so, discard any boundary we found so far (it was inside the ignored subtree)
        // and continue walking up
        if let Some(dir_name) = dir.file_name().and_then(|n| n.to_str()) {
            if is_ignored_directory(dir_name) {
                // Discard any boundary found so far - it was inside this ignored directory
                best_boundary = None;
                // Continue walking up to find boundaries outside the ignored subtree
                current = dir.parent().map(|p| p.to_path_buf());
                depth += 1;
                continue;
            }
        }

        // Check for markers at this level, in priority order
        for (marker, priority) in PROJECT_MARKERS {
            if has_marker(&dir, marker) {
                let boundary = ProjectBoundary {
                    path: dir.to_string_lossy().to_string(),
                    marker: marker.to_string(),
                    priority: *priority,
                };

                // CLAUDE.md (priority 1) immediately wins - it's explicit intent
                if *priority == 1 {
                    return Some(boundary);
                }

                // Track the best (lowest priority number = highest priority)
                // Prefer nearer boundaries at same priority level
                match &best_boundary {
                    None => best_boundary = Some(boundary),
                    Some(existing) if boundary.priority < existing.priority => {
                        best_boundary = Some(boundary);
                    }
                    _ => {}
                }

                // Found a marker at this level, no need to check lower priority markers
                break;
            }
        }

        // Stop at home directory
        if let Some(ref home) = home_dir {
            if dir == *home {
                break;
            }
        }

        // Move to parent
        current = dir.parent().map(|p| p.to_path_buf());
        depth += 1;
    }

    best_boundary
}

/// Checks if a directory name should be skipped during boundary detection.
#[must_use]
pub fn is_ignored_directory(name: &str) -> bool {
    IGNORED_DIRECTORIES.contains(&name)
}

/// Checks if a path is too broad to be a meaningful project boundary.
///
/// # Returns
/// * `Some(reason)` if the path is dangerous, with an explanation
/// * `None` if the path is safe
#[allow(dead_code)]
pub fn is_dangerous_path(path: &str) -> Option<String> {
    // Normalize the path for comparison, handling root specially
    let trimmed = path.trim_end_matches('/');
    let normalized = if trimmed.is_empty() { "/" } else { trimmed };

    // Check against explicit dangerous paths
    for dangerous in DANGEROUS_PATHS {
        if normalized == *dangerous {
            return Some(format!(
                "Path '{}' is too broad and would encompass many projects",
                path
            ));
        }
    }

    // Check if it's a home directory
    if let Some(home) = dirs::home_dir() {
        if normalized == home.to_string_lossy() {
            return Some(format!(
                "Path '{}' is home directory and too broad to pin",
                path
            ));
        }
    }

    None
}

fn has_marker(dir: &Path, marker: &str) -> bool {
    dir.join(marker).exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_marker_wins_over_repo_root() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("repo");
        let app_dir = repo_root.join("packages").join("app");
        let src_dir = app_dir.join("src");

        std::fs::create_dir_all(&src_dir).expect("create dirs");
        std::fs::create_dir_all(repo_root.join(".git")).expect("create git dir");
        std::fs::write(app_dir.join("package.json"), "{}").expect("write package marker");
        std::fs::write(src_dir.join("main.rs"), "fn main() {}").expect("write file");

        let file_path = src_dir.join("main.rs");
        let boundary =
            find_project_boundary(file_path.to_string_lossy().as_ref()).expect("boundary");

        assert_eq!(boundary.path, app_dir.to_string_lossy());
        assert_eq!(boundary.marker, "package.json");
    }
}

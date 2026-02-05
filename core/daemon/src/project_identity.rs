use std::path::{Path, PathBuf};

use crate::boundaries::find_project_boundary;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectIdentity {
    pub project_path: String,
    pub project_id: String,
}

#[derive(Debug, Clone)]
struct GitInfo {
    worktree_root: PathBuf,
    repo_root: PathBuf,
    common_dir: PathBuf,
    is_worktree: bool,
}

pub fn resolve_project_identity(path: &str) -> Option<ProjectIdentity> {
    let boundary = find_project_boundary(path)?;
    let boundary_path = PathBuf::from(&boundary.path);
    let git_info = resolve_git_info(&boundary_path);

    let canonical_boundary = git_info
        .as_ref()
        .map(|info| canonicalize_worktree_path(&boundary_path, info))
        .unwrap_or_else(|| boundary_path.clone());

    let project_id_path = git_info
        .as_ref()
        .map(|info| info.common_dir.clone())
        .unwrap_or_else(|| canonical_boundary.clone());

    Some(ProjectIdentity {
        project_path: path_to_string(&canonical_boundary),
        project_id: path_to_string(&project_id_path),
    })
}

pub fn workspace_id(project_id: &str, project_path: &str) -> String {
    let project_id = canonicalize_path(Path::new(project_id));
    let project_path = canonicalize_path(Path::new(project_path));
    let relative = workspace_relative_path(&project_id, &project_path);
    let source = format!("{}|{}", project_id.to_string_lossy(), relative);
    #[cfg(target_os = "macos")]
    let source = source.to_lowercase();
    format!("{:x}", md5::compute(source))
}

fn workspace_relative_path(project_id: &Path, project_path: &Path) -> String {
    let repo_root = repo_root_from_project_id(project_id);
    if let Some(repo_root) = repo_root {
        if let Ok(relative) = project_path.strip_prefix(&repo_root) {
            return relative.to_string_lossy().to_string();
        }
    }
    project_path.to_string_lossy().to_string()
}

fn repo_root_from_project_id(project_id: &Path) -> Option<PathBuf> {
    if project_id.file_name().and_then(|name| name.to_str()) == Some(".git") {
        return project_id.parent().map(|p| p.to_path_buf());
    }
    None
}

fn resolve_git_info(path: &Path) -> Option<GitInfo> {
    let start = if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent()?.to_path_buf()
    };

    let mut current = Some(start);
    while let Some(dir) = current {
        let git_entry = dir.join(".git");
        if git_entry.exists() {
            if git_entry.is_dir() {
                let repo_root = canonicalize_path(&dir);
                let common_dir = canonicalize_path(&git_entry);
                return Some(GitInfo {
                    worktree_root: repo_root.clone(),
                    repo_root,
                    common_dir,
                    is_worktree: false,
                });
            }

            let git_dir = parse_gitdir(&git_entry, &dir)?;
            if let Some(common_dir) = parse_commondir(&git_dir) {
                let repo_root = common_dir.parent().unwrap_or(&dir).to_path_buf();
                return Some(GitInfo {
                    worktree_root: canonicalize_path(&dir),
                    repo_root: canonicalize_path(&repo_root),
                    common_dir: canonicalize_path(&common_dir),
                    is_worktree: true,
                });
            }

            return Some(GitInfo {
                worktree_root: canonicalize_path(&dir),
                repo_root: canonicalize_path(&dir),
                common_dir: canonicalize_path(&git_dir),
                is_worktree: false,
            });
        }

        let parent = dir.parent().map(|p| p.to_path_buf());
        if parent.as_ref() == Some(&dir) {
            break;
        }
        current = parent;
    }

    None
}

fn parse_gitdir(git_file: &Path, worktree_root: &Path) -> Option<PathBuf> {
    let contents = std::fs::read_to_string(git_file).ok()?;
    let line = contents
        .lines()
        .find(|line| line.to_ascii_lowercase().starts_with("gitdir:"))?;
    let raw = line.get("gitdir:".len()..)?.trim();
    if raw.is_empty() {
        return None;
    }

    Some(resolve_git_path(worktree_root, raw))
}

fn parse_commondir(git_dir: &Path) -> Option<PathBuf> {
    let commondir_path = git_dir.join("commondir");
    if !commondir_path.exists() {
        return None;
    }
    let contents = std::fs::read_to_string(commondir_path).ok()?;
    let raw = contents.trim();
    if raw.is_empty() {
        return None;
    }
    Some(resolve_git_path(git_dir, raw))
}

fn resolve_git_path(base: &Path, raw: &str) -> PathBuf {
    let path = Path::new(raw);
    if path.is_absolute() {
        canonicalize_path(path)
    } else {
        canonicalize_path(&base.join(path))
    }
}

fn canonicalize_worktree_path(path: &Path, git_info: &GitInfo) -> PathBuf {
    if !git_info.is_worktree {
        return canonicalize_path(path);
    }

    let normalized_path = canonicalize_path(path);
    let worktree_root = canonicalize_path(&git_info.worktree_root);
    if let Ok(relative) = normalized_path.strip_prefix(&worktree_root) {
        return git_info.repo_root.join(relative);
    }
    normalized_path
}

fn canonicalize_path(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(target_os = "macos")]
    fn workspace_id_hashes_lowercased_paths_on_macos() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("RepoRoot");
        let repo_git = repo_root.join(".git");

        std::fs::create_dir_all(&repo_git).expect("create git dir");
        std::fs::write(repo_root.join("package.json"), "{}").expect("package marker");

        let identity =
            resolve_project_identity(repo_root.to_string_lossy().as_ref()).expect("repo identity");

        let workspace = workspace_id(&identity.project_id, &identity.project_path);

        let canonical_id = canonicalize_path(&repo_git).to_string_lossy().to_string();
        let source = format!("{}|", canonical_id);
        let expected = format!("{:x}", md5::compute(source.to_lowercase()));

        assert_eq!(workspace, expected);
    }

    #[test]
    fn workspace_id_is_stable_across_worktrees() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("assistant-ui");
        let repo_git = repo_root.join(".git");
        let docs_dir = repo_root.join("apps").join("docs");
        let src_dir = docs_dir.join("src");

        std::fs::create_dir_all(&src_dir).expect("create repo dirs");
        std::fs::create_dir_all(&repo_git).expect("create git dir");
        std::fs::write(docs_dir.join("package.json"), "{}").expect("package marker");
        std::fs::write(src_dir.join("index.ts"), "export {}").expect("file");

        let worktree_root = temp_dir.path().join("assistant-ui-wt");
        let worktree_docs = worktree_root.join("apps").join("docs");
        std::fs::create_dir_all(worktree_docs.join("src")).expect("create worktree dirs");
        std::fs::write(worktree_docs.join("package.json"), "{}").expect("package marker");
        std::fs::write(worktree_docs.join("src").join("index.ts"), "export {}").expect("file");

        let worktree_gitdir = repo_git.join("worktrees").join("feat-docs");
        std::fs::create_dir_all(&worktree_gitdir).expect("create gitdir");
        std::fs::write(worktree_gitdir.join("commondir"), "../..").expect("commondir");
        std::fs::write(
            worktree_root.join(".git"),
            format!("gitdir: {}\n", worktree_gitdir.to_string_lossy()),
        )
        .expect("git file");

        let repo_identity =
            resolve_project_identity(src_dir.join("index.ts").to_string_lossy().as_ref())
                .expect("repo identity");
        let worktree_identity = resolve_project_identity(
            worktree_docs
                .join("src")
                .join("index.ts")
                .to_string_lossy()
                .as_ref(),
        )
        .expect("worktree identity");

        assert_eq!(repo_identity.project_id, worktree_identity.project_id);
        assert_eq!(repo_identity.project_path, worktree_identity.project_path);

        let repo_workspace = workspace_id(&repo_identity.project_id, &repo_identity.project_path);
        let worktree_workspace = workspace_id(
            &worktree_identity.project_id,
            &worktree_identity.project_path,
        );

        assert_eq!(repo_workspace, worktree_workspace);
    }

    #[test]
    fn gitfile_without_commondir_is_not_treated_as_worktree() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("super-repo");
        let repo_gitdir = repo_root.join(".git").join("modules").join("submodule");
        let submodule_root = repo_root.join("submodule");
        let src_dir = submodule_root.join("src");

        std::fs::create_dir_all(&repo_gitdir).expect("create gitdir");
        std::fs::create_dir_all(&src_dir).expect("create submodule src dir");
        std::fs::write(submodule_root.join("package.json"), "{}").expect("package marker");
        std::fs::write(src_dir.join("index.ts"), "export {}").expect("file");
        std::fs::write(
            submodule_root.join(".git"),
            format!("gitdir: {}\n", repo_gitdir.to_string_lossy()),
        )
        .expect("git file");

        let identity =
            resolve_project_identity(src_dir.join("index.ts").to_string_lossy().as_ref())
                .expect("identity");

        let expected_root = canonicalize_path(&submodule_root)
            .to_string_lossy()
            .to_string();
        assert_eq!(identity.project_path, expected_root);
    }
}

use std::path::{Path, PathBuf};

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").expect("HOME not set"))
}

// _in variants take an explicit base (used in tests with tmpdir)
pub fn claude_json_in(base: &Path) -> PathBuf { base.join(".claude.json") }
pub fn claude_dir_in(base: &Path) -> PathBuf { base.join(".claude") }
pub fn profile_json_in(base: &Path, name: &str) -> PathBuf { base.join(format!(".claude.{}.json", name)) }
pub fn profile_dir_in(base: &Path, name: &str) -> PathBuf { base.join(format!(".claude.{}", name)) }
pub fn desktop_dir_in(base: &Path) -> PathBuf { base.join("Library/Application Support/Claude") }
pub fn desktop_profile_dir_in(base: &Path, name: &str) -> PathBuf { base.join(format!("Library/Application Support/Claude.{}", name)) }

// Production wrappers — always use real $HOME
pub fn claude_json() -> PathBuf { claude_json_in(&home()) }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_is_absolute() {
        assert!(home().is_absolute());
    }

    #[test]
    fn paths_in_are_relative_to_base() {
        let base = Path::new("/tmp/testbase");
        assert_eq!(claude_json_in(base), base.join(".claude.json"));
        assert_eq!(claude_dir_in(base), base.join(".claude"));
        assert_eq!(profile_json_in(base, "work"), base.join(".claude.work.json"));
        assert_eq!(profile_dir_in(base, "work"), base.join(".claude.work"));
        assert_eq!(desktop_dir_in(base), base.join("Library/Application Support/Claude"));
        assert_eq!(desktop_profile_dir_in(base, "work"), base.join("Library/Application Support/Claude.work"));
    }

    #[test]
    fn claude_json_uses_home() {
        assert_eq!(claude_json(), home().join(".claude.json"));
    }
}

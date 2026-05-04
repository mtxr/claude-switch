use std::path::PathBuf;

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").expect("HOME not set"))
}

pub fn claude_json() -> PathBuf {
    home().join(".claude.json")
}

pub fn claude_dir() -> PathBuf {
    home().join(".claude")
}

pub fn profile_json(name: &str) -> PathBuf {
    home().join(format!(".claude.{}.json", name))
}

pub fn profile_dir(name: &str) -> PathBuf {
    home().join(format!(".claude.{}", name))
}

pub fn desktop_dir() -> PathBuf {
    home().join("Library/Application Support/Claude")
}

pub fn desktop_profile_dir(name: &str) -> PathBuf {
    home().join(format!("Library/Application Support/Claude.{}", name))
}

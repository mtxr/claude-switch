use crate::{desktop, display, keychain, paths};
use anyhow::{anyhow, Result};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

const KEYCHAIN_CODE: &str = "Claude Code-credentials";
const KC_PROFILE_CODE: &str = "csw-code-";

// ── public API ────────────────────────────────────────────────────────────────

pub fn list() -> Vec<String> {
    list_in(&paths::home())
}

pub fn current() -> Option<String> {
    current_in(&paths::home())
}

pub fn profile_json_email(name: &str) -> Option<String> {
    profile_json_email_in(&paths::home(), name)
}

pub fn cmd_save(name: &str) -> Result<()> {
    let (c_token, c_acct) = match keychain::get(KEYCHAIN_CODE) {
        Ok(token) => {
            display::info("Reading Claude Code session...");
            let acct = keychain::get_account(KEYCHAIN_CODE);
            (Some(token), acct)
        }
        Err(_) => {
            display::info("Claude Code not available — skipping.");
            (None, String::new())
        }
    };
    migrate_to_profile_in(&paths::home(), name)?;
    if let Some(token) = c_token {
        keychain::set(&format!("{}{}", KC_PROFILE_CODE, name), &c_acct, &token)?;
    }
    display::ok(&format!("Profile '{}' saved", name));
    Ok(())
}

pub fn cmd_use(name: &str) -> Result<()> {
    let base = paths::home();
    let p_json = paths::profile_json_in(&base, name);
    if !p_json.exists() {
        return Err(anyhow!("Profile '{}' not found. Use: csw save {}", name, name));
    }
    let current = current_in(&base);
    if let Some(ref cur) = current {
        if cur != name {
            display::info(&format!("Auto-saving current profile '{}' before switching...", cur));
            cmd_save(cur)?;
        }
    }
    let c_token = keychain::get(&format!("{}{}", KC_PROFILE_CODE, name)).ok();
    let c_acct = keychain::get_account(&format!("{}{}", KC_PROFILE_CODE, name));
    desktop::quit();
    let has_desktop = desktop::has_data(name);
    if let Some(ref token) = c_token {
        display::info(&format!("Switching Claude Code → {}", name));
        keychain::set(KEYCHAIN_CODE, &c_acct, token)?;
    }
    switch_links_in(&base, name)?;
    desktop::swap(current.as_deref(), name)?;
    if has_desktop {
        desktop::launch();
    }
    display::ok(&format!("Switched to '{}'", name));
    Ok(())
}

pub fn cmd_new(name: &str) -> Result<()> {
    let base = paths::home();
    let p_json = paths::profile_json_in(&base, name);
    let p_dir = paths::profile_dir_in(&base, name);
    if p_json.exists() || p_dir.exists() {
        return Err(anyhow!("Profile '{}' files already exist. Use: csw use {}", name, name));
    }
    ensure_current_saved_in(&base)?;
    desktop::quit();
    std::fs::write(&p_json, "{}")?;
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&p_json, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::create_dir(&p_dir)?;
    keychain::delete(KEYCHAIN_CODE)?;
    let current_name = current_in(&base);
    switch_links_in(&base, name)?;
    desktop::swap(current_name.as_deref(), name)?;
    display::ok(&format!("Profile '{}' created and activated.", name));
    display::info(&format!(
        "Now run: `claude auth login` and/or login on Claude Desktop\n  When you are done, run: `csw save {}`\n",
        name
    ));
    Ok(())
}

pub fn cmd_delete(name: Option<&str>) -> Result<()> {
    let base = paths::home();
    let name = match name {
        Some(n) => n.to_string(),
        None => {
            let profiles = list_in(&base);
            if profiles.is_empty() {
                return Err(anyhow!("No profiles saved yet."));
            }
            fuzzy_pick(&profiles, "Delete profile > ")?
                .ok_or_else(|| anyhow!("No profile selected"))?
        }
    };
    let p_json = paths::profile_json_in(&base, &name);
    let p_dir = paths::profile_dir_in(&base, &name);
    let d_dir = paths::desktop_profile_dir_in(&base, &name);
    if !p_json.exists() && !p_dir.exists() {
        return Err(anyhow!("Profile '{}' not found", name));
    }
    let is_active = paths::claude_json_in(&base)
        .is_symlink()
        .then(|| paths::claude_json_in(&base).read_link().ok())
        .flatten()
        .map(|t| t == p_json)
        .unwrap_or(false);
    if is_active {
        desktop::quit();
        let _ = keychain::delete(KEYCHAIN_CODE);
        for link in &[paths::claude_json_in(&base), paths::claude_dir_in(&base), paths::desktop_dir_in(&base)] {
            if link.is_symlink() {
                let _ = std::fs::remove_file(link);
            }
        }
    }
    let _ = keychain::delete(&format!("{}{}", KC_PROFILE_CODE, name));
    if p_json.exists() { let _ = std::fs::remove_file(&p_json); }
    if p_dir.exists() { let _ = std::fs::remove_dir_all(&p_dir); }
    if d_dir.exists() { let _ = std::fs::remove_dir_all(&d_dir); }
    display::ok(&format!("Profile '{}' deleted", name));
    Ok(())
}

pub fn cmd_list() -> Result<()> {
    let base = paths::home();
    ensure_current_saved_in(&base)?;
    let profiles = list_in(&base);
    if profiles.is_empty() {
        println!("No profiles saved yet. Use: csw save <n>");
    } else {
        let active = current_in(&base);
        for p in &profiles {
            let marker = if Some(p.as_str()) == active.as_deref() { "  ◀" } else { "" };
            println!("  • {}{}", p, marker);
        }
    }
    Ok(())
}

pub fn cmd_pick() -> Result<()> {
    let profiles = list_in(&paths::home());
    if profiles.is_empty() {
        return Err(anyhow!("No profiles saved yet. Use: csw save <n>"));
    }
    if let Some(chosen) = fuzzy_pick(&profiles, "Pick profile > ")? {
        cmd_use(&chosen)?;
    }
    Ok(())
}

pub fn cmd_logout_all() -> Result<()> {
    let base = paths::home();
    display::info("Removing Claude Code keychain entry...");
    let _ = keychain::delete(KEYCHAIN_CODE);
    desktop::quit();
    for link in &[paths::claude_json_in(&base), paths::claude_dir_in(&base), paths::desktop_dir_in(&base)] {
        if link.is_symlink() {
            display::info(&format!("Removing symlink {}", link.display()));
            let _ = std::fs::remove_file(link);
        }
    }
    display::ok("Logged out of all accounts. Symlinks removed.");
    Ok(())
}

// ── internal helpers (pub(crate) for tests) ───────────────────────────────────

pub(crate) fn list_in(base: &Path) -> Vec<String> {
    let pattern = base.join(".claude.*.json");
    let mut profiles = Vec::new();
    if let Ok(entries) = glob::glob(&pattern.to_string_lossy()) {
        for path in entries.flatten() {
            if let Some(fname) = path.file_name().and_then(|n| n.to_str()) {
                if let Some(stem) = fname.strip_prefix(".claude.").and_then(|s| s.strip_suffix(".json")) {
                    if !stem.is_empty() {
                        profiles.push(stem.to_string());
                    }
                }
            }
        }
    }
    profiles.sort();
    profiles
}

pub(crate) fn current_in(base: &Path) -> Option<String> {
    let link = paths::claude_json_in(base);
    if !link.is_symlink() { return None; }
    let target = link.read_link().ok()?;
    // Target may be absolute or relative; extract file name
    let fname = target.file_name()?.to_str()?;
    let stem = fname.strip_prefix(".claude.")?.strip_suffix(".json")?;
    if stem.is_empty() { None } else { Some(stem.to_string()) }
}

pub(crate) fn profile_json_email_in(base: &Path, name: &str) -> Option<String> {
    let path = paths::profile_json_in(base, name);
    let text = std::fs::read_to_string(path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    json.get("oauthAccount")?.get("emailAddress")?.as_str().map(String::from)
}

pub(crate) fn switch_link_in(link: &Path, target: &Path, ensure_dir: bool) -> Result<()> {
    if !target.exists() {
        if ensure_dir {
            std::fs::create_dir_all(target)?;
        } else {
            return Ok(());
        }
    }
    if link.is_symlink() {
        std::fs::remove_file(link)?;
    } else if link.exists() {
        return Err(anyhow!(
            "{} exists and is not a symlink. Run 'csw save <name>' first to migrate.",
            link.display()
        ));
    }
    std::os::unix::fs::symlink(target, link)?;
    Ok(())
}

pub(crate) fn switch_links_in(base: &Path, name: &str) -> Result<()> {
    let p_json = paths::profile_json_in(base, name);
    let p_dir = paths::profile_dir_in(base, name);
    if !p_json.exists() {
        return Err(anyhow!("Profile config not found: {}\nRun: csw new {}", p_json.display(), name));
    }
    if !p_dir.exists() {
        return Err(anyhow!("Profile dir not found: {}\nRun: csw new {}", p_dir.display(), name));
    }
    switch_link_in(&paths::claude_json_in(base), &p_json, false)?;
    switch_link_in(&paths::claude_dir_in(base), &p_dir, true)?;
    Ok(())
}

pub(crate) fn migrate_to_profile_in(base: &Path, name: &str) -> Result<()> {
    let cj = paths::claude_json_in(base);
    let cd = paths::claude_dir_in(base);
    let p_json = paths::profile_json_in(base, name);
    let p_dir = paths::profile_dir_in(base, name);
    if !cj.is_symlink() && cj.exists() {
        display::info(&format!("Migrating ~/.claude.json → .claude.{}.json", name));
        std::fs::rename(&cj, &p_json)?;
        std::os::unix::fs::symlink(&p_json, &cj)?;
    }
    if !cd.is_symlink() && cd.exists() {
        display::info(&format!("Migrating ~/.claude/ → .claude.{}/", name));
        std::fs::rename(&cd, &p_dir)?;
        std::os::unix::fs::symlink(&p_dir, &cd)?;
    }
    desktop::migrate_in(base)?;
    Ok(())
}

fn ensure_current_saved_in(base: &Path) -> Result<()> {
    let cj = paths::claude_json_in(base);
    let cd = paths::claude_dir_in(base);
    if cj.is_symlink() { return Ok(()); }
    if !cj.exists() && !cd.exists() { return Ok(()); }
    println!("⚠️  Your current ~/.claude.json and ~/.claude/ are not managed by csw.");
    print!("Enter a name to save the current profile (or press Enter to skip): ");
    io::stdout().flush()?;
    let mut name = String::new();
    io::stdin().read_line(&mut name)?;
    let name = name.trim().to_string();
    if !name.is_empty() {
        cmd_save(&name)?;
    }
    Ok(())
}

fn fuzzy_cmd() -> Result<String> {
    for cmd in &["sk", "fzf"] {
        if Command::new("which")
            .arg(cmd)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
        {
            return Ok(cmd.to_string());
        }
    }
    Err(anyhow!("sk or fzf not found.\nInstall with: brew install sk"))
}

fn fuzzy_pick(items: &[String], prompt: &str) -> Result<Option<String>> {
    let cmd = fuzzy_cmd()?;
    let input = items.join("\n");
    let mut child = Command::new(&cmd)
        .args(["--prompt", prompt])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input.as_bytes());
    }
    let out = child.wait_with_output()?;
    let chosen = String::from_utf8_lossy(&out.stdout).trim().to_string();
    Ok(if chosen.is_empty() { None } else { Some(chosen) })
}

fn _symlink_target_path(link: &Path) -> Option<PathBuf> {
    link.read_link().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup() -> TempDir {
        tempfile::tempdir().unwrap()
    }

    fn create_profile(base: &Path, name: &str) {
        std::fs::write(paths::profile_json_in(base, name), "{}").unwrap();
        std::fs::create_dir_all(paths::profile_dir_in(base, name)).unwrap();
    }

    fn activate_profile(base: &Path, name: &str) {
        let p_json = paths::profile_json_in(base, name);
        let p_dir = paths::profile_dir_in(base, name);
        let cj = paths::claude_json_in(base);
        let cd = paths::claude_dir_in(base);
        if cj.is_symlink() { std::fs::remove_file(&cj).unwrap(); }
        if cd.is_symlink() { std::fs::remove_file(&cd).unwrap(); }
        std::os::unix::fs::symlink(&p_json, &cj).unwrap();
        std::os::unix::fs::symlink(&p_dir, &cd).unwrap();
    }

    // list_in

    #[test]
    fn list_empty_dir() {
        let tmp = setup();
        assert!(list_in(tmp.path()).is_empty());
    }

    #[test]
    fn list_finds_profiles() {
        let tmp = setup();
        std::fs::write(paths::profile_json_in(tmp.path(), "work"), "{}").unwrap();
        std::fs::write(paths::profile_json_in(tmp.path(), "personal"), "{}").unwrap();
        assert_eq!(list_in(tmp.path()), ["personal", "work"]);
    }

    #[test]
    fn list_sorted_alphabetically() {
        let tmp = setup();
        for name in &["zebra", "alpha", "middle"] {
            std::fs::write(paths::profile_json_in(tmp.path(), name), "{}").unwrap();
        }
        assert_eq!(list_in(tmp.path()), ["alpha", "middle", "zebra"]);
    }

    #[test]
    fn list_ignores_non_profile_json() {
        let tmp = setup();
        // This is a regular .json, not a profile
        std::fs::write(tmp.path().join("other.json"), "{}").unwrap();
        assert!(list_in(tmp.path()).is_empty());
    }

    // current_in

    #[test]
    fn current_none_when_no_symlink() {
        let tmp = setup();
        assert!(current_in(tmp.path()).is_none());
    }

    #[test]
    fn current_returns_active_profile() {
        let tmp = setup();
        create_profile(tmp.path(), "work");
        activate_profile(tmp.path(), "work");
        assert_eq!(current_in(tmp.path()).unwrap(), "work");
    }

    #[test]
    fn current_switches_when_symlink_changes() {
        let tmp = setup();
        create_profile(tmp.path(), "work");
        create_profile(tmp.path(), "personal");
        activate_profile(tmp.path(), "work");
        assert_eq!(current_in(tmp.path()).unwrap(), "work");
        activate_profile(tmp.path(), "personal");
        assert_eq!(current_in(tmp.path()).unwrap(), "personal");
    }

    // profile_json_email_in

    #[test]
    fn email_returns_none_when_missing() {
        let tmp = setup();
        assert!(profile_json_email_in(tmp.path(), "ghost").is_none());
    }

    #[test]
    fn email_parsed_from_json() {
        let tmp = setup();
        std::fs::write(
            paths::profile_json_in(tmp.path(), "work"),
            r#"{"oauthAccount":{"emailAddress":"me@work.com"}}"#,
        )
        .unwrap();
        assert_eq!(profile_json_email_in(tmp.path(), "work").unwrap(), "me@work.com");
    }

    #[test]
    fn email_returns_none_when_field_absent() {
        let tmp = setup();
        std::fs::write(paths::profile_json_in(tmp.path(), "work"), r#"{"other":{}}"#).unwrap();
        assert!(profile_json_email_in(tmp.path(), "work").is_none());
    }

    // switch_links_in

    #[test]
    fn switch_links_creates_symlinks() {
        let tmp = setup();
        create_profile(tmp.path(), "work");
        switch_links_in(tmp.path(), "work").unwrap();
        assert!(paths::claude_json_in(tmp.path()).is_symlink());
        assert!(paths::claude_dir_in(tmp.path()).is_symlink());
    }

    #[test]
    fn switch_links_updates_existing_symlinks() {
        let tmp = setup();
        create_profile(tmp.path(), "work");
        create_profile(tmp.path(), "personal");
        switch_links_in(tmp.path(), "work").unwrap();
        switch_links_in(tmp.path(), "personal").unwrap();
        assert_eq!(current_in(tmp.path()).unwrap(), "personal");
    }

    #[test]
    fn switch_links_errors_when_profile_missing() {
        let tmp = setup();
        assert!(switch_links_in(tmp.path(), "ghost").is_err());
    }

    // migrate_to_profile_in

    #[test]
    fn migrate_moves_unmanaged_json() {
        let tmp = setup();
        let cj = paths::claude_json_in(tmp.path());
        std::fs::write(&cj, r#"{"oauthAccount":{}}"#).unwrap();
        migrate_to_profile_in(tmp.path(), "work").unwrap();
        // Original file should now be a symlink
        assert!(cj.is_symlink());
        // Actual data moved to profile path
        assert!(paths::profile_json_in(tmp.path(), "work").exists());
    }

    #[test]
    fn migrate_moves_unmanaged_dir() {
        let tmp = setup();
        let cd = paths::claude_dir_in(tmp.path());
        std::fs::create_dir_all(&cd).unwrap();
        std::fs::write(cd.join("somefile"), b"data").unwrap();
        migrate_to_profile_in(tmp.path(), "work").unwrap();
        assert!(cd.is_symlink());
        assert!(paths::profile_dir_in(tmp.path(), "work").join("somefile").exists());
    }

    #[test]
    fn migrate_no_op_when_already_symlinked() {
        let tmp = setup();
        create_profile(tmp.path(), "work");
        activate_profile(tmp.path(), "work");
        // Should not error or change anything
        migrate_to_profile_in(tmp.path(), "work").unwrap();
        assert_eq!(current_in(tmp.path()).unwrap(), "work");
    }
}

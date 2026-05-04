use crate::{desktop, display, keychain, paths};
use anyhow::{anyhow, Result};
use std::io::{self, Write};
use std::path::Path;
use std::process::Command;

const KEYCHAIN_CODE: &str = "Claude Code-credentials";
const KC_PROFILE_CODE: &str = "csw-code-";

pub fn list() -> Vec<String> {
    let pattern = paths::home().join(".claude.*.json");
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

pub fn current() -> Option<String> {
    let link = paths::claude_json();
    if !link.is_symlink() {
        return None;
    }
    let target = link.read_link().ok()?;
    let fname = target.file_name()?.to_str()?;
    let stem = fname.strip_prefix(".claude.")?.strip_suffix(".json")?;
    if stem.is_empty() { None } else { Some(stem.to_string()) }
}

pub fn profile_json_email(name: &str) -> Option<String> {
    let path = paths::profile_json(name);
    let text = std::fs::read_to_string(path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    json.get("oauthAccount")?.get("emailAddress")?.as_str().map(String::from)
}

fn switch_link(link: &Path, target: &Path, ensure_dir: bool) -> Result<()> {
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

fn switch_links(name: &str) -> Result<()> {
    let p_json = paths::profile_json(name);
    let p_dir = paths::profile_dir(name);
    if !p_json.exists() {
        return Err(anyhow!(
            "Profile config not found: {}\nRun: csw new {}",
            p_json.display(),
            name
        ));
    }
    if !p_dir.exists() {
        return Err(anyhow!(
            "Profile dir not found: {}\nRun: csw new {}",
            p_dir.display(),
            name
        ));
    }
    switch_link(&paths::claude_json(), &p_json, false)?;
    switch_link(&paths::claude_dir(), &p_dir, true)?;
    Ok(())
}

fn migrate_to_profile(name: &str) -> Result<()> {
    let cj = paths::claude_json();
    let cd = paths::claude_dir();
    let p_json = paths::profile_json(name);
    let p_dir = paths::profile_dir(name);

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

    desktop::migrate()?;
    Ok(())
}

fn ensure_current_saved() -> Result<()> {
    let cj = paths::claude_json();
    let cd = paths::claude_dir();
    if cj.is_symlink() {
        return Ok(());
    }
    if !cj.exists() && !cd.exists() {
        return Ok(());
    }
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

    migrate_to_profile(name)?;

    if let Some(token) = c_token {
        keychain::set(&format!("{}{}", KC_PROFILE_CODE, name), &c_acct, &token)?;
    }

    display::ok(&format!("Profile '{}' saved", name));
    Ok(())
}

pub fn cmd_use(name: &str) -> Result<()> {
    let p_json = paths::profile_json(name);
    if !p_json.exists() {
        return Err(anyhow!("Profile '{}' not found. Use: csw save {}", name, name));
    }

    let current = current();
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

    switch_links(name)?;
    desktop::swap(current.as_deref(), name)?;

    if has_desktop {
        desktop::launch();
    }

    display::ok(&format!("Switched to '{}'", name));
    Ok(())
}

pub fn cmd_new(name: &str) -> Result<()> {
    let p_json = paths::profile_json(name);
    let p_dir = paths::profile_dir(name);

    if p_json.exists() || p_dir.exists() {
        return Err(anyhow!("Profile '{}' files already exist. Use: csw use {}", name, name));
    }

    ensure_current_saved()?;
    desktop::quit();

    std::fs::write(&p_json, "{}")?;
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&p_json, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::create_dir(&p_dir)?;

    keychain::delete(KEYCHAIN_CODE)?;

    let current_name = current();
    switch_links(name)?;
    desktop::swap(current_name.as_deref(), name)?;

    display::ok(&format!("Profile '{}' created and activated.", name));
    display::info(&format!(
        "Now run: `claude auth login` and/or login on Claude Desktop\n  When you are done, run: `csw save {}`\n",
        name
    ));
    Ok(())
}

pub fn cmd_delete(name: Option<&str>) -> Result<()> {
    let name = match name {
        Some(n) => n.to_string(),
        None => {
            let profiles = list();
            if profiles.is_empty() {
                return Err(anyhow!("No profiles saved yet."));
            }
            fuzzy_pick(&profiles, "Delete profile > ")?
                .ok_or_else(|| anyhow!("No profile selected"))?
        }
    };

    let p_json = paths::profile_json(&name);
    let p_dir = paths::profile_dir(&name);
    let d_dir = paths::desktop_profile_dir(&name);

    if !p_json.exists() && !p_dir.exists() {
        return Err(anyhow!("Profile '{}' not found", name));
    }

    // If this is the active profile, clean up active state
    let is_active = paths::claude_json()
        .is_symlink()
        .then(|| paths::claude_json().read_link().ok())
        .flatten()
        .map(|t| t == p_json)
        .unwrap_or(false);

    if is_active {
        desktop::quit();
        let _ = keychain::delete(KEYCHAIN_CODE);
        for link in &[paths::claude_json(), paths::claude_dir(), paths::desktop_dir()] {
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
    ensure_current_saved()?;
    let profiles = list();
    if profiles.is_empty() {
        println!("No profiles saved yet. Use: csw save <n>");
    } else {
        let active = current();
        for p in &profiles {
            let marker = if Some(p.as_str()) == active.as_deref() { "  ◀" } else { "" };
            println!("  • {}{}", p, marker);
        }
    }
    Ok(())
}

pub fn cmd_pick() -> Result<()> {
    let profiles = list();
    if profiles.is_empty() {
        return Err(anyhow!("No profiles saved yet. Use: csw save <n>"));
    }
    if let Some(chosen) = fuzzy_pick(&profiles, "Pick profile > ")? {
        cmd_use(&chosen)?;
    }
    Ok(())
}

pub fn cmd_logout_all() -> Result<()> {
    display::info("Removing Claude Code keychain entry...");
    let _ = keychain::delete(KEYCHAIN_CODE);

    desktop::quit();

    for link in &[paths::claude_json(), paths::claude_dir(), paths::desktop_dir()] {
        if link.is_symlink() {
            display::info(&format!("Removing symlink {}", link.display()));
            let _ = std::fs::remove_file(link);
        }
    }

    display::ok("Logged out of all accounts. Symlinks removed.");
    Ok(())
}

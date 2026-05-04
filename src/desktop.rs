use crate::{crypto, display, keychain, paths};
use anyhow::{anyhow, Result};
use std::process::Command;
use std::thread;
use std::time::Duration;

const KEYCHAIN_DESKTOP: &str = "Claude Safe Storage";

pub fn is_running() -> bool {
    Command::new("pgrep")
        .args(["-x", "Claude"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

pub fn quit() {
    if is_running() {
        display::info("Quitting Claude Desktop...");
        let _ = Command::new("pkill").args(["-9", "-x", "Claude"]).output();
        thread::sleep(Duration::from_secs(3));
    }
}

pub fn launch() {
    display::info("Reopening Claude Desktop...");
    let _ = Command::new("open").args(["-a", "Claude"]).output();
}

pub fn has_data(name: &str) -> bool {
    let d = paths::desktop_profile_dir(name);
    d.exists() && d.read_dir().map(|mut e| e.next().is_some()).unwrap_or(false)
}

/// Dissolve a legacy Desktop symlink back to a real directory.
pub fn migrate() -> Result<()> {
    let dd = paths::desktop_dir();
    if dd.is_symlink() {
        let real = dd.read_link()?;
        std::fs::remove_file(&dd)?;
        if real.exists() && !dd.exists() {
            std::fs::rename(&real, &dd)?;
        }
    }
    Ok(())
}

/// Swap Desktop dirs: rename Claude/ → Claude.<from>/ and Claude.<to>/ → Claude/
pub fn swap(current_name: Option<&str>, to_name: &str) -> Result<()> {
    let dd = paths::desktop_dir();
    let d_to = paths::desktop_profile_dir(to_name);

    // Save current Claude/ → Claude.<current>/
    if dd.is_symlink() {
        std::fs::remove_file(&dd)?;
    } else if dd.exists() {
        if let Some(cur) = current_name {
            let d_from = paths::desktop_profile_dir(cur);
            if d_from.exists() {
                std::fs::remove_dir_all(&d_from)?;
            }
            std::fs::rename(&dd, &d_from)?;
        }
    }

    // Activate Claude.<to>/ → Claude/
    if d_to.exists() {
        std::fs::rename(&d_to, &dd)?;
    } else {
        std::fs::create_dir_all(&dd)?;
    }

    Ok(())
}

pub fn get_session_key() -> Result<String> {
    let cookies_path = paths::desktop_dir().join("Cookies");
    if !cookies_path.exists() {
        return Err(anyhow!("Cookies DB not found: {}", cookies_path.display()));
    }

    let raw_key = keychain::get(KEYCHAIN_DESKTOP)
        .map_err(|_| anyhow!("Claude Safe Storage not found in Keychain. Is Claude Desktop installed?"))?;
    let key = crypto::derive_key(&raw_key);

    let conn = rusqlite::Connection::open_with_flags(
        &cookies_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;

    let encrypted: Vec<u8> = conn
        .query_row(
            "SELECT encrypted_value FROM cookies WHERE name='sessionKey'",
            [],
            |row| row.get(0),
        )
        .map_err(|_| anyhow!("Claude Desktop: sessionKey cookie not found"))?;

    let decrypted = crypto::decrypt_v10(&encrypted, &key)?;

    let idx = decrypted
        .find("sk-ant")
        .ok_or_else(|| anyhow!("Claude Desktop: could not find token in decrypted cookie"))?;

    Ok(decrypted[idx..].to_string())
}

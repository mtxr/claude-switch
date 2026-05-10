use crate::{crypto, display, keychain, paths};
use anyhow::{anyhow, Result};
use std::path::Path;
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
    has_data_in(&paths::home(), name)
}

pub fn swap(current_name: Option<&str>, to_name: &str) -> Result<()> {
    swap_in(&paths::home(), current_name, to_name)
}

pub fn get_session_key() -> Result<String> {
    let raw_key = keychain::get(KEYCHAIN_DESKTOP)
        .map_err(|_| anyhow!("Claude Safe Storage not found in Keychain. Is Claude Desktop installed?"))?;
    get_session_key_with_key_in(&paths::home(), &raw_key)
}

// _in variants accept a base path for testability

pub(crate) fn has_data_in(base: &Path, name: &str) -> bool {
    let d = paths::desktop_profile_dir_in(base, name);
    d.exists() && d.read_dir().map(|mut e| e.next().is_some()).unwrap_or(false)
}

pub(crate) fn migrate_in(base: &Path) -> Result<()> {
    let dd = paths::desktop_dir_in(base);
    if dd.is_symlink() {
        let real = dd.read_link()?;
        std::fs::remove_file(&dd)?;
        if real.exists() && !dd.exists() {
            std::fs::rename(&real, &dd)?;
        }
    }
    Ok(())
}

pub(crate) fn swap_in(base: &Path, current_name: Option<&str>, to_name: &str) -> Result<()> {
    let dd = paths::desktop_dir_in(base);
    let d_to = paths::desktop_profile_dir_in(base, to_name);

    if dd.is_symlink() {
        std::fs::remove_file(&dd)?;
    } else if dd.exists() {
        if let Some(cur) = current_name {
            let d_from = paths::desktop_profile_dir_in(base, cur);
            if d_from.exists() {
                std::fs::remove_dir_all(&d_from)?;
            }
            std::fs::rename(&dd, &d_from)?;
        }
    }

    if d_to.exists() {
        std::fs::rename(&d_to, &dd)?;
    } else {
        std::fs::create_dir_all(&dd)?;
    }

    Ok(())
}

pub(crate) fn get_session_key_with_key_in(base: &Path, raw_key: &str) -> Result<String> {
    let cookies_path = paths::desktop_dir_in(base).join("Cookies");
    if !cookies_path.exists() {
        return Err(anyhow!("Cookies DB not found: {}", cookies_path.display()));
    }

    let key = crypto::derive_key(raw_key);

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto;
    use aes::Aes128;
    use cbc::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
    use tempfile::TempDir;

    type Aes128CbcEnc = cbc::Encryptor<Aes128>;

    fn setup() -> TempDir {
        tempfile::tempdir().unwrap()
    }

    fn make_cookies_db(base: &Path, raw_key: &str, token: &str) {
        let claude_dir = paths::desktop_dir_in(base);
        std::fs::create_dir_all(&claude_dir).unwrap();
        let cookies_path = claude_dir.join("Cookies");

        let key = crypto::derive_key(raw_key);
        let iv = [b' '; 16];
        let mut buf = vec![0u8; token.len() + 16];
        let ct = Aes128CbcEnc::new(&key.into(), &iv.into())
            .encrypt_padded_b2b_mut::<Pkcs7>(token.as_bytes(), &mut buf)
            .unwrap();

        let mut encrypted = b"v10".to_vec();
        encrypted.extend_from_slice(ct);

        let conn = rusqlite::Connection::open(&cookies_path).unwrap();
        conn.execute_batch("CREATE TABLE cookies (name TEXT, encrypted_value BLOB)")
            .unwrap();
        conn.execute(
            "INSERT INTO cookies (name, encrypted_value) VALUES ('sessionKey', ?1)",
            [&encrypted],
        )
        .unwrap();
    }

    #[test]
    fn get_session_key_decrypts_cookie() {
        let tmp = setup();
        let raw_key = "test_storage_key";
        let token = "sk-ant-sid01-test-token-abc123";
        make_cookies_db(tmp.path(), raw_key, token);
        let result = get_session_key_with_key_in(tmp.path(), raw_key).unwrap();
        assert_eq!(result, token);
    }

    #[test]
    fn get_session_key_finds_sk_ant_within_noise() {
        let tmp = setup();
        let raw_key = "key";
        // Cookie contains noise before the actual token (realistic)
        let cookie_value = "\x00\x01noise\x00sk-ant-sid01-real-token";
        make_cookies_db(tmp.path(), raw_key, cookie_value);
        let result = get_session_key_with_key_in(tmp.path(), raw_key).unwrap();
        assert_eq!(result, "sk-ant-sid01-real-token");
    }

    #[test]
    fn get_session_key_errors_when_db_missing() {
        let tmp = setup();
        assert!(get_session_key_with_key_in(tmp.path(), "key").is_err());
    }

    #[test]
    fn get_session_key_errors_when_cookie_missing() {
        let tmp = setup();
        let claude_dir = paths::desktop_dir_in(tmp.path());
        std::fs::create_dir_all(&claude_dir).unwrap();
        let conn = rusqlite::Connection::open(claude_dir.join("Cookies")).unwrap();
        conn.execute_batch("CREATE TABLE cookies (name TEXT, encrypted_value BLOB)")
            .unwrap();
        assert!(get_session_key_with_key_in(tmp.path(), "key").is_err());
    }

    #[test]
    fn has_data_false_when_dir_missing() {
        let tmp = setup();
        assert!(!has_data_in(tmp.path(), "work"));
    }

    #[test]
    fn has_data_false_when_dir_empty() {
        let tmp = setup();
        std::fs::create_dir_all(paths::desktop_profile_dir_in(tmp.path(), "work")).unwrap();
        assert!(!has_data_in(tmp.path(), "work"));
    }

    #[test]
    fn has_data_true_when_dir_has_files() {
        let tmp = setup();
        let dir = paths::desktop_profile_dir_in(tmp.path(), "work");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("somefile"), b"data").unwrap();
        assert!(has_data_in(tmp.path(), "work"));
    }

    #[test]
    fn swap_moves_dirs_correctly() {
        let tmp = setup();
        let dd = paths::desktop_dir_in(tmp.path());
        let d_work = paths::desktop_profile_dir_in(tmp.path(), "work");
        let d_personal = paths::desktop_profile_dir_in(tmp.path(), "personal");

        std::fs::create_dir_all(&dd).unwrap();
        std::fs::write(dd.join("marker"), b"current").unwrap();
        std::fs::create_dir_all(&d_personal).unwrap();
        std::fs::write(d_personal.join("pfile"), b"personal").unwrap();

        swap_in(tmp.path(), Some("work"), "personal").unwrap();

        // Claude/ should now have personal's content
        assert!(dd.join("pfile").exists());
        // work's data should be saved to Claude.work/
        assert!(d_work.join("marker").exists());
    }

    #[test]
    fn swap_creates_dir_when_target_missing() {
        let tmp = setup();
        let dd = paths::desktop_dir_in(tmp.path());
        std::fs::create_dir_all(&dd).unwrap();

        swap_in(tmp.path(), Some("current"), "new-profile").unwrap();

        // Claude/ should exist (created fresh)
        assert!(dd.exists());
    }

    #[test]
    fn migrate_dissolves_symlink() {
        let tmp = setup();
        let real_dir = paths::desktop_profile_dir_in(tmp.path(), "work");
        std::fs::create_dir_all(&real_dir).unwrap();
        std::fs::write(real_dir.join("data"), b"x").unwrap();

        let dd = paths::desktop_dir_in(tmp.path());
        std::fs::create_dir_all(dd.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&real_dir, &dd).unwrap();

        migrate_in(tmp.path()).unwrap();

        // Symlink dissolved: data renamed from Claude.work/ into Claude/
        assert!(!dd.is_symlink());
        assert!(dd.is_dir());
        assert!(dd.join("data").exists());
    }
}

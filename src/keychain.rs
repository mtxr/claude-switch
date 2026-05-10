use anyhow::{anyhow, Result};
use std::process::Command;

pub fn get(service: &str) -> Result<String> {
    let out = Command::new("security")
        .args(["find-generic-password", "-s", service, "-w"])
        .output()?;
    if !out.status.success() {
        return Err(anyhow!("keychain entry not found: {}", service));
    }
    Ok(String::from_utf8(out.stdout)?.trim().to_string())
}

pub fn get_account(service: &str) -> String {
    let out = match Command::new("security")
        .args(["find-generic-password", "-s", service])
        .output()
    {
        Ok(o) => o,
        Err(_) => return "user".to_string(),
    };
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        if line.contains("\"acct\"") {
            // Line format: "acct"<blob>="value"
            let parts: Vec<&str> = line.split('"').collect();
            if parts.len() >= 4 {
                return parts[3].to_string();
            }
        }
    }
    "user".to_string()
}

pub fn set(service: &str, account: &str, value: &str) -> Result<()> {
    let _ = delete(service);
    let out = Command::new("security")
        .args(["add-generic-password", "-s", service, "-a", account, "-w", value])
        .output()?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(anyhow!("failed to write keychain entry '{}': {}", service, err.trim()));
    }
    Ok(())
}

pub fn delete(service: &str) -> Result<()> {
    Command::new("security")
        .args(["delete-generic-password", "-s", service])
        .output()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Unique service name per test run to avoid cross-run interference.
    fn svc(name: &str) -> String {
        format!("csw-test-{}-{}", std::process::id(), name)
    }

    fn cleanup(service: &str) {
        let _ = delete(service);
    }

    #[test]
    fn get_missing_returns_error() {
        let s = svc("missing");
        cleanup(&s);
        assert!(get(&s).is_err());
    }

    #[test]
    fn set_and_get_roundtrip() {
        let s = svc("roundtrip");
        cleanup(&s);
        set(&s, "testuser", "secret-value").unwrap();
        assert_eq!(get(&s).unwrap(), "secret-value");
        cleanup(&s);
    }

    #[test]
    fn set_overwrites_existing_entry() {
        let s = svc("overwrite");
        cleanup(&s);
        set(&s, "user", "first").unwrap();
        set(&s, "user", "second").unwrap();
        assert_eq!(get(&s).unwrap(), "second");
        cleanup(&s);
    }

    #[test]
    fn get_account_returns_stored_account() {
        let s = svc("account");
        cleanup(&s);
        set(&s, "hello@example.com", "value").unwrap();
        assert_eq!(get_account(&s), "hello@example.com");
        cleanup(&s);
    }

    #[test]
    fn get_account_returns_user_when_missing() {
        let s = svc("no-acct");
        cleanup(&s);
        assert_eq!(get_account(&s), "user");
    }

    #[test]
    fn delete_removes_entry() {
        let s = svc("delete");
        set(&s, "u", "v").unwrap();
        delete(&s).unwrap();
        assert!(get(&s).is_err());
    }

    #[test]
    fn delete_nonexistent_does_not_error() {
        let s = svc("delete-missing");
        cleanup(&s);
        assert!(delete(&s).is_ok());
    }
}

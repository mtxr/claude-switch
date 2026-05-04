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

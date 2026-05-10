mod crypto;
mod desktop;
mod display;
mod keychain;
mod paths;
mod profile;

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::process;

const KEYCHAIN_CODE: &str = "Claude Code-credentials";
const KC_PROFILE_CODE: &str = "csw-code-";
const GITHUB_REPO: &str = "mtxr/claude-switch";

#[derive(Parser)]
#[command(name = "csw", about = "Claude account switcher — swap Code + Desktop accounts on macOS")]
#[command(version = env!("CARGO_PKG_VERSION"))]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Save current sessions (Code + Desktop) as a named profile
    Save { name: String },
    /// Switch to a saved profile
    Use { name: String },
    /// Deprecated alias for 'use'
    #[command(hide = true)]
    Switch { name: String },
    /// Create a new empty profile slot (then: claude auth login)
    New { name: String },
    /// Delete a profile and its config files
    Delete { name: Option<String> },
    /// List all saved profiles
    List,
    /// Show active session info (Code + Desktop)
    Whoami,
    /// Interactive profile picker (sk / fzf)
    Pick,
    /// Update csw to the latest release
    Update,
    /// Log out of all accounts and remove active symlinks
    #[command(name = "logout-all")]
    LogoutAll,
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command.unwrap_or(Commands::Pick) {
        Commands::Save { name } => profile::cmd_save(&name),
        Commands::Use { name } => profile::cmd_use(&name),
        Commands::Switch { name } => {
            display::info("'switch' is deprecated, use 'use' instead");
            profile::cmd_use(&name)
        }
        Commands::New { name } => profile::cmd_new(&name),
        Commands::Delete { name } => profile::cmd_delete(name.as_deref()),
        Commands::List => profile::cmd_list(),
        Commands::Whoami => cmd_whoami(),
        Commands::Pick => profile::cmd_pick(),
        Commands::Update => cmd_update(),
        Commands::LogoutAll => profile::cmd_logout_all(),
    }
}

fn cmd_whoami() -> Result<()> {
    // Claude Code
    match keychain::get(KEYCHAIN_CODE) {
        Ok(token) => match serde_json::from_str::<serde_json::Value>(&token) {
            Ok(json) => print_code_session(json.get("claudeAiOauth").cloned().unwrap_or_default()),
            Err(_) => {
                display::section("Claude Code");
                display::row("Error", "failed to parse token");
            }
        },
        Err(_) => {
            display::section("Claude Code");
            display::row("Status", "no active session");
        }
    }

    // Claude Desktop
    match desktop::get_session_key() {
        Ok(token) => {
            display::section("Claude Desktop");
            display::row("Token type", "sessionKey (sk-ant-sid)");
            display::row("Token", &format!("{}...", &token[..token.len().min(15)]));
            display::row("Storage", "Electron cookie (AES encrypted)");
        }
        Err(_) => {
            display::section("Claude Desktop");
            display::row("Status", "not running or no session found");
        }
    }

    // Saved profiles
    let profiles = profile::list();
    if !profiles.is_empty() {
        let active = profile::current();
        display::section("Saved profiles");
        for p in &profiles {
            let marker = if Some(p.as_str()) == active.as_deref() { "  ◀  active" } else { "" };
            match keychain::get(&format!("{}{}", KC_PROFILE_CODE, p)) {
                Ok(token) => match serde_json::from_str::<serde_json::Value>(&token) {
                    Ok(json) => {
                        let oauth = json.get("claudeAiOauth").cloned().unwrap_or_default();
                        let email = profile::profile_json_email(p).unwrap_or_else(|| "?".to_string());
                        let sub = oauth.get("subscriptionType").and_then(|v| v.as_str()).unwrap_or("?");
                        let exp_ms = oauth.get("expiresAt").and_then(|v| v.as_i64()).unwrap_or(0);
                        let exp = display::fmt_expiry(exp_ms);
                        let email_short = &email[..email.len().min(30)];
                        println!("  • {:<12} {:<30} {:<10} {}{}", p, email_short, sub, exp, marker);
                    }
                    Err(_) => println!("  • {}{}", p, marker),
                },
                Err(_) => println!("  • {}{}", p, marker),
            }
        }
    }
    println!();
    Ok(())
}

fn print_code_session(oauth: serde_json::Value) {
    let acct = read_active_account_at(&paths::claude_json());
    let email = acct.get("emailAddress").and_then(|v| v.as_str()).unwrap_or("?");
    let org = acct.get("organizationName").and_then(|v| v.as_str()).unwrap_or("");

    display::section("Claude Code");
    if org.is_empty() {
        display::row("Account", email);
    } else {
        display::row("Account", &format!("{} ({})", email, org));
    }
    display::row("Plan", oauth.get("subscriptionType").and_then(|v| v.as_str()).unwrap_or("?"));
    display::row("Rate limit", oauth.get("rateLimitTier").and_then(|v| v.as_str()).unwrap_or("?"));
    let exp_ms = oauth.get("expiresAt").and_then(|v| v.as_i64()).unwrap_or(0);
    display::row("Expires", &display::fmt_expiry(exp_ms));
    let scopes = oauth.get("scopes").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    display::row("Scopes", &display::fmt_scopes(&scopes));
    let token = oauth.get("accessToken").and_then(|v| v.as_str()).unwrap_or("?");
    display::row("Token", &format!("{}...", &token[..token.len().min(15)]));
}

fn read_active_account_at(path: &std::path::Path) -> serde_json::Value {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.get("oauthAccount").cloned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup() -> TempDir {
        tempfile::tempdir().unwrap()
    }

    #[test]
    fn read_active_account_returns_empty_when_file_missing() {
        let tmp = setup();
        let result = read_active_account_at(&tmp.path().join(".claude.json"));
        assert_eq!(result, serde_json::Value::Null);
    }

    #[test]
    fn read_active_account_parses_email_and_org() {
        let tmp = setup();
        let path = tmp.path().join(".claude.json");
        std::fs::write(
            &path,
            r#"{"oauthAccount":{"emailAddress":"me@co.com","organizationName":"Acme"}}"#,
        )
        .unwrap();
        let acct = read_active_account_at(&path);
        assert_eq!(acct["emailAddress"], "me@co.com");
        assert_eq!(acct["organizationName"], "Acme");
    }

    #[test]
    fn read_active_account_returns_empty_on_invalid_json() {
        let tmp = setup();
        let path = tmp.path().join(".claude.json");
        std::fs::write(&path, b"not json").unwrap();
        assert_eq!(read_active_account_at(&path), serde_json::Value::Null);
    }

    #[test]
    fn read_active_account_returns_empty_when_field_absent() {
        let tmp = setup();
        let path = tmp.path().join(".claude.json");
        std::fs::write(&path, r#"{"other":"value"}"#).unwrap();
        assert_eq!(read_active_account_at(&path), serde_json::Value::Null);
    }

    #[test]
    fn oauth_token_preview_truncated_to_15() {
        // Verify the token display logic used in print_code_session
        let token = "sk-ant-oat01-ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        let preview = format!("{}...", &token[..token.len().min(15)]);
        assert_eq!(preview, "sk-ant-oat01-AB...");
        assert_eq!(preview.len(), 18); // 15 + 3
    }

    #[test]
    fn oauth_token_shorter_than_15_does_not_panic() {
        let token = "short";
        let preview = format!("{}...", &token[..token.len().min(15)]);
        assert_eq!(preview, "short...");
    }
}

fn cmd_update() -> Result<()> {
    let current = env!("CARGO_PKG_VERSION");

    display::info("Checking for updates...");
    let out = process::Command::new("curl")
        .args([
            "-s",
            "-H", "Accept: application/vnd.github+json",
            &format!("https://api.github.com/repos/{}/releases/latest", GITHUB_REPO),
        ])
        .output()?;

    if !out.status.success() {
        anyhow::bail!("failed to reach GitHub API");
    }

    let json: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_default();
    let latest = json["tag_name"]
        .as_str()
        .unwrap_or("")
        .trim_start_matches('v');

    if latest.is_empty() {
        anyhow::bail!("could not determine latest version — check https://github.com/{}/releases", GITHUB_REPO);
    }

    if latest == current {
        display::ok(&format!("Already up to date (v{})", current));
        return Ok(());
    }

    display::info(&format!("Update available: v{} → v{}", current, latest));

    let arch = if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" };
    let url = format!(
        "https://github.com/{}/releases/download/v{}/csw-{}-apple-darwin",
        GITHUB_REPO, latest, arch
    );

    let exe = std::env::current_exe()?;
    display::info(&format!("Downloading to {}...", exe.display()));

    let tmp = exe.with_extension("_update_tmp");
    let status = process::Command::new("curl")
        .args(["-L", "--fail", "-o", &tmp.to_string_lossy(), &url])
        .status()?;

    if !status.success() {
        anyhow::bail!("download failed — check your connection or visit https://github.com/{}/releases", GITHUB_REPO);
    }

    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
    std::fs::rename(&tmp, &exe)?;

    display::ok(&format!("Updated to v{}", latest));
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("❌  {}", e);
        process::exit(1);
    }
}

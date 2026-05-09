use chrono::{DateTime, Local, TimeZone, Utc};

pub fn info(msg: &str) {
    println!("➜   {}", msg);
}

pub fn ok(msg: &str) {
    println!("✅  {}", msg);
}

pub fn row(label: &str, value: &str) {
    println!("  {:<16} {}", label, value);
}

pub fn section(title: &str) {
    println!("\n  {}", title);
    println!("  {}", "─".repeat(title.chars().count() + 20));
}

pub fn fmt_expiry(expires_ms: i64) -> String {
    if expires_ms == 0 {
        return "?".to_string();
    }
    let expires_secs = expires_ms / 1000;
    let dt_utc = match Utc.timestamp_opt(expires_secs, 0).single() {
        Some(dt) => dt,
        None => return "?".to_string(),
    };
    let local: DateTime<Local> = dt_utc.with_timezone(&Local);
    let now_ms = Utc::now().timestamp_millis();
    let remaining_hours = (expires_ms - now_ms) / 1000 / 3600;
    let ts = local.format("%d %b %Y %H:%M %Z").to_string();
    if remaining_hours <= 0 {
        format!("{}  ⚠️  EXPIRED", ts)
    } else if remaining_hours < 24 {
        format!("{}  ({}h remaining)", ts, remaining_hours)
    } else {
        format!("{}  ({}d remaining)", ts, remaining_hours / 24)
    }
}

pub fn fmt_scopes(scopes: &[serde_json::Value]) -> String {
    let parts: Vec<&str> = scopes
        .iter()
        .filter_map(|s| s.as_str())
        .map(|s| s.trim_start_matches("user:"))
        .collect();
    if parts.is_empty() {
        "?".to_string()
    } else {
        parts.join(", ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use serde_json::json;

    #[test]
    fn fmt_expiry_zero_returns_question_mark() {
        assert_eq!(fmt_expiry(0), "?");
    }

    #[test]
    fn fmt_expiry_past_shows_expired() {
        // 1 hour ago
        let past_ms = (Utc::now().timestamp() - 3600) * 1000;
        assert!(fmt_expiry(past_ms).contains("EXPIRED"));
    }

    #[test]
    fn fmt_expiry_within_24h_shows_hours() {
        // 12 hours from now
        let soon_ms = (Utc::now().timestamp() + 12 * 3600) * 1000;
        let result = fmt_expiry(soon_ms);
        assert!(result.contains("h remaining"), "got: {}", result);
    }

    #[test]
    fn fmt_expiry_beyond_24h_shows_days() {
        // 3 days from now
        let future_ms = (Utc::now().timestamp() + 3 * 24 * 3600) * 1000;
        let result = fmt_expiry(future_ms);
        assert!(result.contains("d remaining"), "got: {}", result);
    }

    #[test]
    fn fmt_scopes_empty_returns_question_mark() {
        assert_eq!(fmt_scopes(&[]), "?");
    }

    #[test]
    fn fmt_scopes_strips_user_prefix() {
        let scopes = vec![json!("user:inference"), json!("user:profile")];
        assert_eq!(fmt_scopes(&scopes), "inference, profile");
    }

    #[test]
    fn fmt_scopes_no_prefix_left_unchanged() {
        let scopes = vec![json!("mcp_servers"), json!("file_upload")];
        assert_eq!(fmt_scopes(&scopes), "mcp_servers, file_upload");
    }

    #[test]
    fn fmt_scopes_ignores_non_string_values() {
        let scopes = vec![json!("user:inference"), json!(42), json!(null)];
        assert_eq!(fmt_scopes(&scopes), "inference");
    }
}

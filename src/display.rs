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

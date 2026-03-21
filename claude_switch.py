#!/usr/bin/env python3
# /// script
# dependencies = ["pycryptodome"]
# ///
"""
csw / claude-switch — swap Claude accounts (Code + Desktop) on macOS
"""

import hashlib
import json
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

PREF_CMD = "csw"

KEYCHAIN_CODE    = "Claude Code-credentials"
KEYCHAIN_DESKTOP = "Claude Safe Storage"
COOKIES_DB       = Path.home() / "Library/Application Support/Claude/Cookies"
CLAUDE_JSON      = Path.home() / ".claude.json"
CLAUDE_DIR       = Path.home() / ".claude"

# Profile tokens are stored in Keychain with these service prefixes
KC_PROFILE_CODE    = "csw-code-"      # + profile name
KC_PROFILE_DESKTOP = "csw-desktop-"   # + profile name

def die(msg):   print(f"❌  {msg}", file=sys.stderr); sys.exit(1)
def info(msg):  print(f"➜   {msg}")
def ok(msg):    print(f"✅  {msg}")

def _row(label, value, width=16):
    print(f"  {label:<{width}} {value}")

def _section(title):
    print(f"\n  {title}")
    print(f"  {'─' * (len(title) + 20)}")

def fuzzy_cmd():
    for cmd in ("sk", "fzf"):
        if shutil.which(cmd):
            return cmd
    die("sk or fzf not found.\nInstall with: brew install sk")

def fuzzy_pick(items, prompt="Pick profile > "):
    cmd = fuzzy_cmd()
    result = subprocess.run(
        [cmd, "--prompt", prompt],
        input="\n".join(items),
        stdout=subprocess.PIPE,
        text=True
    )
    return result.stdout.strip() or None

def keychain_get(service):
    r = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-w"],
        capture_output=True, text=True
    )
    return r.stdout.strip() if r.returncode == 0 else None

def keychain_get_acct(service):
    r = subprocess.run(
        ["security", "find-generic-password", "-s", service],
        capture_output=True, text=True
    )
    for line in r.stdout.splitlines():
        if '"acct"' in line:
            return line.split('"')[3]
    return "user"

def keychain_set(service, acct, value):
    keychain_delete(service)
    r = subprocess.run(
        ["security", "add-generic-password", "-s", service, "-a", acct, "-w", value],
        capture_output=True
    )
    if r.returncode != 0:
        die(f"Failed to write keychain entry: {service}")

def keychain_delete(service):
    subprocess.run(
        ["security", "delete-generic-password", "-s", service],
        capture_output=True
    )

def code_get():
    token = keychain_get(KEYCHAIN_CODE)
    if not token:
        die("Claude Code: no active session found. Run: claude auth login")
    return token

def code_acct():
    return keychain_get_acct(KEYCHAIN_CODE)

def code_set(token, acct):
    keychain_set(KEYCHAIN_CODE, acct, token)

def _derive_key():
    raw = keychain_get(KEYCHAIN_DESKTOP)
    if not raw:
        die("Claude Safe Storage not found in Keychain. Is Claude Desktop installed?")
    return hashlib.pbkdf2_hmac("sha1", raw.encode(), b"saltysalt", 1003, dklen=16)

def desktop_get():
    from Crypto.Cipher import AES

    if not COOKIES_DB.exists():
        die(f"Cookies DB not found: {COOKIES_DB}")

    key = _derive_key()
    conn = sqlite3.connect(str(COOKIES_DB))
    row = conn.execute(
        "SELECT encrypted_value FROM cookies WHERE name='sessionKey'"
    ).fetchone()
    conn.close()

    if not row:
        die("Claude Desktop: sessionKey cookie not found")

    enc = bytes(row[0])
    iv  = b" " * 16
    dec = AES.new(key, AES.MODE_CBC, IV=iv).decrypt(enc[3:])
    pad = dec[-1]
    dec = dec[:-pad].decode("latin-1")

    idx = dec.find("sk-ant")
    if idx == -1:
        die("Claude Desktop: could not find token in decrypted cookie")
    return dec[idx:]

def desktop_set(token):
    from Crypto.Cipher import AES

    key  = _derive_key()
    iv   = b" " * 16
    data = token.encode("utf-8")
    pad  = 16 - (len(data) % 16)
    data += bytes([pad] * pad)
    enc  = b"v10" + AES.new(key, AES.MODE_CBC, IV=iv).encrypt(data)

    conn = sqlite3.connect(str(COOKIES_DB))
    conn.execute(
        "UPDATE cookies SET encrypted_value=? WHERE name='sessionKey'", (enc,)
    )
    conn.commit()
    conn.close()

def desktop_running():
    r = subprocess.run(["pgrep", "-x", "Claude"], capture_output=True)
    return r.returncode == 0

def desktop_quit():
    if desktop_running():
        info("Quitting Claude Desktop...")
        subprocess.run(["osascript", "-e", 'quit app "Claude"'], capture_output=True)
        time.sleep(1)

def desktop_open():
    info("Reopening Claude Desktop...")
    subprocess.run(["open", "-a", "Claude"], capture_output=True)

def list_profiles():
    """Discover profiles from ~/.claude.{name}.json config files."""
    profiles = []
    for p in Path.home().glob(".claude.*.json"):
        stem = p.name[len(".claude."):-len(".json")]
        if stem:
            profiles.append(stem)
    return sorted(profiles)

def _profile_json(name):
    return Path.home() / f".claude.{name}.json"

def _profile_dir(name):
    return Path.home() / f".claude.{name}"

def _migrate_to_profile(name):
    """First-time setup: rename real ~/.claude.json and ~/.claude/ to profile-specific paths and symlink them."""
    p_json = _profile_json(name)
    p_dir  = _profile_dir(name)

    if not CLAUDE_JSON.is_symlink() and CLAUDE_JSON.exists():
        info(f"Migrating ~/.claude.json → .claude.{name}.json")
        CLAUDE_JSON.rename(p_json)
        CLAUDE_JSON.symlink_to(p_json)

    if not CLAUDE_DIR.is_symlink() and CLAUDE_DIR.exists():
        info(f"Migrating ~/.claude/ → .claude.{name}/")
        shutil.move(str(CLAUDE_DIR), str(p_dir))
        CLAUDE_DIR.symlink_to(p_dir)

def _switch_links(name):
    """Point ~/.claude.json and ~/.claude/ symlinks at the given profile."""
    p_json = _profile_json(name)
    p_dir  = _profile_dir(name)

    if not p_json.exists():
        die(f"Profile config not found: {p_json}\nRun: {PREF_CMD} new {name}")
    if not p_dir.exists():
        die(f"Profile dir not found: {p_dir}\nRun: {PREF_CMD} new {name}")

    for link, target in [(CLAUDE_JSON, p_json), (CLAUDE_DIR, p_dir)]:
        if link.is_symlink():
            link.unlink()
        elif link.exists():
            die(f"{link} exists and is not a symlink. Run '{PREF_CMD} save <name>' first to migrate.")
        link.symlink_to(target)

def _current_profile_name():
    """Return the name of the currently active profile, or None if not managed."""
    if CLAUDE_JSON.is_symlink():
        target = CLAUDE_JSON.resolve().name  # e.g. ".claude.work.json"
        if target.startswith(".claude.") and target.endswith(".json"):
            return target[len(".claude."):-len(".json")]
    return None

def _ensure_current_saved():
    """If the current state is not managed by claude-switch, prompt the user to save it first."""
    if CLAUDE_JSON.is_symlink():
        return  # already managed

    if not CLAUDE_JSON.exists() and not CLAUDE_DIR.exists():
        return  # nothing to save

    print(f"⚠️  Your current ~/.claude.json and ~/.claude/ are not managed by {PREF_CMD}.")
    save_name = input("Enter a name to save the current profile (or press Enter to skip): ").strip()
    if save_name:
        cmd_save(save_name)

def cmd_new(name):
    """Create a fresh profile slot and activate it (then run: claude auth login)."""
    p_json = _profile_json(name)
    p_dir  = _profile_dir(name)

    if p_json.exists() or p_dir.exists():
        die(f"Profile '{name}' files already exist. Use: {PREF_CMD} switch {name}")

    _ensure_current_saved()

    p_json.write_text("{}")
    p_json.chmod(0o600)
    p_dir.mkdir()

    keychain_delete(KEYCHAIN_CODE)

    _switch_links(name)
    ok(f"Profile '{name}' created and activated.")
    info(
f"""Now run: `claude auth login` and/or login on Claude Desktop
  When you are done, run: `csw save {name}`
""")

def cmd_save(name):
    c_token = c_acct = None
    try:
        info("Reading Claude Code session...")
        c_token = code_get()
        c_acct  = code_acct()
    except SystemExit:
        info("Claude Code not available — skipping.")

    _migrate_to_profile(name)

    d_token = None
    try:
        info("Reading Claude Desktop session...")
        d_token = desktop_get()
    except SystemExit:
        info("Claude Desktop not available — skipping.")

    if not c_token and not d_token:
        die("No active session found for Code or Desktop. Nothing to save.")

    if c_token:
        keychain_set(KC_PROFILE_CODE + name, c_acct, c_token)
    if d_token:
        keychain_set(KC_PROFILE_DESKTOP + name, "desktop", d_token)

    ok(f"Profile '{name}' saved (tokens stored in Keychain)")

def cmd_switch(name):
    p_json = _profile_json(name)
    if not p_json.exists():
        die(f"Profile '{name}' not found. Use: {PREF_CMD} save {name}")

    c_token = keychain_get(KC_PROFILE_CODE + name)
    c_acct  = keychain_get_acct(KC_PROFILE_CODE + name)
    d_token = keychain_get(KC_PROFILE_DESKTOP + name)

    if c_token:
        info(f"Switching Claude Code → {name}")
        code_set(c_token, c_acct)
    _switch_links(name)

    if d_token:
        info(f"Switching Claude Desktop → {name}")
        desktop_quit()
        desktop_set(d_token)
        desktop_open()

    ok(f"Switched to '{name}'")
    cmd_whoami()

def cmd_delete(name=None):
    if not name:
        profiles = list_profiles()
        if not profiles:
            die("No profiles saved yet.")
        name = fuzzy_pick(profiles, prompt="Delete profile > ")
        if not name:
            return

    p_json = _profile_json(name)
    p_dir  = _profile_dir(name)

    if not p_json.exists() and not p_dir.exists():
        die(f"Profile '{name}' not found")

    # If this profile is currently active, remove keychain + symlinks
    if CLAUDE_JSON.is_symlink() and CLAUDE_JSON.resolve() == p_json.resolve():
        keychain_delete(KEYCHAIN_CODE)
        for link in (CLAUDE_JSON, CLAUDE_DIR):
            if link.is_symlink():
                link.unlink()

    # Remove profile keychain entries
    keychain_delete(KC_PROFILE_CODE + name)
    keychain_delete(KC_PROFILE_DESKTOP + name)

    if p_json.exists():
        p_json.unlink()
    if p_dir.exists():
        shutil.rmtree(str(p_dir))

    ok(f"Profile '{name}' deleted")

def cmd_logout_all():
    info("Removing Claude Code keychain entry...")
    keychain_delete(KEYCHAIN_CODE)

    for link in (CLAUDE_JSON, CLAUDE_DIR):
        if link.is_symlink():
            info(f"Removing symlink {link}")
            link.unlink()

    info("Quitting Claude Desktop...")
    desktop_quit()

    ok("Logged out of all accounts. Symlinks removed.")

def cmd_list():
    _ensure_current_saved()
    profiles = list_profiles()
    if not profiles:
        print(f"No profiles saved yet. Use: {PREF_CMD} save <n>")
    else:
        active = _current_profile_name()
        for p in profiles:
            marker = "  ◀" if p == active else ""
            print(f"  • {p}{marker}")

def _fmt_expiry(expires_ms):
    if not expires_ms:
        return "?"
    dt        = datetime.fromtimestamp(expires_ms / 1000, tz=timezone.utc).astimezone()
    now_ms    = datetime.now(tz=timezone.utc).timestamp() * 1000
    remaining = int((expires_ms - now_ms) / 1000 / 3600)
    ts        = dt.strftime("%d %b %Y %H:%M %Z")
    if remaining <= 0:
        return f"{ts}  ⚠️  EXPIRED"
    if remaining < 24:
        return f"{ts}  ({remaining}h remaining)"
    return f"{ts}  ({remaining // 24}d remaining)"

def _fmt_scopes(scopes):
    return ", ".join(s.replace("user:", "") for s in scopes) or "?"

def _read_claude_json_account():
    """Read account info from the active ~/.claude.json (follows symlink)."""
    try:
        data = json.loads(CLAUDE_JSON.read_text())
        return data.get("oauthAccount", {})
    except Exception:
        return {}

def _print_code_session(oauth, label="Claude Code"):
    acct = _read_claude_json_account()
    email = acct.get("emailAddress", "?")
    org   = acct.get("organizationName", "")
    _section(label)
    _row("Account",    f"{email} ({org})" if org else email)
    _row("Plan",       oauth.get("subscriptionType", "?"))
    _row("Rate limit", oauth.get("rateLimitTier", "?"))
    _row("Expires",    _fmt_expiry(oauth.get("expiresAt")))
    _row("Scopes",     _fmt_scopes(oauth.get("scopes", [])))
    _row("Token",      oauth.get("accessToken", "?")[:15] + "...")

def _print_desktop_session(token, label="Claude Desktop"):
    _section(label)
    _row("Token type", "sessionKey (sk-ant-sid)")
    _row("Token",      token[:15] + "...")
    _row("Storage",    "Electron cookie (AES encrypted)")

def cmd_whoami():
    try:
        c_token = code_get()
        oauth = json.loads(c_token).get("claudeAiOauth", {})
        _print_code_session(oauth)
    except SystemExit:
        _section("Claude Code")
        _row("Status", "no active session")
    except Exception as e:
        _section("Claude Code")
        _row("Error",   str(e))

    try:
        d_token = desktop_get()
        _print_desktop_session(d_token)
    except SystemExit:
        _section("Claude Desktop")
        _row("Status", "not running or no session found")
    except Exception as e:
        _section("Claude Desktop")
        _row("Error", str(e))

    profiles = list_profiles()
    if profiles:
        active = _current_profile_name()
        _section("Saved profiles")
        for p in profiles:
            token = keychain_get(KC_PROFILE_CODE + p)
            marker = "  ◀  active" if p == active else ""
            try:
                td   = json.loads(token).get("claudeAiOauth", {})
                acct = json.loads(_profile_json(p).read_text()).get("oauthAccount", {})
                email = acct.get("emailAddress", "?")
                org   = acct.get("organizationName", "")
                who   = f"{email[:30]}" if org else email
                psub  = td.get("subscriptionType", "?")
                exp   = _fmt_expiry(td.get("expiresAt"))
                print(f"  • {p:<12} {who:<30} {psub:<10} {exp}{marker}")
            except Exception:
                print(f"  • {p}{marker}")
    print()

def cmd_update():
    repo = Path(__file__).parent
    r = subprocess.run(["git", "-C", str(repo), "pull", "--rebase"], text=True)
    if r.returncode != 0:
        die("Update failed. Check your git status.")

def cmd_pick():
    profiles = list_profiles()
    if not profiles:
        die(f"No profiles saved yet. Use: {PREF_CMD} save <n>")
    chosen = fuzzy_pick(profiles)
    if chosen:
        cmd_switch(chosen)

USAGE = f"""\
Usage: {PREF_CMD} <command> [profile]

Commands:
  save <n>    Save current sessions (Code + Desktop) as a profile
  switch <n>  Switch to a saved profile
  new <n>       Create a new empty profile slot (then: claude auth login)
  delete <n>    Delete a profile and its config files
  list          List all saved profiles
  whoami        Show active session info (Code + Desktop)
  pick          Interactive profile picker (sk / fzf)
  logout-all    Log out of all accounts and remove active symlinks
  update        Pull latest version from git
  help          Show this help

Examples:
  {PREF_CMD} save work
  {PREF_CMD} new personal   # then: claude auth login, {PREF_CMD} save personal
  {PREF_CMD} switch work
  {PREF_CMD} pick
"""

def main():
    args = sys.argv[1:]
    cmd  = args[0] if args else "pick"

    match cmd:
        case "save":
            if len(args) < 2: die(f"Usage: {PREF_CMD} save <n>")
            cmd_save(args[1])
        case "switch":
            if len(args) < 2: die(f"Usage: {PREF_CMD} switch <n>")
            cmd_switch(args[1])
        case "new":
            if len(args) < 2: die(f"Usage: {PREF_CMD} new <n>")
            cmd_new(args[1])
        case "delete":
            cmd_delete(args[1] if len(args) > 1 else None)
        case "list":
            cmd_list()
        case "whoami":
            cmd_whoami()
        case "pick":
            cmd_pick()
        case "update":
            cmd_update()
        case "logout-all":
            cmd_logout_all()
        case "help" | "--help" | "-h":
            print(USAGE)
        case _:
            die(f"Unknown command: {cmd}\nRun '{PREF_CMD} help'")

if __name__ == "__main__":
    main()

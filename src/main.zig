//! main.zig — entry point and argument parser

const std = @import("std");
const display = @import("display.zig");
const keychain = @import("keychain.zig");
const desktop = @import("desktop.zig");
const paths = @import("paths.zig");
const platform = @import("platform.zig");
const profile = @import("profile.zig");
const session = @import("session.zig");
const version = @import("version.zig");

comptime {
    _ = @import("crypto.zig");
    _ = @import("display.zig");
    _ = @import("keychain.zig");
    _ = @import("desktop.zig");
    _ = @import("paths.zig");
    _ = @import("platform.zig");
    _ = @import("profile.zig");
    _ = @import("session.zig");
    _ = @import("version.zig");
}

const KEYCHAIN_CODE = "Claude Code-credentials";
const KC_PROFILE_CODE = "csw-code-";
const GITHUB_REPO = "mtxr/claude-switch";
const VERSION = "0.2.6"; // x-release-please-version
const UPDATE_CACHE_FILE = "/tmp/csw-update-cache";
const UPDATE_CHECK_INTERVAL_S = 86400;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    var iter = init.minimal.args.iterate();
    _ = iter.next();
    while (iter.next()) |arg| {
        try args_list.append(gpa, arg);
    }
    const args = args_list.items;

    run(gpa, io, args) catch {
        std.process.exit(1);
    };
}

fn readUpdateCache(gpa: std.mem.Allocator, cache_path_z: [*:0]const u8) version.UpdateCache {
    const fd = std.c.open(cache_path_z, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return .{ .version = null, .checked = 0 };
    defer _ = std.c.close(fd);
    var buf: [256]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return .{ .version = null, .checked = 0 };
    return version.parseUpdateCache(gpa, buf[0..@intCast(n)]);
}

fn checkUpdateSilent(gpa: std.mem.Allocator, io: std.Io) void {
    const c_time = @cImport(@cInclude("time.h"));
    const now: i64 = c_time.time(null);

    const cache_path_z = gpa.dupeZ(u8, UPDATE_CACHE_FILE) catch return;
    defer gpa.free(cache_path_z);

    const cache = readUpdateCache(gpa, cache_path_z);
    defer if (cache.version) |v| gpa.free(v);

    if (cache.version) |latest| {
        if (version.isNewerVersion(latest, VERSION)) {
            const msg = std.fmt.allocPrint(gpa, "Update available: v{s} → v{s}  (run: csw update)", .{ VERSION, latest }) catch return;
            defer gpa.free(msg);
            display.info(msg);
        }
    }

    if (now - cache.checked < UPDATE_CHECK_INTERVAL_S) return;

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = platform.executablePath(&exe_buf) orelse return;

    _ = std.process.spawn(io, .{
        .argv = &.{ exe_path, "--check-update-bg" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
}

fn cmdCheckUpdateBg(gpa: std.mem.Allocator, io: std.Io) void {
    const c_time = @cImport(@cInclude("time.h"));
    const now: i64 = c_time.time(null);

    const cache_path_z = gpa.dupeZ(u8, UPDATE_CACHE_FILE) catch return;
    defer gpa.free(cache_path_z);

    const url = std.fmt.allocPrint(gpa, "https://api.github.com/repos/{s}/releases/latest", .{GITHUB_REPO}) catch return;
    defer gpa.free(url);

    const result = std.process.run(gpa, io, .{
        .argv = &.{ "curl", "-s", "--max-time", "10", "-H", "Accept: application/vnd.github+json", url },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256),
    }) catch return;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) return;

    const latest_owned = version.latestFromRelease(gpa, result.stdout) catch return;
    defer if (latest_owned) |l| gpa.free(l);
    const latest = latest_owned orelse VERSION;

    const json = version.formatUpdateCache(gpa, now, latest) catch return;
    defer gpa.free(json);
    const fd = std.c.open(cache_path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, json.ptr, json.len);
}

fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    const cmd = if (args.len > 0) args[0] else "";
    if (std.mem.eql(u8, cmd, "--check-update-bg")) {
        cmdCheckUpdateBg(gpa, io);
        return;
    }

    const skip_check = std.mem.eql(u8, cmd, "update") or
        std.mem.eql(u8, cmd, "--version") or
        std.mem.eql(u8, cmd, "-v");
    if (!skip_check) checkUpdateSilent(gpa, io);

    if (args.len == 0) return profile.cmdPick(gpa, io);

    const needsName = struct {
        fn check(a: []const []const u8, c: []const u8) ![]const u8 {
            if (a.len < 2) {
                display.print("❌  Usage: csw {s} <name>\n", .{c});
                return error.MissingArg;
            }
            return a[1];
        }
    }.check;

    if (std.mem.eql(u8, cmd, "save")) {
        return profile.cmdSave(gpa, io, try needsName(args, "save"));
    } else if (std.mem.eql(u8, cmd, "use")) {
        return profile.cmdUse(gpa, io, try needsName(args, "use"));
    } else if (std.mem.eql(u8, cmd, "switch")) {
        display.info("'switch' is deprecated, use 'use' instead");
        return profile.cmdUse(gpa, io, try needsName(args, "switch"));
    } else if (std.mem.eql(u8, cmd, "new")) {
        return profile.cmdNew(gpa, io, try needsName(args, "new"));
    } else if (std.mem.eql(u8, cmd, "delete")) {
        const name_opt: ?[]const u8 = if (args.len >= 2) args[1] else null;
        return profile.cmdDelete(gpa, io, name_opt);
    } else if (std.mem.eql(u8, cmd, "list")) {
        return profile.cmdList(gpa, io);
    } else if (std.mem.eql(u8, cmd, "whoami")) {
        return cmdWhoami(gpa, io);
    } else if (std.mem.eql(u8, cmd, "pick")) {
        return profile.cmdPick(gpa, io);
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        return cmdDoctor(gpa, io);
    } else if (std.mem.eql(u8, cmd, "update")) {
        const verbose = args.len >= 2 and std.mem.eql(u8, args[1], "--verbose");
        return cmdUpdate(gpa, io, verbose);
    } else if (std.mem.eql(u8, cmd, "logout-all")) {
        return profile.cmdLogoutAll(gpa, io);
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        display.print("csw {s}\n", .{VERSION});
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printHelp();
    } else {
        display.print("❌  Unknown command: {s}\n\n", .{cmd});
        printHelp();
        return error.UnknownCommand;
    }
}

fn printHelp() void {
    display.print(
        \\csw — Claude account switcher
        \\
        \\USAGE:
        \\  csw <command> [name]
        \\
        \\COMMANDS:
        \\  save <name>      Save current sessions as a named profile
        \\  use <name>       Switch to a saved profile
        \\  new <name>       Create a new empty profile slot
        \\  delete [name]    Delete a profile
        \\  list             List all saved profiles
        \\  whoami           Show active session info
        \\  pick             Interactive profile picker (sk / fzf)
        \\  update [--verbose]  Update csw to the latest release
        \\  logout-all       Log out and remove all active symlinks
        \\  doctor           Check that everything csw needs is in order
        \\
    , .{});
}

fn doctorOk(label: []const u8, detail: []const u8) void {
    display.print("\x1b[32m  [ok]  \x1b[0m {s:<32} {s}\n", .{ label, detail });
}
fn doctorWarn(label: []const u8, detail: []const u8) void {
    display.print("\x1b[33m  [warn]\x1b[0m {s:<32} {s}\n", .{ label, detail });
}
fn doctorFail(label: []const u8, detail: []const u8) void {
    display.print("\x1b[31m  [fail]\x1b[0m {s:<32} {s}\n", .{ label, detail });
}

fn doctorMacos(gpa: std.mem.Allocator, io: std.Io, h: []const u8, issues: *usize) !void {
    display.print("  Claude Desktop\n  ──────────────────────────────────\n", .{});

    const app_exists = desktop.pathExists(gpa, "/Applications/Claude.app");
    if (app_exists) {
        doctorOk("Claude.app", "/Applications/Claude.app");
    } else {
        doctorFail("Claude.app", "not found — install from https://claude.ai/download");
        issues.* += 1;
    }

    const running = desktop.isRunning(gpa, io);
    if (running) {
        doctorOk("Process", "running");
    } else {
        doctorWarn("Process", "not running");
    }

    display.print("\n  Keychain\n  ──────────────────────────────────\n", .{});

    if (keychain.get(gpa, io, "Claude Safe Storage")) |v| {
        gpa.free(v);
        doctorOk("Claude Safe Storage", "found");
    } else |_| {
        doctorFail("Claude Safe Storage", "missing — open Claude Desktop to create it");
        issues.* += 1;
    }

    if (keychain.get(gpa, io, KEYCHAIN_CODE)) |v| {
        gpa.free(v);
        doctorOk("Claude Code-credentials", "found");
    } else |_| {
        doctorWarn("Claude Code-credentials", "missing — run: claude auth login");
    }

    display.print("\n  Data\n  ──────────────────────────────────\n", .{});

    const desktop_dir = try paths.desktopDirIn(gpa, h);
    defer gpa.free(desktop_dir);
    if (desktop.pathExists(gpa, desktop_dir)) {
        doctorOk("Desktop data dir", "~/Library/Application Support/Claude/");
    } else {
        doctorFail("Desktop data dir", "missing — Claude Desktop has never run?");
        issues.* += 1;
    }

    const cookies_path = try std.fs.path.join(gpa, &.{ desktop_dir, "Cookies" });
    defer gpa.free(cookies_path);
    if (desktop.pathExists(gpa, cookies_path)) {
        doctorOk("Cookies DB", "found");
    } else {
        doctorFail("Cookies DB", "missing");
        issues.* += 1;
    }

    if (desktop.hasSessionKeyCookie(gpa, h)) {
        doctorOk("sessionKey cookie", "found (legacy token auth)");
    } else {
        doctorWarn("sessionKey cookie", "absent — Desktop likely uses OAuth now (save/use still work)");
    }
}

fn doctorLinux(gpa: std.mem.Allocator, io: std.Io) void {
    display.print("  Claude Code\n  ──────────────────────────────────\n", .{});
    if (keychain.get(gpa, io, KEYCHAIN_CODE)) |v| {
        gpa.free(v);
        doctorOk("Claude Code credentials", "found (~/.claude/.credentials.json)");
    } else |_| {
        doctorWarn("Claude Code credentials", "missing — run: claude auth login");
    }
    doctorWarn("Claude Desktop", "not supported on this OS");
}

fn cmdDoctor(gpa: std.mem.Allocator, io: std.Io) !void {
    display.print("\ncsw doctor\n\n", .{});
    var issues: usize = 0;

    const h = try paths.home(gpa);
    defer gpa.free(h);

    if (comptime platform.supports_desktop) {
        try doctorMacos(gpa, io, h, &issues);
    } else {
        doctorLinux(gpa, io);
    }

    display.print("\n  Profiles\n  ──────────────────────────────────\n", .{});

    const active = try profile.current(gpa);
    defer if (active) |a| gpa.free(a);
    if (active) |a| {
        doctorOk("Active profile", a);
    } else {
        doctorWarn("Active profile", "none — run: csw save <name>");
    }

    const profiles = try profile.list(gpa);
    defer {
        for (profiles) |p| gpa.free(p);
        gpa.free(profiles);
    }
    if (profiles.len > 0) {
        const list_str = try std.mem.join(gpa, ", ", profiles);
        defer gpa.free(list_str);
        doctorOk("Saved profiles", list_str);
    } else {
        doctorWarn("Saved profiles", "none");
    }

    display.print("\n  Tools\n  ──────────────────────────────────\n", .{});

    var found_picker = false;
    for (&[_][]const u8{ "sk", "fzf" }) |cmd| {
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "which", cmd },
            .stdout_limit = .limited(256),
            .stderr_limit = .limited(256),
        }) catch continue;
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) {
            doctorOk("Fuzzy picker", cmd);
            found_picker = true;
            break;
        }
    }
    if (!found_picker) {
        var hint_buf: [128]u8 = undefined;
        const hint = std.fmt.bufPrint(&hint_buf, "sk/fzf not found — install: {s}", .{platform.picker_install_hint}) catch "sk/fzf not found";
        doctorWarn("Fuzzy picker", hint);
    }

    display.print("\n", .{});
    if (issues == 0) {
        display.ok("All checks passed.");
    } else {
        const msg = try std.fmt.allocPrint(gpa, "{d} issue(s) found — see [fail] lines above.", .{issues});
        defer gpa.free(msg);
        display.err(msg);
        return error.DoctorFailed;
    }
}

fn cmdWhoami(gpa: std.mem.Allocator, io: std.Io) !void {
    if (keychain.get(gpa, io, KEYCHAIN_CODE)) |token| {
        defer gpa.free(token);
        if (std.json.parseFromSlice(std.json.Value, gpa, token, .{})) |parsed| {
            defer parsed.deinit();
            try printCodeSession(gpa, session.oauthFromCredentials(parsed.value));
        } else |_| {
            display.section("Claude Code");
            display.row("Error", "failed to parse token");
        }
    } else |_| {
        display.section("Claude Code");
        display.row("Status", "no active session");
    }

    if (comptime !platform.supports_desktop) {
        display.section("Claude Desktop");
        display.row("Status", "not supported on this OS");
    } else if (desktop.getSessionKey(gpa, io)) |token| {
        defer gpa.free(token);
        display.section("Claude Desktop");
        display.row("Token type", "sessionKey (sk-ant-sid)");
        display.row("Status", "sessionKey found");
        display.row("Storage", "Electron cookie (AES encrypted)");
    } else |_| {
        display.section("Claude Desktop");
        display.row("Status", "not running or no session found");
    }

    const profiles = try profile.list(gpa);
    defer {
        for (profiles) |p| gpa.free(p);
        gpa.free(profiles);
    }

    if (profiles.len > 0) {
        display.section("Saved profiles");

        const active = try profile.current(gpa);
        defer if (active) |a| gpa.free(a);

        for (profiles) |p| {
            const is_active = if (active) |a| std.mem.eql(u8, p, a) else false;
            const marker: []const u8 = if (is_active) "  ◀  active" else "";

            const svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KC_PROFILE_CODE, p });
            defer gpa.free(svc);

            if (keychain.get(gpa, io, svc)) |token| {
                defer gpa.free(token);
                if (std.json.parseFromSlice(std.json.Value, gpa, token, .{})) |parsed| {
                    defer parsed.deinit();
                    const oauth = session.oauthFromCredentials(parsed.value);

                    const email_raw = try profile.profileJsonEmail(gpa, p);
                    defer if (email_raw) |e| gpa.free(e);
                    const email = email_raw orelse "?";

                    const sub = session.oauthString(oauth, "subscriptionType");
                    const exp_str = try display.fmtExpiry(gpa, session.oauthInt(oauth, "expiresAt"));
                    defer gpa.free(exp_str);

                    const email_short = session.shortEmail(email);
                    display.print(
                        "  • {s:<12} {s:<30} {s:<10} {s}{s}\n",
                        .{ p, email_short, sub, exp_str, marker },
                    );
                } else |_| {
                    display.print("  • {s}{s}\n", .{ p, marker });
                }
            } else |_| {
                display.print("  • {s}{s}\n", .{ p, marker });
            }
        }
    }

    display.print("\n", .{});
}

fn printCodeSession(gpa: std.mem.Allocator, oauth: std.json.Value) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const cj = try paths.claudeJsonIn(gpa, h);
    defer gpa.free(cj);

    var account = session.Account{ .email = null, .organization = null };
    defer account.deinit(gpa);

    readProfileJson: {
        const cj_z = gpa.dupeZ(u8, cj) catch break :readProfileJson;
        defer gpa.free(cj_z);
        const fd = std.c.open(cj_z, .{}, @as(std.c.mode_t, 0));
        if (fd < 0) break :readProfileJson;
        defer _ = std.c.close(fd);
        var raw_buf: [1024 * 1024]u8 = undefined;
        const n = std.c.read(fd, &raw_buf, raw_buf.len);
        if (n <= 0) break :readProfileJson;
        account = session.parseAccount(gpa, raw_buf[0..@intCast(n)]) catch break :readProfileJson;
    }

    const email = account.email orelse "?";
    const org = account.organization orelse "";

    display.section("Claude Code");

    const acct_str = try session.accountLabel(gpa, email, org);
    defer gpa.free(acct_str);
    display.row("Account", acct_str);

    display.row("Plan", session.oauthString(oauth, "subscriptionType"));
    display.row("Rate limit", session.oauthString(oauth, "rateLimitTier"));

    const exp_str = try display.fmtExpiry(gpa, session.oauthInt(oauth, "expiresAt"));
    defer gpa.free(exp_str);
    display.row("Expires", exp_str);

    if (oauth == .object) {
        if (oauth.object.get("scopes")) |scopes_val| {
            if (scopes_val == .array) {
                const scopes_str = try display.fmtScopes(gpa, scopes_val.array.items);
                defer gpa.free(scopes_str);
                display.row("Scopes", scopes_str);
            }
        }
    }

    const token_preview = try session.tokenPreview(gpa, session.oauthString(oauth, "accessToken"));
    defer gpa.free(token_preview);
    display.row("Token", token_preview);
}

fn cmdUpdate(gpa: std.mem.Allocator, io: std.Io, verbose: bool) !void {
    display.info("Checking for updates...");

    const url = try std.fmt.allocPrint(
        gpa,
        "https://api.github.com/repos/{s}/releases/latest",
        .{GITHUB_REPO},
    );
    defer gpa.free(url);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "curl", "-s", "-H", "Accept: application/vnd.github+json", url },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) {
        display.err("failed to reach GitHub API");
        return error.NetworkError;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, result.stdout, .{}) catch {
        display.err("failed to parse GitHub response");
        return error.ParseError;
    };
    defer parsed.deinit();

    const tag = if (parsed.value == .object)
        if (parsed.value.object.get("tag_name")) |v| if (v == .string) v.string else "" else ""
    else
        "";

    const latest = version.trimTag(tag);
    if (latest.len == 0) {
        display.print(
            "❌  could not determine latest version — check https://github.com/{s}/releases\n",
            .{GITHUB_REPO},
        );
        return error.VersionUnknown;
    }

    if (std.mem.eql(u8, latest, VERSION)) {
        const msg = try std.fmt.allocPrint(gpa, "Already up to date (v{s})", .{VERSION});
        defer gpa.free(msg);
        display.ok(msg);
        return;
    }

    const update_msg = try std.fmt.allocPrint(gpa, "Update available: v{s} → v{s}", .{ VERSION, latest });
    defer gpa.free(update_msg);
    display.info(update_msg);

    var asset_buf: [64]u8 = undefined;
    const asset = platform.releaseAsset(&asset_buf) catch {
        platform.notSupported("csw update");
        return error.UnsupportedPlatform;
    };
    const dl_url = try std.fmt.allocPrint(
        gpa,
        "https://github.com/{s}/releases/download/v{s}/{s}",
        .{ GITHUB_REPO, latest, asset },
    );
    defer gpa.free(dl_url);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = platform.executablePath(&exe_buf) orelse {
        display.err("could not determine executable path");
        return error.ExePathFailed;
    };

    const dl_msg = try std.fmt.allocPrint(gpa, "Downloading to {s}...", .{exe_path});
    defer gpa.free(dl_msg);
    display.info(dl_msg);

    if (verbose) {
        const url_msg = try std.fmt.allocPrint(gpa, "URL: {s}", .{dl_url});
        defer gpa.free(url_msg);
        display.info(url_msg);
    }

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}_update_tmp", .{exe_path});
    defer gpa.free(tmp_path);

    const dl_result = try std.process.run(gpa, io, .{
        .argv = &.{ "curl", "-L", "--fail", "-o", tmp_path, dl_url },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(dl_result.stdout);
    defer gpa.free(dl_result.stderr);

    const dl_ok = switch (dl_result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!dl_ok) {
        display.print(
            "❌  download failed — check your connection or visit https://github.com/{s}/releases\n",
            .{GITHUB_REPO},
        );
        return error.DownloadFailed;
    }

    const tmp_path_z = try gpa.dupeZ(u8, tmp_path);
    defer gpa.free(tmp_path_z);
    const exe_path_z = try gpa.dupeZ(u8, exe_path);
    defer gpa.free(exe_path_z);
    _ = std.c.chmod(tmp_path_z, 0o755);
    if (std.c.rename(tmp_path_z, exe_path_z) != 0) return error.RenameFailed;

    const done_msg = try std.fmt.allocPrint(gpa, "Updated to v{s}", .{latest});
    defer gpa.free(done_msg);
    display.ok(done_msg);
}

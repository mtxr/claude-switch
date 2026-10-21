//! profile.zig — profile management

const std = @import("std");
const desktop = @import("desktop.zig");
const display = @import("display.zig");
const keychain = @import("keychain.zig");
const paths = @import("paths.zig");
const platform = @import("platform.zig");
const session = @import("session.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("unistd.h");
});

const KEYCHAIN_CODE = "Claude Code-credentials";
const KC_PROFILE_CODE = "csw-code-";


pub fn list(gpa: std.mem.Allocator) ![]const []const u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    return listIn(gpa, h);
}

pub fn current(gpa: std.mem.Allocator) !?[]const u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    return currentIn(gpa, h);
}

pub fn profileJsonEmail(gpa: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    return profileJsonEmailIn(gpa, h, name);
}

pub fn cmdSave(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    var c_token: ?[]const u8 = null;
    var c_acct: []const u8 = "";
    if (comptime platform.supports_keychain) {
        if (keychain.get(gpa, io, KEYCHAIN_CODE)) |token| {
            display.info("Reading Claude Code session...");
            c_token = token;
            c_acct = keychain.getAccount(gpa, io, KEYCHAIN_CODE);
        } else |_| {
            display.info("Claude Code not available — skipping.");
        }
    }
    defer if (c_token) |t| gpa.free(t);
    defer if (c_acct.len > 0) gpa.free(c_acct);

    try migrateToProfileIn(gpa, io, h, name);

    if (c_token) |token| {
        const svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KC_PROFILE_CODE, name });
        defer gpa.free(svc);
        try keychain.set(gpa, io, svc, c_acct, token);
    }

    const msg = try std.fmt.allocPrint(gpa, "Profile '{s}' saved", .{name});
    defer gpa.free(msg);
    display.ok(msg);
}

pub fn cmdUse(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const p_json = try paths.profileJsonIn(gpa, h, name);
    defer gpa.free(p_json);

    if (!desktop.pathExists(gpa, p_json)) {
        display.print("❌  Profile '{s}' not found. Use: csw save {s}\n", .{ name, name });
        return error.ProfileNotFound;
    }

    const cur = try currentIn(gpa, h);
    defer if (cur) |cur_owned| gpa.free(cur_owned);
    if (cur) |c_name| {
        if (!std.mem.eql(u8, c_name, name)) {
            const msg = try std.fmt.allocPrint(gpa, "Auto-saving current profile '{s}' before switching...", .{c_name});
            defer gpa.free(msg);
            display.info(msg);
            try cmdSave(gpa, io, c_name);
        }
    }

    const svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KC_PROFILE_CODE, name });
    defer gpa.free(svc);

    const c_token: ?[]const u8 = if (comptime platform.supports_keychain) keychain.get(gpa, io, svc) catch null else null;
    defer if (c_token) |t| gpa.free(t);
    const c_acct = keychain.getAccount(gpa, io, svc);
    defer gpa.free(c_acct);

    desktop.quit(gpa, io);
    const has_desktop = desktop.hasData(gpa, name);

    if (c_token) |token| {
        const msg = try std.fmt.allocPrint(gpa, "Switching Claude Code → {s}", .{name});
        defer gpa.free(msg);
        display.info(msg);
        try keychain.set(gpa, io, KEYCHAIN_CODE, c_acct, token);
    }

    try switchLinksIn(gpa, h, name);
    try desktop.swap(gpa, cur, name);
    if (has_desktop) desktop.launch(gpa, io);

    const msg = try std.fmt.allocPrint(gpa, "Switched to '{s}'", .{name});
    defer gpa.free(msg);
    display.ok(msg);
}

pub fn cmdNew(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const p_json = try paths.profileJsonIn(gpa, h, name);
    defer gpa.free(p_json);
    const p_dir = try paths.profileDirIn(gpa, h, name);
    defer gpa.free(p_dir);

    if (desktop.pathExists(gpa, p_json) or desktop.pathExists(gpa, p_dir)) {
        display.print("❌  Profile '{s}' files already exist. Use: csw use {s}\n", .{ name, name });
        return error.ProfileAlreadyExists;
    }

    try ensureCurrentSavedIn(gpa, io, h);
    desktop.quit(gpa, io);

    {
        const p_json_z = try gpa.dupeZ(u8, p_json);
        defer gpa.free(p_json_z);
        const fd = std.c.open(p_json_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.CreateFileFailed;
        _ = std.c.write(fd, "{}", 2);
        _ = std.c.close(fd);
    }

    try desktop.mkdirAllC(gpa, p_dir);
    keychain.delete(gpa, io, KEYCHAIN_CODE) catch {};

    const cur_name = try currentIn(gpa, h);
    defer if (cur_name) |cn| gpa.free(cn);

    try switchLinksIn(gpa, h, name);
    try desktop.swap(gpa, cur_name, name);

    const ok_msg = try std.fmt.allocPrint(gpa, "Profile '{s}' created and activated.", .{name});
    defer gpa.free(ok_msg);
    display.ok(ok_msg);
    const info_msg = try std.fmt.allocPrint(
        gpa,
        "Now run: `claude auth login` and/or login on Claude Desktop\n  When you are done, run: `csw save {s}`\n",
        .{name},
    );
    defer gpa.free(info_msg);
    display.info(info_msg);
}

pub fn cmdDelete(gpa: std.mem.Allocator, io: std.Io, name_opt: ?[]const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const name = if (name_opt) |n| try gpa.dupe(u8, n) else blk: {
        const profiles = try listIn(gpa, h);
        defer {
            for (profiles) |p| gpa.free(p);
            gpa.free(profiles);
        }
        if (profiles.len == 0) {
            display.err("No profiles saved yet.");
            return error.NoProfiles;
        }
        const chosen = try fuzzyPick(gpa, io, h, profiles, "Delete profile > ");
        break :blk chosen orelse {
            display.err("No profile selected");
            return error.NoneSelected;
        };
    };
    defer gpa.free(name);

    const p_json = try paths.profileJsonIn(gpa, h, name);
    defer gpa.free(p_json);
    const p_dir = try paths.profileDirIn(gpa, h, name);
    defer gpa.free(p_dir);
    const d_dir = try paths.desktopProfileDirIn(gpa, h, name);
    defer gpa.free(d_dir);

    if (!desktop.pathExists(gpa, p_json) and !desktop.pathExists(gpa, p_dir)) {
        display.print("❌  Profile '{s}' not found\n", .{name});
        return error.ProfileNotFound;
    }

    const cj = try paths.claudeJsonIn(gpa, h);
    defer gpa.free(cj);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const is_active = blk: {
        const n = desktop.readLinkC(gpa, cj, &link_buf) catch break :blk false;
        break :blk std.mem.eql(u8, link_buf[0..n], p_json);
    };

    if (is_active) {
        desktop.quit(gpa, io);
        keychain.delete(gpa, io, KEYCHAIN_CODE) catch {};
        const links = [_][]const u8{
            try paths.claudeJsonIn(gpa, h),
            try paths.claudeDirIn(gpa, h),
            try paths.desktopDirIn(gpa, h),
        };
        defer for (links) |l| gpa.free(l);
        for (links) |l| {
            if (desktop.isSymlink(gpa, l)) desktop.deletePathC(gpa, l);
        }
    }

    const svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KC_PROFILE_CODE, name });
    defer gpa.free(svc);
    keychain.delete(gpa, io, svc) catch {};

    if (desktop.pathExists(gpa, p_json)) desktop.deletePathC(gpa, p_json);
    if (desktop.pathExists(gpa, p_dir)) try deleteTreeC(gpa, io, p_dir);
    if (desktop.pathExists(gpa, d_dir)) try deleteTreeC(gpa, io, d_dir);

    const msg = try std.fmt.allocPrint(gpa, "Profile '{s}' deleted", .{name});
    defer gpa.free(msg);
    display.ok(msg);
}

pub fn cmdList(gpa: std.mem.Allocator, io: std.Io) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    try ensureCurrentSavedIn(gpa, io, h);

    const profiles = try listIn(gpa, h);
    defer {
        for (profiles) |p| gpa.free(p);
        gpa.free(profiles);
    }

    if (profiles.len == 0) {
        display.print("No profiles saved yet. Use: csw save <n>\n", .{});
        return;
    }

    const active = try currentIn(gpa, h);
    defer if (active) |a| gpa.free(a);

    for (profiles) |p| {
        const marker: []const u8 = if (active != null and std.mem.eql(u8, p, active.?)) "  ◀" else "";
        display.print("  • {s}{s}\n", .{ p, marker });
    }
}

pub fn cmdPick(gpa: std.mem.Allocator, io: std.Io) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const profiles = try listIn(gpa, h);
    defer {
        for (profiles) |p| gpa.free(p);
        gpa.free(profiles);
    }

    if (profiles.len == 0) {
        display.err("No profiles saved yet. Use: csw save <n>");
        return error.NoProfiles;
    }

    if (try fuzzyPick(gpa, io, h, profiles, "Pick profile > ")) |chosen| {
        defer gpa.free(chosen);
        try cmdUse(gpa, io, chosen);
    }
}

pub fn cmdLogoutAll(gpa: std.mem.Allocator, io: std.Io) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    if (comptime platform.supports_keychain) display.info("Removing Claude Code keychain entry...");
    keychain.delete(gpa, io, KEYCHAIN_CODE) catch {};
    desktop.quit(gpa, io);

    const links = [_][]const u8{
        try paths.claudeJsonIn(gpa, h),
        try paths.claudeDirIn(gpa, h),
        try paths.desktopDirIn(gpa, h),
    };
    defer for (links) |l| gpa.free(l);

    for (links) |l| {
        if (desktop.isSymlink(gpa, l)) {
            const msg = try std.fmt.allocPrint(gpa, "Removing symlink {s}", .{l});
            defer gpa.free(msg);
            display.info(msg);
            desktop.deletePathC(gpa, l);
        }
    }
    display.ok("Logged out of all accounts. Symlinks removed.");
}


pub fn listIn(gpa: std.mem.Allocator, base: []const u8) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |item| gpa.free(item);
        results.deinit(gpa);
    }

    const base_z = try gpa.dupeZ(u8, base);
    defer gpa.free(base_z);

    const dir_handle = c.opendir(base_z) orelse return results.toOwnedSlice(gpa);
    defer _ = c.closedir(dir_handle);

    while (c.readdir(dir_handle)) |entry| {
        const full = entry.*.d_name;
        const end = std.mem.indexOfScalar(u8, &full, 0) orelse full.len;
        const name = full[0..end];
        if (!std.mem.startsWith(u8, name, ".claude.")) continue;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const min_len = ".claude.".len + ".json".len;
        if (name.len <= min_len) continue;
        const stem = name[".claude.".len .. name.len - ".json".len];
        try results.append(gpa, try gpa.dupe(u8, stem));
    }

    const result = try results.toOwnedSlice(gpa);
    std.mem.sort([]const u8, result, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return result;
}

pub fn currentIn(gpa: std.mem.Allocator, base: []const u8) !?[]const u8 {
    const link = try paths.claudeJsonIn(gpa, base);
    defer gpa.free(link);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = desktop.readLinkC(gpa, link, &buf) catch return null;
    const target = buf[0..n];

    const fname = std.fs.path.basename(target);
    if (!std.mem.startsWith(u8, fname, ".claude.")) return null;
    if (!std.mem.endsWith(u8, fname, ".json")) return null;
    const stem = fname[".claude.".len .. fname.len - ".json".len];
    if (stem.len == 0) return null;
    return @as(?[]const u8, try gpa.dupe(u8, stem));
}

pub fn profileJsonEmailIn(gpa: std.mem.Allocator, base: []const u8, name: []const u8) !?[]const u8 {
    const path = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(path);

    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    const fd = std.c.open(path_z, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);

    var buf: [1024 * 1024]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const content = buf[0..@intCast(n)];

    return session.emailFromClaudeJson(gpa, content);
}

pub fn switchLinkIn(gpa: std.mem.Allocator, link: []const u8, target: []const u8, ensure_dir: bool) !void {
    if (!desktop.pathExists(gpa, target)) {
        if (ensure_dir) {
            try desktop.mkdirAllC(gpa, target);
        } else return;
    }

    if (desktop.isSymlink(gpa, link)) {
        desktop.deletePathC(gpa, link);
    } else if (desktop.pathExists(gpa, link)) {
        display.print("❌  {s} exists and is not a symlink. Run 'csw save <name>' first.\n", .{link});
        return error.NotASymlink;
    }

    const target_z = try gpa.dupeZ(u8, target);
    defer gpa.free(target_z);
    const link_z = try gpa.dupeZ(u8, link);
    defer gpa.free(link_z);
    if (std.c.symlink(target_z, link_z) != 0) return error.SymlinkFailed;
}

pub fn switchLinksIn(gpa: std.mem.Allocator, base: []const u8, name: []const u8) !void {
    const p_json = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(p_json);
    const p_dir = try paths.profileDirIn(gpa, base, name);
    defer gpa.free(p_dir);

    if (!desktop.pathExists(gpa, p_json)) {
        display.print("❌  Profile config not found: {s}\nRun: csw new {s}\n", .{ p_json, name });
        return error.ProfileNotFound;
    }
    if (!desktop.pathExists(gpa, p_dir)) {
        display.print("❌  Profile dir not found: {s}\nRun: csw new {s}\n", .{ p_dir, name });
        return error.ProfileNotFound;
    }

    const cj = try paths.claudeJsonIn(gpa, base);
    defer gpa.free(cj);
    const cd = try paths.claudeDirIn(gpa, base);
    defer gpa.free(cd);

    try switchLinkIn(gpa, cj, p_json, false);
    try switchLinkIn(gpa, cd, p_dir, true);
}

pub fn migrateToProfileIn(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8) !void {
    const cj = try paths.claudeJsonIn(gpa, base);
    defer gpa.free(cj);
    const cd = try paths.claudeDirIn(gpa, base);
    defer gpa.free(cd);
    const p_json = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(p_json);
    const p_dir = try paths.profileDirIn(gpa, base, name);
    defer gpa.free(p_dir);

    if (!desktop.isSymlink(gpa, cj) and desktop.pathExists(gpa, cj)) {
        const msg = try std.fmt.allocPrint(gpa, "Migrating ~/.claude.json → .claude.{s}.json", .{name});
        defer gpa.free(msg);
        display.info(msg);
        try desktop.renameC(gpa, cj, p_json);
        const pj_z = try gpa.dupeZ(u8, p_json);
        defer gpa.free(pj_z);
        const cj_z = try gpa.dupeZ(u8, cj);
        defer gpa.free(cj_z);
        if (std.c.symlink(pj_z, cj_z) != 0) return error.SymlinkFailed;
    }

    if (!desktop.isSymlink(gpa, cd) and desktop.pathExists(gpa, cd)) {
        const msg = try std.fmt.allocPrint(gpa, "Migrating ~/.claude/ → .claude.{s}/", .{name});
        defer gpa.free(msg);
        display.info(msg);
        try desktop.renameC(gpa, cd, p_dir);
        const pd_z = try gpa.dupeZ(u8, p_dir);
        defer gpa.free(pd_z);
        const cd_z = try gpa.dupeZ(u8, cd);
        defer gpa.free(cd_z);
        if (std.c.symlink(pd_z, cd_z) != 0) return error.SymlinkFailed;
    }

    try desktop.migrateIn(gpa, base);
    _ = io;
}

fn ensureCurrentSavedIn(gpa: std.mem.Allocator, io: std.Io, base: []const u8) !void {
    const cj = try paths.claudeJsonIn(gpa, base);
    defer gpa.free(cj);
    const cd = try paths.claudeDirIn(gpa, base);
    defer gpa.free(cd);

    if (desktop.isSymlink(gpa, cj)) return;
    if (!desktop.pathExists(gpa, cj) and !desktop.pathExists(gpa, cd)) return;

    display.print("⚠️  Your current ~/.claude.json and ~/.claude/ are not managed by csw.\n", .{});
    display.print("Enter a name to save the current profile (or press Enter to skip): ", .{});

    var name_buf: [256]u8 = undefined;
    var n: usize = 0;
    while (n < name_buf.len - 1) {
        const ch_n = std.c.read(std.posix.STDIN_FILENO, name_buf[n..n+1].ptr, 1);
        if (ch_n <= 0) break;
        if (name_buf[n] == '\n') break;
        n += 1;
    }
    const line = std.mem.trim(u8, name_buf[0..n], " \t\r");
    if (line.len > 0) try cmdSave(gpa, io, line);
}

/// Picker lines: aligned name + tab + email (if any). Caller frees.
pub fn pickerLinesIn(gpa: std.mem.Allocator, base: []const u8, profiles: []const []const u8) ![]const []const u8 {
    var width: usize = 0;
    for (profiles) |p| width = @max(width, p.len);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }

    for (profiles) |p| {
        const email = try profileJsonEmailIn(gpa, base, p);
        defer if (email) |e| gpa.free(e);
        const line = if (email) |e|
            try std.fmt.allocPrint(gpa, "{[name]s: <[w]}\t{[email]s}", .{ .name = p, .w = width, .email = e })
        else
            try gpa.dupe(u8, p);
        try lines.append(gpa, line);
    }
    return lines.toOwnedSlice(gpa);
}

/// Extracts the profile name from a line chosen in the picker.
pub fn pickerName(line: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
    return std.mem.trim(u8, line[0..end], " \t\n\r");
}

fn fuzzyPick(gpa: std.mem.Allocator, io: std.Io, base: []const u8, profiles: []const []const u8, prompt: []const u8) !?[]const u8 {
    const cmd = try fuzzyCmd(gpa, io);
    defer gpa.free(cmd);

    const items = try pickerLinesIn(gpa, base, profiles);
    defer {
        for (items) |l| gpa.free(l);
        gpa.free(items);
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ cmd, "--prompt", prompt },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    if (child.stdin) |stdin| {
        for (items) |item| {
            _ = std.c.write(stdin.handle, item.ptr, item.len);
            _ = std.c.write(stdin.handle, "\n", 1);
        }
        _ = std.c.close(stdin.handle);
        child.stdin = null;
    }

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |stdout| {
        while (total < buf.len) {
            const r = std.c.read(stdout.handle, buf[total..].ptr, buf.len - total);
            if (r <= 0) break;
            total += @intCast(r);
        }
        _ = std.c.close(stdout.handle);
        child.stdout = null;
    }

    _ = try child.wait(io);

    const chosen = pickerName(buf[0..total]);
    if (chosen.len == 0) return null;
    return try gpa.dupe(u8, chosen);
}

fn fuzzyCmd(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    for (&[_][]const u8{ "sk", "fzf" }) |cmd| {
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "which", cmd },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        }) catch continue;
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) return gpa.dupe(u8, cmd);
    }
    var hint_buf: [128]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, "sk or fzf not found. Install with: {s}", .{platform.picker_install_hint}) catch "sk or fzf not found.";
    display.err(hint);
    return error.FuzzyNotFound;
}

fn deleteTreeC(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "rm", "-rf", path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}


test "listIn empty dir" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);
    const result = try listIn(alloc, base);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "listIn finds profiles in sorted order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    for (&[_][]const u8{ "work", "personal" }) |name| {
        const p = try paths.profileJsonIn(alloc, base, name);
        defer alloc.free(p);
        const p_z = try alloc.dupeZ(u8, p);
        defer alloc.free(p_z);
        const fd = std.c.open(p_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) _ = std.c.close(fd);
    }

    const result = try listIn(alloc, base);
    defer {
        for (result) |p| alloc.free(p);
        alloc.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("personal", result[0]);
    try std.testing.expectEqualStrings("work", result[1]);
}

test "currentIn returns null without symlink" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);
    try std.testing.expectEqual(@as(?[]const u8, null), try currentIn(alloc, base));
}

test "currentIn returns the active profile" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    const p_json = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(p_json);
    const p_z = try alloc.dupeZ(u8, p_json);
    defer alloc.free(p_z);
    const fd = std.c.open(p_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) _ = std.c.close(fd);

    const cj = try paths.claudeJsonIn(alloc, base);
    defer alloc.free(cj);
    const cj_z = try alloc.dupeZ(u8, cj);
    defer alloc.free(cj_z);
    if (std.c.symlink(p_z, cj_z) != 0) return error.SymlinkFailed;

    const result = try currentIn(alloc, base);
    defer if (result) |r| alloc.free(r);
    try std.testing.expectEqualStrings("work", result.?);
}

test "emailIn parses email from JSON" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    const path = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(path);
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) {
        const content = "{\"oauthAccount\":{\"emailAddress\":\"me@work.com\"}}";
        _ = std.c.write(fd, content.ptr, content.len);
        _ = std.c.close(fd);
    }

    const result = try profileJsonEmailIn(alloc, base, "work");
    defer if (result) |r| alloc.free(r);
    try std.testing.expectEqualStrings("me@work.com", result.?);
}

test "pickerLinesIn aligns name and email" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    const p = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(p);
    const p_z = try alloc.dupeZ(u8, p);
    defer alloc.free(p_z);
    const fd = std.c.open(p_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const json = "{\"oauthAccount\":{\"emailAddress\":\"me@work.com\"}}";
    _ = std.c.write(fd, json.ptr, json.len);
    _ = std.c.close(fd);

    const lines = try pickerLinesIn(alloc, base, &.{ "personal", "work" });
    defer {
        for (lines) |l| alloc.free(l);
        alloc.free(lines);
    }
    try std.testing.expectEqualStrings("personal", lines[0]);
    try std.testing.expectEqualStrings("work    \tme@work.com", lines[1]);
}

test "pickerName extracts name from line" {
    try std.testing.expectEqualStrings("work", pickerName("work    \tme@work.com\n"));
    try std.testing.expectEqualStrings("personal", pickerName("personal\n"));
    try std.testing.expectEqualStrings("", pickerName("\n"));
}

const TestDir = struct {
    tmp: std.testing.TmpDir,
    base: []const u8,

    fn init(alloc: std.mem.Allocator) !TestDir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
        return .{ .tmp = tmp, .base = try alloc.dupe(u8, base_buf[0..base_len]) };
    }

    fn deinit(self: *TestDir, alloc: std.mem.Allocator) void {
        alloc.free(self.base);
        self.tmp.cleanup();
    }

    fn join(self: TestDir, alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fs.path.join(alloc, &.{ self.base, name });
    }

    fn write(self: TestDir, alloc: std.mem.Allocator, name: []const u8, content: []const u8) !void {
        const path = try self.join(alloc, name);
        defer alloc.free(path);
        const path_z = try alloc.dupeZ(u8, path);
        defer alloc.free(path_z);
        const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        _ = std.c.write(fd, content.ptr, content.len);
        _ = std.c.close(fd);
    }

    fn mkdir(self: TestDir, alloc: std.mem.Allocator, name: []const u8) !void {
        const path = try self.join(alloc, name);
        defer alloc.free(path);
        try desktop.mkdirAllC(alloc, path);
    }

    fn exists(self: TestDir, alloc: std.mem.Allocator, name: []const u8) !bool {
        const path = try self.join(alloc, name);
        defer alloc.free(path);
        return desktop.pathExists(alloc, path);
    }

    fn linkTarget(self: TestDir, alloc: std.mem.Allocator, name: []const u8, buf: []u8) !?[]const u8 {
        const path = try self.join(alloc, name);
        defer alloc.free(path);
        const n = desktop.readLinkC(alloc, path, buf) catch return null;
        return buf[0..n];
    }
};

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.heap.page_allocator, .{});
}

fn linkAndCurrent(alloc: std.mem.Allocator, td: TestDir, target: []const u8) !?[]const u8 {
    const link = try paths.claudeJsonIn(alloc, td.base);
    defer alloc.free(link);
    const link_z = try alloc.dupeZ(u8, link);
    defer alloc.free(link_z);
    const target_z = try alloc.dupeZ(u8, target);
    defer alloc.free(target_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target_z, link_z));
    return currentIn(alloc, td.base);
}

test "listIn ignores files that are not profiles" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    const noise = [_][]const u8{ ".claude.json", ".claude..json", "other.json", ".claude.work", ".claude.x.txt" };
    for (noise) |n| try td.write(alloc, n, "{}");
    try td.write(alloc, ".claude.ok.json", "{}");

    const result = try listIn(alloc, td.base);
    defer {
        for (result) |p| alloc.free(p);
        alloc.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("ok", result[0]);
}

test "listIn returns empty for a missing base" {
    const alloc = std.testing.allocator;
    const result = try listIn(alloc, "/nonexistent/csw-test-base");
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "currentIn ignores a symlink that does not point to a profile" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    try td.write(alloc, "random.txt", "x");
    const target = try td.join(alloc, "random.txt");
    defer alloc.free(target);
    try std.testing.expectEqual(@as(?[]const u8, null), try linkAndCurrent(alloc, td, target));
}

test "currentIn ignores a symlink with an empty profile name" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    try td.write(alloc, ".claude..json", "x");
    const target = try td.join(alloc, ".claude..json");
    defer alloc.free(target);
    try std.testing.expectEqual(@as(?[]const u8, null), try linkAndCurrent(alloc, td, target));
}

test "currentIn ignores a symlink with the right prefix and wrong suffix" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    try td.write(alloc, ".claude.work.txt", "x");
    const target = try td.join(alloc, ".claude.work.txt");
    defer alloc.free(target);
    try std.testing.expectEqual(@as(?[]const u8, null), try linkAndCurrent(alloc, td, target));
}

test "profileJsonEmailIn returns null for a missing, empty or invalid file" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);

    try std.testing.expectEqual(@as(?[]const u8, null), try profileJsonEmailIn(alloc, td.base, "none"));

    try td.write(alloc, ".claude.empty.json", "");
    try std.testing.expectEqual(@as(?[]const u8, null), try profileJsonEmailIn(alloc, td.base, "empty"));

    try td.write(alloc, ".claude.bad.json", "not json");
    try std.testing.expectEqual(@as(?[]const u8, null), try profileJsonEmailIn(alloc, td.base, "bad"));

    try td.write(alloc, ".claude.noemail.json", "{\"oauthAccount\":{}}");
    try std.testing.expectEqual(@as(?[]const u8, null), try profileJsonEmailIn(alloc, td.base, "noemail"));
}

test "switchLinkIn refuses to replace a real file" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    try td.write(alloc, "real", "x");
    try td.write(alloc, "target", "y");
    const link = try td.join(alloc, "real");
    defer alloc.free(link);
    const target = try td.join(alloc, "target");
    defer alloc.free(target);
    try std.testing.expectError(error.NotASymlink, switchLinkIn(alloc, link, target, false));
}

test "switchLinkIn skips a missing target without ensure_dir" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    const link = try td.join(alloc, "link");
    defer alloc.free(link);
    const target = try td.join(alloc, "missing");
    defer alloc.free(target);
    try switchLinkIn(alloc, link, target, false);
    try std.testing.expect(!try td.exists(alloc, "link"));
}

test "switchLinkIn creates the target with ensure_dir and swaps an existing symlink" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    const link = try td.join(alloc, "link");
    defer alloc.free(link);
    const first = try td.join(alloc, "first");
    defer alloc.free(first);
    const second = try td.join(alloc, "second");
    defer alloc.free(second);

    try switchLinkIn(alloc, link, first, true);
    try std.testing.expect(try td.exists(alloc, "first"));
    try switchLinkIn(alloc, link, second, true);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(second, (try td.linkTarget(alloc, "link", &buf)).?);
}

test "switchLinksIn fails without the profile json or dir" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    try std.testing.expectError(error.ProfileNotFound, switchLinksIn(alloc, td.base, "work"));
    try td.write(alloc, ".claude.work.json", "{}");
    try std.testing.expectError(error.ProfileNotFound, switchLinksIn(alloc, td.base, "work"));
}

test "switchLinksIn points json and dir at the profile" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    try td.write(alloc, ".claude.work.json", "{}");
    try td.mkdir(alloc, ".claude.work");
    try switchLinksIn(alloc, td.base, "work");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const json_target = (try td.linkTarget(alloc, ".claude.json", &buf)).?;
    try std.testing.expect(std.mem.endsWith(u8, json_target, ".claude.work.json"));
    const dir_target = (try td.linkTarget(alloc, ".claude", &buf)).?;
    try std.testing.expect(std.mem.endsWith(u8, dir_target, ".claude.work"));
}

test "migrateToProfileIn moves real files and leaves symlinks" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    var tio = testIo();
    defer tio.deinit();

    try td.write(alloc, ".claude.json", "{\"oauthAccount\":{\"emailAddress\":\"me@work.com\"}}");
    try td.mkdir(alloc, ".claude");
    try td.write(alloc, ".claude/.credentials.json", "{\"claudeAiOauth\":{}}");

    try migrateToProfileIn(alloc, tio.io(), td.base, "work");

    try std.testing.expect(try td.exists(alloc, ".claude.work.json"));
    try std.testing.expect(try td.exists(alloc, ".claude.work/.credentials.json"));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect((try td.linkTarget(alloc, ".claude.json", &buf)) != null);
    try std.testing.expect((try td.linkTarget(alloc, ".claude", &buf)) != null);

    const email = try profileJsonEmailIn(alloc, td.base, "work");
    defer if (email) |e| alloc.free(e);
    try std.testing.expectEqualStrings("me@work.com", email.?);
}

test "migrateToProfileIn is idempotent when symlinks already exist" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    var tio = testIo();
    defer tio.deinit();

    try td.write(alloc, ".claude.json", "{}");
    try td.mkdir(alloc, ".claude");
    try migrateToProfileIn(alloc, tio.io(), td.base, "work");
    try migrateToProfileIn(alloc, tio.io(), td.base, "work");

    const result = try listIn(alloc, td.base);
    defer {
        for (result) |p| alloc.free(p);
        alloc.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "migrateToProfileIn creates no profile when there is nothing to migrate" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    var tio = testIo();
    defer tio.deinit();
    try migrateToProfileIn(alloc, tio.io(), td.base, "work");
    try std.testing.expect(!try td.exists(alloc, ".claude.work.json"));
}

test "pickerLinesIn uses only the name when there is no email" {
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    const lines = try pickerLinesIn(alloc, td.base, &.{"solo"});
    defer {
        for (lines) |l| alloc.free(l);
        alloc.free(lines);
    }
    try std.testing.expectEqualStrings("solo", lines[0]);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const FlowHome = struct {
    previous: ?[]const u8,

    fn enter(alloc: std.mem.Allocator, base: []const u8) !FlowHome {
        const previous = if (std.c.getenv("HOME")) |v| try alloc.dupe(u8, std.mem.sliceTo(v, 0)) else null;
        const base_z = try alloc.dupeZ(u8, base);
        defer alloc.free(base_z);
        try std.testing.expectEqual(@as(c_int, 0), setenv("HOME", base_z, 1));
        return .{ .previous = previous };
    }

    fn leave(self: FlowHome, alloc: std.mem.Allocator) void {
        if (self.previous) |p| {
            const p_z = alloc.dupeZ(u8, p) catch return;
            defer alloc.free(p_z);
            _ = setenv("HOME", p_z, 1);
            alloc.free(p);
        }
    }
};

test "full command flow in a temporary HOME (without Desktop only)" {
    if (platform.supports_desktop) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    var tio = testIo();
    defer tio.deinit();
    const io = tio.io();

    const home_guard = try FlowHome.enter(alloc, td.base);
    defer home_guard.leave(alloc);

    try std.testing.expectError(error.NoProfiles, cmdPick(alloc, io));
    try std.testing.expectError(error.NoProfiles, cmdDelete(alloc, io, null));
    try cmdList(alloc, io);

    try td.write(alloc, ".claude.json", "{\"oauthAccount\":{\"emailAddress\":\"me@work.com\"}}");
    try td.mkdir(alloc, ".claude");
    try td.write(alloc, ".claude/.credentials.json", "{\"claudeAiOauth\":{\"subscriptionType\":\"max\"}}");

    try cmdSave(alloc, io, "work");
    {
        const active = try current(alloc);
        defer if (active) |a| alloc.free(a);
        try std.testing.expectEqualStrings("work", active.?);
    }

    try std.testing.expectError(error.ProfileAlreadyExists, cmdNew(alloc, io, "work"));
    try cmdNew(alloc, io, "personal");
    {
        const active = try current(alloc);
        defer if (active) |a| alloc.free(a);
        try std.testing.expectEqualStrings("personal", active.?);
    }
    try std.testing.expectError(error.KeychainNotFound, keychain.get(alloc, io, KEYCHAIN_CODE));

    try cmdUse(alloc, io, "work");
    {
        const active = try current(alloc);
        defer if (active) |a| alloc.free(a);
        try std.testing.expectEqualStrings("work", active.?);
    }
    const credentials = try keychain.get(alloc, io, KEYCHAIN_CODE);
    defer alloc.free(credentials);
    try std.testing.expect(std.mem.indexOf(u8, credentials, "max") != null);

    try std.testing.expectError(error.ProfileNotFound, cmdUse(alloc, io, "ghost"));
    try std.testing.expectError(error.ProfileNotFound, cmdDelete(alloc, io, "ghost"));

    const names = try list(alloc);
    defer {
        for (names) |p| alloc.free(p);
        alloc.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    const email = try profileJsonEmail(alloc, "work");
    defer if (email) |e| alloc.free(e);
    try std.testing.expectEqualStrings("me@work.com", email.?);

    try cmdList(alloc, io);

    try cmdDelete(alloc, io, "personal");
    try std.testing.expect(!try td.exists(alloc, ".claude.personal.json"));
    try std.testing.expect(!try td.exists(alloc, ".claude.personal"));

    try cmdDelete(alloc, io, "work");
    try std.testing.expect(!try td.exists(alloc, ".claude.work.json"));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), try td.linkTarget(alloc, ".claude.json", &buf));
}

test "logout-all removes active symlinks (without Desktop only)" {
    if (platform.supports_desktop) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var td = try TestDir.init(alloc);
    defer td.deinit(alloc);
    var tio = testIo();
    defer tio.deinit();
    const io = tio.io();

    const home_guard = try FlowHome.enter(alloc, td.base);
    defer home_guard.leave(alloc);

    try td.write(alloc, ".claude.json", "{}");
    try td.mkdir(alloc, ".claude");
    try cmdSave(alloc, io, "work");
    try cmdLogoutAll(alloc, io);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), try td.linkTarget(alloc, ".claude.json", &buf));
    try std.testing.expect(try td.exists(alloc, ".claude.work.json"));
}

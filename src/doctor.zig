//! doctor.zig — read-only health checks for profiles, bindings and the shell

const std = @import("std");
const bind = @import("bind.zig");
const credentials = @import("credentials.zig");
const desktop = @import("desktop.zig");
const keychain = @import("keychain.zig");
const paths = @import("paths.zig");
const platform = @import("platform.zig");
const testutil = @import("testutil.zig");
const run = @import("run.zig");

const c = @import("c");

pub const Level = enum { ok, warn };

pub const Finding = struct {
    level: Level,
    label: []const u8,
    detail: []u8,
};

pub const Report = struct {
    items: std.ArrayList(Finding) = .empty,

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        for (self.items.items) |item| gpa.free(item.detail);
        self.items.deinit(gpa);
    }

    pub fn add(self: *Report, gpa: std.mem.Allocator, level: Level, label: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const detail = try std.fmt.allocPrint(gpa, fmt, args);
        errdefer gpa.free(detail);
        try self.items.append(gpa, .{ .level = level, .label = label, .detail = detail });
    }
};

pub const ConfigDirKind = union(enum) {
    unset,
    profile: []const u8,
    missing_profile: []const u8,
    foreign_exists,
    foreign_missing,
};

fn profileComplete(gpa: std.mem.Allocator, base: []const u8, name: []const u8) bool {
    if (!bind.profileExistsIn(gpa, base, name)) return false;
    const dir = paths.profileDirIn(gpa, base, name) catch return false;
    defer gpa.free(dir);
    return desktop.pathExists(gpa, dir);
}

/// What a CLAUDE_CONFIG_DIR value points at, relative to the csw profile dirs under `base`.
pub fn classifyConfigDirIn(gpa: std.mem.Allocator, base: []const u8, current: ?[]const u8) ConfigDirKind {
    const dir = current orelse return .unset;
    const parent = std.fs.path.dirname(dir);
    if (parent != null and std.mem.eql(u8, parent.?, base)) {
        if (run.profileNameOfDir(dir)) |name| {
            return if (profileComplete(gpa, base, name)) .{ .profile = name } else .{ .missing_profile = name };
        }
    }
    return if (desktop.pathExists(gpa, dir)) .foreign_exists else .foreign_missing;
}

/// Adds one ok finding when `names` is empty, otherwise one warning listing them.
pub fn namesFinding(gpa: std.mem.Allocator, report: *Report, label: []const u8, ok_detail: []const u8, warn_prefix: []const u8, names: []const []const u8) !void {
    if (names.len == 0) return report.add(gpa, .ok, label, "{s}", .{ok_detail});
    const joined = try std.mem.join(gpa, ", ", names);
    defer gpa.free(joined);
    try report.add(gpa, .warn, label, "{s}: {s}", .{ warn_prefix, joined });
}

pub fn overlapFinding(gpa: std.mem.Allocator, report: *Report, name: []const u8, identical: ?bool) !void {
    const same = identical orelse return;
    if (same) {
        try report.add(gpa, .warn, "Login in two places", "'{s}' is stored in the default entry and the per-directory entry (identical copies); using it with and without the hook at the same time can invalidate one refresh token", .{name});
    } else {
        try report.add(gpa, .warn, "Login in two places", "'{s}' is stored in the default entry and the per-directory entry, and the copies have diverged; one may hold an outdated refresh token (run: csw save {s} after logging in)", .{ name, name });
    }
}

fn orphanDirsIn(gpa: std.mem.Allocator, base: []const u8, profiles: []const []const u8) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |item| gpa.free(item);
        results.deinit(gpa);
    }

    const base_z = try gpa.dupeSentinel(u8, base, 0);
    defer gpa.free(base_z);
    const handle = c.opendir(base_z) orelse return results.toOwnedSlice(gpa);
    defer _ = c.closedir(handle);

    const prefix = ".claude.";
    while (c.readdir(handle)) |entry| {
        const full = entry.*.d_name;
        const end = std.mem.indexOfScalar(u8, &full, 0) orelse full.len;
        const name = full[0..end];
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) continue;
        if (std.mem.endsWith(u8, name, ".json")) continue;
        const stem = name[prefix.len..];
        if (std.mem.eql(u8, stem, "json") or std.mem.startsWith(u8, stem, "json.")) continue;
        if (containsName(profiles, stem)) continue;
        if (!isDirectory(gpa, base, name)) continue;
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

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn isDirectory(gpa: std.mem.Allocator, base: []const u8, name: []const u8) bool {
    const full = std.fs.path.join(gpa, &.{ base, name }) catch return false;
    defer gpa.free(full);
    const full_z = gpa.dupeSentinel(u8, full, 0) catch return false;
    defer gpa.free(full_z);
    const handle = c.opendir(full_z) orelse return false;
    _ = c.closedir(handle);
    return true;
}

/// Profile files on disk: directories, orphan directories and inner config links.
pub fn fileFindingsIn(gpa: std.mem.Allocator, base: []const u8, profiles: []const []const u8, report: *Report) !void {
    var no_dir: std.ArrayList([]const u8) = .empty;
    defer no_dir.deinit(gpa);
    var stale_inner: std.ArrayList([]const u8) = .empty;
    defer stale_inner.deinit(gpa);

    for (profiles) |name| {
        const dir = try paths.profileDirIn(gpa, base, name);
        defer gpa.free(dir);
        if (!desktop.pathExists(gpa, dir)) {
            try no_dir.append(gpa, name);
            continue;
        }
        const inner = try std.fs.path.join(gpa, &.{ dir, ".claude.json" });
        defer gpa.free(inner);
        if (desktop.pathExists(gpa, inner) and !desktop.isSymlink(gpa, inner)) try stale_inner.append(gpa, name);
    }

    const orphans = try orphanDirsIn(gpa, base, profiles);
    defer {
        for (orphans) |o| gpa.free(o);
        gpa.free(orphans);
    }

    try namesFinding(gpa, report, "Profile directories", "every profile has its directory", "profile json without a directory (run: csw use <name>)", no_dir.items);
    try namesFinding(gpa, report, "Orphan directories", "none", "~/.claude.<name>/ without ~/.claude.<name>.json", orphans);
    try namesFinding(gpa, report, "Inner .claude.json", "linked to the profile json", "regular file instead of a link, so csw will not see its updates", stale_inner.items);
}

pub fn loginFindingsFrom(gpa: std.mem.Allocator, report: *Report, profiles: []const []const u8, has_login: []const bool, has_legacy: []const bool) !void {
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);
    var legacy: std.ArrayList([]const u8) = .empty;
    defer legacy.deinit(gpa);
    for (profiles, 0..) |name, i| {
        if (!has_login[i]) try missing.append(gpa, name);
        if (has_legacy[i]) try legacy.append(gpa, name);
    }
    try namesFinding(gpa, report, "Stored logins", "every profile has a login", "no stored login (run: csw use <name>, log in, then csw save <name>)", missing.items);
    if (comptime platform.supports_keychain) {
        try namesFinding(gpa, report, "Legacy entries", "none", "old csw-code entries, converted on the next use or save", legacy.items);
    }
}

/// Which profiles have a stored login and which still carry a legacy Keychain entry.
pub fn loginFindings(gpa: std.mem.Allocator, io: std.Io, base: []const u8, profiles: []const []const u8, report: *Report) !void {
    const has_login = try gpa.alloc(bool, profiles.len);
    defer gpa.free(has_login);
    const has_legacy = try gpa.alloc(bool, profiles.len);
    defer gpa.free(has_legacy);
    for (profiles, 0..) |name, i| {
        has_login[i] = credentials.hasLogin(gpa, io, base, name);
        has_legacy[i] = credentials.hasLegacy(gpa, io, name);
    }
    try loginFindingsFrom(gpa, report, profiles, has_login, has_legacy);
}

pub fn overlapFindings(gpa: std.mem.Allocator, io: std.Io, base: []const u8, active: ?[]const u8, current: ?[]const u8, live: []const u8, report: *Report) !void {
    if (comptime !platform.supports_keychain) return;
    const name = switch (classifyConfigDirIn(gpa, base, current)) {
        .profile => |n| n,
        else => return,
    };
    const active_name = active orelse return;
    if (!std.mem.eql(u8, name, active_name)) return;
    try overlapFinding(gpa, report, name, credentials.sameAsLive(gpa, io, base, name, live));
}

/// Shell state: the hook, CLAUDE_CONFIG_DIR and the `.csw` that applies to `cwd`.
pub fn shellFindings(gpa: std.mem.Allocator, base: []const u8, cwd: []const u8, bound: ?[]const u8, current: ?[]const u8, report: *Report) !void {
    switch (classifyConfigDirIn(gpa, base, current)) {
        .unset => try report.add(gpa, .ok, "CLAUDE_CONFIG_DIR", "not set (Claude Code follows the active profile)", .{}),
        .profile => |name| {
            const by_hook = bound != null and std.mem.eql(u8, bound.?, current.?);
            try report.add(gpa, .ok, "CLAUDE_CONFIG_DIR", "'{s}' ({s})", .{ name, if (by_hook) "set by the csw hook" else "set by hand" });
        },
        .missing_profile => |name| try report.add(gpa, .warn, "CLAUDE_CONFIG_DIR", "points at profile '{s}', which no longer exists", .{name}),
        .foreign_exists => try report.add(gpa, .ok, "CLAUDE_CONFIG_DIR", "{s} (not a csw profile)", .{current.?}),
        .foreign_missing => try report.add(gpa, .warn, "CLAUDE_CONFIG_DIR", "{s} does not exist", .{current.?}),
    }

    const binding = try bind.findBindingAtIn(gpa, cwd);
    defer if (binding) |b| b.deinit(gpa);
    var applies = false;
    if (binding) |b| {
        if (bind.profileExistsIn(gpa, base, b.name)) {
            applies = true;
            try report.add(gpa, .ok, ".csw binding", "'{s}' (from {s})", .{ b.name, b.dir });
        } else {
            try report.add(gpa, .warn, ".csw binding", "{s}/.csw names '{s}', which does not exist", .{ b.dir, b.name });
        }
    } else {
        try report.add(gpa, .ok, ".csw binding", "none in this directory tree", .{});
    }

    if (bound != null) {
        try report.add(gpa, .ok, "Shell hook", "active in this shell", .{});
    } else if (applies and current == null) {
        try report.add(gpa, .warn, "Shell hook", "a .csw applies here but the hook is not loaded: eval \"$(csw hook zsh)\"", .{});
    } else {
        try report.add(gpa, .ok, "Shell hook", "not detected in this shell (optional)", .{});
    }
}

fn tmpBase(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.Options.debug_io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

fn touchIn(tmp: *std.testing.TmpDir, sub_path: []const u8) !void {
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = sub_path, .data = "{}" });
}

fn mkdirIn(tmp: *std.testing.TmpDir, sub_path: []const u8) !void {
    try tmp.dir.createDir(std.Options.debug_io, sub_path, .default_dir);
}

fn expectFinding(report: Report, label: []const u8, level: Level, detail_part: []const u8) !void {
    for (report.items.items) |item| {
        if (!std.mem.eql(u8, item.label, label)) continue;
        try std.testing.expectEqual(level, item.level);
        try std.testing.expect(std.mem.indexOf(u8, item.detail, detail_part) != null);
        return;
    }
    return error.FindingNotFound;
}

test "classifyConfigDirIn tells profiles, missing profiles and foreign dirs apart" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    try std.testing.expectEqual(ConfigDirKind.unset, classifyConfigDirIn(alloc, base, null));

    try touchIn(&tmp, ".claude.work.json");
    try mkdirIn(&tmp, ".claude.work");
    const work = try paths.profileDirIn(alloc, base, "work");
    defer alloc.free(work);
    try std.testing.expectEqualStrings("work", classifyConfigDirIn(alloc, base, work).profile);

    const ghost = try paths.profileDirIn(alloc, base, "ghost");
    defer alloc.free(ghost);
    try std.testing.expectEqualStrings("ghost", classifyConfigDirIn(alloc, base, ghost).missing_profile);

    try touchIn(&tmp, ".claude.half.json");
    const half = try paths.profileDirIn(alloc, base, "half");
    defer alloc.free(half);
    try std.testing.expectEqualStrings("half", classifyConfigDirIn(alloc, base, half).missing_profile);

    try mkdirIn(&tmp, "elsewhere");
    const elsewhere = try std.fs.path.join(alloc, &.{ base, "elsewhere" });
    defer alloc.free(elsewhere);
    try std.testing.expectEqual(ConfigDirKind.foreign_exists, classifyConfigDirIn(alloc, base, elsewhere));
    try std.testing.expectEqual(ConfigDirKind.foreign_missing, classifyConfigDirIn(alloc, base, "/nonexistent/csw-doctor"));
}

test "namesFinding is ok when empty and lists names otherwise" {
    const alloc = std.testing.allocator;
    var report: Report = .{};
    defer report.deinit(alloc);
    try namesFinding(alloc, &report, "A", "fine", "bad", &.{});
    try namesFinding(alloc, &report, "B", "fine", "bad", &.{ "x", "y" });
    try expectFinding(report, "A", .ok, "fine");
    try expectFinding(report, "B", .warn, "bad: x, y");
}

test "overlapFinding stays silent without data and explains both cases" {
    const alloc = std.testing.allocator;
    var report: Report = .{};
    defer report.deinit(alloc);
    try overlapFinding(alloc, &report, "work", null);
    try std.testing.expectEqual(@as(usize, 0), report.items.items.len);
    try overlapFinding(alloc, &report, "work", true);
    try expectFinding(report, "Login in two places", .warn, "identical copies");
    try overlapFinding(alloc, &report, "work", false);
    try std.testing.expect(std.mem.indexOf(u8, report.items.items[1].detail, "diverged") != null);
}

test "fileFindingsIn flags missing dirs, orphan dirs and stale inner configs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    try touchIn(&tmp, ".claude.good.json");
    try mkdirIn(&tmp, ".claude.good");
    try touchIn(&tmp, ".claude.nodir.json");
    try touchIn(&tmp, ".claude.stale.json");
    try mkdirIn(&tmp, ".claude.stale");
    try touchIn(&tmp, ".claude.stale/.claude.json");
    try mkdirIn(&tmp, ".claude.orphan");
    try touchIn(&tmp, ".claude.json.backup");
    try touchIn(&tmp, ".claude.afile");

    const profiles: []const []const u8 = &.{ "good", "nodir", "stale" };
    var report: Report = .{};
    defer report.deinit(alloc);
    try fileFindingsIn(alloc, base, profiles, &report);
    try expectFinding(report, "Profile directories", .warn, "nodir");
    try expectFinding(report, "Orphan directories", .warn, "orphan");
    try expectFinding(report, "Inner .claude.json", .warn, "stale");
    const orphan_detail = report.items.items[1].detail;
    try std.testing.expect(std.mem.endsWith(u8, orphan_detail, ": orphan"));
    try std.testing.expect(std.mem.indexOf(u8, orphan_detail, "afile") == null);
    try std.testing.expect(std.mem.indexOf(u8, orphan_detail, "backup") == null);
}

test "fileFindingsIn is clean for a healthy base" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    try touchIn(&tmp, ".claude.good.json");
    try mkdirIn(&tmp, ".claude.good");

    var report: Report = .{};
    defer report.deinit(alloc);
    try fileFindingsIn(alloc, base, &.{"good"}, &report);
    for (report.items.items) |item| try std.testing.expectEqual(Level.ok, item.level);
}

test "loginFindingsFrom reports missing logins and legacy entries" {
    const alloc = std.testing.allocator;
    var report: Report = .{};
    defer report.deinit(alloc);
    try loginFindingsFrom(alloc, &report, &.{ "a", "b" }, &.{ true, false }, &.{ true, false });
    try expectFinding(report, "Stored logins", .warn, "b");
    if (platform.supports_keychain) try expectFinding(report, "Legacy entries", .warn, "a");

    var clean: Report = .{};
    defer clean.deinit(alloc);
    try loginFindingsFrom(alloc, &clean, &.{"a"}, &.{true}, &.{false});
    try expectFinding(clean, "Stored logins", .ok, "every profile");
}

test "loginFindings gathers from a temporary base" {
    if (platform.supports_keychain and !keychain.realKeychainEnabled()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    var report: Report = .{};
    defer report.deinit(alloc);
    const token = try testutil.uniqueToken(alloc);
    defer alloc.free(token);
    const name = try std.fmt.allocPrint(alloc, "cswdoctor{s}", .{token});
    defer alloc.free(name);
    try loginFindings(alloc, io, base, &.{name}, &report);
    try expectFinding(report, "Stored logins", .warn, name);
}

test "overlapFindings compares the per-dir login with the live entry" {
    if (comptime !platform.supports_keychain) return error.SkipZigTest;
    if (!keychain.realKeychainEnabled()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    try touchIn(&tmp, ".claude.p.json");
    try mkdirIn(&tmp, ".claude.p");

    const dir_service = try credentials.profileService(alloc, base, "p");
    defer alloc.free(dir_service);
    const token = try testutil.uniqueToken(alloc);
    defer alloc.free(token);
    const live = try std.fmt.allocPrint(alloc, "csw-test-{s}-doctor-live", .{token});
    defer alloc.free(live);
    keychain.delete(alloc, io, dir_service) catch {};
    keychain.delete(alloc, io, live) catch {};
    defer keychain.delete(alloc, io, dir_service) catch {};
    defer keychain.delete(alloc, io, live) catch {};
    try keychain.set(alloc, io, dir_service, "tester", "same");
    try keychain.set(alloc, io, live, "tester", "same");

    const dir = try paths.profileDirIn(alloc, base, "p");
    defer alloc.free(dir);

    var report: Report = .{};
    defer report.deinit(alloc);
    try overlapFindings(alloc, io, base, "p", dir, live, &report);
    try expectFinding(report, "Login in two places", .warn, "identical");

    var other: Report = .{};
    defer other.deinit(alloc);
    try overlapFindings(alloc, io, base, "q", dir, live, &other);
    try overlapFindings(alloc, io, base, null, dir, live, &other);
    try overlapFindings(alloc, io, base, "p", null, live, &other);
    try std.testing.expectEqual(@as(usize, 0), other.items.items.len);
}

test "shellFindings reports the variable, the binding and the hook" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    try touchIn(&tmp, ".claude.work.json");
    try mkdirIn(&tmp, ".claude.work");
    try mkdirIn(&tmp, "proj");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "proj/.csw", .data = "work\n" });
    const proj = try std.fs.path.join(alloc, &.{ base, "proj" });
    defer alloc.free(proj);
    const work = try paths.profileDirIn(alloc, base, "work");
    defer alloc.free(work);

    var hooked: Report = .{};
    defer hooked.deinit(alloc);
    try shellFindings(alloc, base, proj, work, work, &hooked);
    try expectFinding(hooked, "CLAUDE_CONFIG_DIR", .ok, "set by the csw hook");
    try expectFinding(hooked, ".csw binding", .ok, "work");
    try expectFinding(hooked, "Shell hook", .ok, "active");

    var by_hand: Report = .{};
    defer by_hand.deinit(alloc);
    try shellFindings(alloc, base, proj, null, work, &by_hand);
    try expectFinding(by_hand, "CLAUDE_CONFIG_DIR", .ok, "set by hand");
    try expectFinding(by_hand, "Shell hook", .ok, "not detected");

    var unhooked: Report = .{};
    defer unhooked.deinit(alloc);
    try shellFindings(alloc, base, proj, null, null, &unhooked);
    try expectFinding(unhooked, "CLAUDE_CONFIG_DIR", .ok, "not set");
    try expectFinding(unhooked, "Shell hook", .warn, "not loaded");
}

test "shellFindings finds no binding outside any bound tree" {
    const alloc = std.testing.allocator;
    var report: Report = .{};
    defer report.deinit(alloc);
    try shellFindings(alloc, "/nonexistent", "/nonexistent/csw-doctor", null, null, &report);
    try expectFinding(report, ".csw binding", .ok, "none in this directory tree");
    try expectFinding(report, "Shell hook", .ok, "not detected");
}

test "shellFindings warns about a missing profile dir and a dangling binding" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    try mkdirIn(&tmp, "proj");
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "proj/.csw", .data = "ghost\n" });
    try mkdirIn(&tmp, "foreign");
    const proj = try std.fs.path.join(alloc, &.{ base, "proj" });
    defer alloc.free(proj);
    const ghost = try paths.profileDirIn(alloc, base, "ghost");
    defer alloc.free(ghost);
    const foreign = try std.fs.path.join(alloc, &.{ base, "foreign" });
    defer alloc.free(foreign);

    var dangling: Report = .{};
    defer dangling.deinit(alloc);
    try shellFindings(alloc, base, proj, null, ghost, &dangling);
    try expectFinding(dangling, "CLAUDE_CONFIG_DIR", .warn, "no longer exists");
    try expectFinding(dangling, ".csw binding", .warn, "ghost");

    var foreign_report: Report = .{};
    defer foreign_report.deinit(alloc);
    try shellFindings(alloc, base, proj, null, foreign, &foreign_report);
    try expectFinding(foreign_report, "CLAUDE_CONFIG_DIR", .ok, "not a csw profile");

    var missing_report: Report = .{};
    defer missing_report.deinit(alloc);
    try shellFindings(alloc, base, proj, null, "/nonexistent/csw-doctor", &missing_report);
    try expectFinding(missing_report, "CLAUDE_CONFIG_DIR", .warn, "does not exist");
}

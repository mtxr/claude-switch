//! rename.zig — rename a profile across its config files, Keychain entry and Desktop data

const std = @import("std");
const bind = @import("bind.zig");
const credentials = @import("credentials.zig");
const desktop = @import("desktop.zig");
const display = @import("display.zig");
const isolated = @import("isolated.zig");
const keychain = @import("keychain.zig");
const paths = @import("paths.zig");
const profile = @import("profile.zig");
const run = @import("run.zig");
const testutil = @import("testutil.zig");

const c = @import("c");

pub const Report = struct {
    code_renamed: bool = false,
    active_relinked: bool = false,
    inner_relinked: bool = false,
    desktop_renamed: bool = false,
    owner_updated: bool = false,
    owner_dangling: bool = false,
};

pub const RenameArgs = union(enum) {
    pair: struct { old: []const u8, new: []const u8 },
    pick_old: []const u8,
    usage,
};

/// Reads `rename [old] <new>`: with a single name the old profile is picked,
/// which needs a terminal.
pub fn parseArgs(first: ?[]const u8, second: ?[]const u8, interactive: bool) RenameArgs {
    const a = first orelse return .usage;
    if (second) |b| return .{ .pair = .{ .old = a, .new = b } };
    if (interactive) return .{ .pick_old = a };
    return .usage;
}

pub fn validate(old: []const u8, new: []const u8) !void {
    if (!run.isValidName(old)) return error.InvalidProfileName;
    if (!bind.isValidName(new)) return error.InvalidNewName;
    if (std.mem.eql(u8, old, new)) return error.SameName;
}

/// Verifies every precondition without changing anything.
pub fn checkIn(gpa: std.mem.Allocator, base: []const u8, old: []const u8, new: []const u8) !void {
    try validate(old, new);

    const old_json = try paths.profileJsonIn(gpa, base, old);
    defer gpa.free(old_json);
    if (!desktop.pathExists(gpa, old_json)) return error.ProfileNotFound;

    const new_json = try paths.profileJsonIn(gpa, base, new);
    defer gpa.free(new_json);
    const new_dir = try paths.profileDirIn(gpa, base, new);
    defer gpa.free(new_dir);
    const new_desktop = try paths.desktopProfileDirIn(gpa, base, new);
    defer gpa.free(new_desktop);
    for ([_][]const u8{ new_json, new_dir, new_desktop }) |path| {
        if (desktop.pathExists(gpa, path) or desktop.isSymlink(gpa, path)) return error.ProfileAlreadyExists;
    }
}

/// Re-points `<dir>/.claude.json` when it is the link csw created to the old profile json.
fn relinkInner(gpa: std.mem.Allocator, dir: []const u8, old_json: []const u8, new_json: []const u8) !bool {
    const inner = try std.fs.path.join(gpa, &.{ dir, ".claude.json" });
    defer gpa.free(inner);
    if (!desktop.isSymlink(gpa, inner)) return false;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try desktop.readLinkC(gpa, inner, &buf);
    if (!std.mem.eql(u8, buf[0..n], old_json)) return false;

    desktop.deletePathC(gpa, inner);
    const target_z = try gpa.dupeSentinel(u8, new_json, 0);
    defer gpa.free(target_z);
    const inner_z = try gpa.dupeSentinel(u8, inner, 0);
    defer gpa.free(inner_z);
    if (std.c.symlink(target_z, inner_z) != 0) return error.SymlinkFailed;
    return true;
}

/// Renames the files and Desktop data of a profile inside `base`. On a
/// failure part-way it puts back what it already moved.
pub fn renameIn(gpa: std.mem.Allocator, base: []const u8, old: []const u8, new: []const u8, opts: profile.Options) !Report {
    try checkIn(gpa, base, old, new);

    var report: Report = .{};

    const old_json = try paths.profileJsonIn(gpa, base, old);
    defer gpa.free(old_json);
    const new_json = try paths.profileJsonIn(gpa, base, new);
    defer gpa.free(new_json);
    const old_dir = try paths.profileDirIn(gpa, base, old);
    defer gpa.free(old_dir);
    const new_dir = try paths.profileDirIn(gpa, base, new);
    defer gpa.free(new_dir);
    const old_desktop = try paths.desktopProfileDirIn(gpa, base, old);
    defer gpa.free(old_desktop);
    const new_desktop = try paths.desktopProfileDirIn(gpa, base, new);
    defer gpa.free(new_desktop);

    const active = try profile.currentIn(gpa, base);
    defer if (active) |a| gpa.free(a);
    const was_active = opts.code and active != null and std.mem.eql(u8, active.?, old);

    errdefer if (was_active) profile.switchLinksIn(gpa, base, old) catch {};

    var json_moved = false;
    errdefer if (json_moved) desktop.renameC(gpa, new_json, old_json) catch {};
    var dir_moved = false;
    errdefer if (dir_moved) desktop.renameC(gpa, new_dir, old_dir) catch {};

    if (opts.code) {
        try desktop.renameC(gpa, old_json, new_json);
        json_moved = true;
        if (desktop.pathExists(gpa, old_dir)) {
            try desktop.renameC(gpa, old_dir, new_dir);
            dir_moved = true;
            report.inner_relinked = try relinkInner(gpa, new_dir, old_json, new_json);
        }
        report.code_renamed = true;
        if (was_active) {
            try profile.switchLinksIn(gpa, base, new);
            report.active_relinked = true;
        }
    }

    const owner = try desktop.ownerIn(gpa, base);
    defer if (owner) |o| gpa.free(o);
    const owns_main = owner != null and std.mem.eql(u8, owner.?, old);

    if (opts.desktop) {
        if (desktop.pathExists(gpa, old_desktop)) {
            try desktop.renameC(gpa, old_desktop, new_desktop);
            report.desktop_renamed = true;
        }
        if (owns_main) {
            desktop.writeOwnerIn(gpa, base, new);
            report.owner_updated = true;
        }
    } else if (opts.code and owns_main) {
        report.owner_dangling = true;
    }

    return report;
}

/// Same as `renameIn`, plus the per-directory Keychain login: it is copied
/// to the new service first and the old one removed only once the files moved.
pub fn renameWithCredentialsIn(gpa: std.mem.Allocator, io: std.Io, base: []const u8, old: []const u8, new: []const u8, opts: profile.Options) !Report {
    try checkIn(gpa, base, old, new);

    const copied = opts.code and try credentials.copyProfile(gpa, io, base, old, new);
    errdefer if (copied) credentials.forget(gpa, io, base, new) catch {};

    const report = try renameIn(gpa, base, old, new, opts);
    if (opts.code) try credentials.forget(gpa, io, base, old);
    return report;
}

pub fn cmdRename(gpa: std.mem.Allocator, io: std.Io, old: []const u8, new: []const u8, opts: profile.Options) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    if (opts.desktop) try isolated.refuseWhenOpen(gpa, io, h, old);
    const report = renameWithCredentialsIn(gpa, io, h, old, new, opts) catch |e| {
        reportError(old, new, e);
        return e;
    };

    const msg = try std.fmt.allocPrint(gpa, "Renamed '{s}' to '{s}'", .{ old, new });
    defer gpa.free(msg);
    display.ok(msg);
    if (report.active_relinked) display.info("The active profile was re-linked");
    if (report.desktop_renamed or report.owner_updated) {
        display.info("Claude Desktop data was renamed");
    } else if (opts.desktop) {
        display.info("No Claude Desktop data found for that profile");
    }
    if (report.owner_dangling) {
        const warn = try std.fmt.allocPrint(gpa, "Claude Desktop data still belongs to '{s}'; run: csw rename {s} {s} --desktop", .{ old, old, new });
        defer gpa.free(warn);
        display.info(warn);
    }
    const follow_up = try std.fmt.allocPrint(
        gpa,
        "Update any .csw file naming '{s}' and restart shells whose CLAUDE_CONFIG_DIR still points at ~/.claude.{s}",
        .{ old, old },
    );
    defer gpa.free(follow_up);
    display.info(follow_up);
}

fn reportError(old: []const u8, new: []const u8, e: anyerror) void {
    switch (e) {
        error.InvalidProfileName => display.print("❌  Invalid profile name '{s}'\n", .{old}),
        error.InvalidNewName => display.print("❌  Invalid new name '{s}'. Use only A-Z a-z 0-9 . _ - (max 64 chars)\n", .{new}),
        error.SameName => display.print("❌  '{s}' already has that name\n", .{old}),
        error.ProfileNotFound => display.print("❌  Profile '{s}' not found. Use: csw save {s}\n", .{ old, old }),
        error.ProfileAlreadyExists => display.print("❌  '{s}' already exists. Pick another name or delete it first\n", .{new}),
        else => display.print("❌  Could not rename '{s}' to '{s}': {s}. Nothing was left half-done\n", .{ old, new, @errorName(e) }),
    }
}

fn tmpBase(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.Options.debug_io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

fn touch(alloc: std.mem.Allocator, path: []const u8) !void {
    const z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(z);
    const fd = std.c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.CreateFileFailed;
    _ = std.c.close(fd);
}

fn symlinkTo(alloc: std.mem.Allocator, target: []const u8, link: []const u8) !void {
    const target_z = try alloc.dupeSentinel(u8, target, 0);
    defer alloc.free(target_z);
    const link_z = try alloc.dupeSentinel(u8, link, 0);
    defer alloc.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target_z, link_z));
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: []u8,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const base = try tmpBase(alloc, &tmp);
        return .{ .tmp = tmp, .base = base };
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        alloc.free(self.base);
        self.tmp.cleanup();
    }

    fn addProfile(self: Fixture, alloc: std.mem.Allocator, name: []const u8) !void {
        const json = try paths.profileJsonIn(alloc, self.base, name);
        defer alloc.free(json);
        try touch(alloc, json);
        const dir = try paths.profileDirIn(alloc, self.base, name);
        defer alloc.free(dir);
        try desktop.mkdirAllC(alloc, dir);
    }

    fn activate(self: Fixture, alloc: std.mem.Allocator, name: []const u8) !void {
        try profile.switchLinksIn(alloc, self.base, name);
    }

    fn has(self: Fixture, alloc: std.mem.Allocator, relative: []const u8) !bool {
        const path = try std.fs.path.join(alloc, &.{ self.base, relative });
        defer alloc.free(path);
        return desktop.pathExists(alloc, path);
    }
};

test "parseArgs reads two names, one name with a terminal, or asks for usage" {
    const pair = parseArgs("a", "b", false).pair;
    try std.testing.expectEqualStrings("a", pair.old);
    try std.testing.expectEqualStrings("b", pair.new);
    try std.testing.expectEqualStrings("b", parseArgs("b", null, true).pick_old);
    try std.testing.expect(parseArgs("b", null, false) == .usage);
    try std.testing.expect(parseArgs(null, null, true) == .usage);
}

test "validate rejects bad and identical names" {
    try validate("work", "job");
    try std.testing.expectError(error.InvalidProfileName, validate("a/b", "job"));
    try std.testing.expectError(error.InvalidNewName, validate("work", "a b"));
    try std.testing.expectError(error.InvalidNewName, validate("work", "$(x)"));
    try std.testing.expectError(error.SameName, validate("work", "work"));
}

test "checkIn needs the old profile and a free new name" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try std.testing.expectError(error.ProfileNotFound, checkIn(alloc, fx.base, "work", "job"));
    try fx.addProfile(alloc, "work");
    try checkIn(alloc, fx.base, "work", "job");

    try fx.addProfile(alloc, "job");
    try std.testing.expectError(error.ProfileAlreadyExists, checkIn(alloc, fx.base, "work", "job"));
}

test "checkIn refuses a new name that already has Desktop data or a dangling dir" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");

    const d_new = try paths.desktopProfileDirIn(alloc, fx.base, "job");
    defer alloc.free(d_new);
    try desktop.mkdirAllC(alloc, d_new);
    try std.testing.expectError(error.ProfileAlreadyExists, checkIn(alloc, fx.base, "work", "job"));
}

test "renameIn moves the json and dir and fixes the inner link" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");

    const old_json = try paths.profileJsonIn(alloc, fx.base, "work");
    defer alloc.free(old_json);
    const old_dir = try paths.profileDirIn(alloc, fx.base, "work");
    defer alloc.free(old_dir);
    const inner = try std.fs.path.join(alloc, &.{ old_dir, ".claude.json" });
    defer alloc.free(inner);
    try symlinkTo(alloc, old_json, inner);

    const report = try renameIn(alloc, fx.base, "work", "job", .{});
    try std.testing.expect(report.code_renamed);
    try std.testing.expect(report.inner_relinked);
    try std.testing.expect(!report.active_relinked);
    try std.testing.expect(!try fx.has(alloc, ".claude.work.json"));
    try std.testing.expect(!try fx.has(alloc, ".claude.work"));
    try std.testing.expect(try fx.has(alloc, ".claude.job.json"));

    const new_json = try paths.profileJsonIn(alloc, fx.base, "job");
    defer alloc.free(new_json);
    const new_inner = try std.fs.path.join(alloc, &.{ fx.base, ".claude.job", ".claude.json" });
    defer alloc.free(new_inner);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try desktop.readLinkC(alloc, new_inner, &buf);
    try std.testing.expectEqualStrings(new_json, buf[0..n]);
}

test "renameIn leaves a regular or foreign inner .claude.json alone" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");
    try fx.addProfile(alloc, "other");

    const other_json = try paths.profileJsonIn(alloc, fx.base, "other");
    defer alloc.free(other_json);
    const inner = try std.fs.path.join(alloc, &.{ fx.base, ".claude.work", ".claude.json" });
    defer alloc.free(inner);
    try symlinkTo(alloc, other_json, inner);
    const foreign = try renameIn(alloc, fx.base, "work", "job", .{});
    try std.testing.expect(!foreign.inner_relinked);

    var fx2 = try Fixture.init(alloc);
    defer fx2.deinit(alloc);
    try fx2.addProfile(alloc, "work");
    const regular = try std.fs.path.join(alloc, &.{ fx2.base, ".claude.work", ".claude.json" });
    defer alloc.free(regular);
    try touch(alloc, regular);
    const plain = try renameIn(alloc, fx2.base, "work", "job", .{});
    try std.testing.expect(!plain.inner_relinked);
}

test "renameIn handles a profile whose dir does not exist" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    const json = try paths.profileJsonIn(alloc, fx.base, "work");
    defer alloc.free(json);
    try touch(alloc, json);

    const report = try renameIn(alloc, fx.base, "work", "job", .{});
    try std.testing.expect(report.code_renamed);
    try std.testing.expect(!report.inner_relinked);
    try std.testing.expect(try fx.has(alloc, ".claude.job.json"));
}

test "renameIn re-links the active profile" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");
    try fx.activate(alloc, "work");

    const report = try renameIn(alloc, fx.base, "work", "job", .{});
    try std.testing.expect(report.active_relinked);

    const active = (try profile.currentIn(alloc, fx.base)).?;
    defer alloc.free(active);
    try std.testing.expectEqualStrings("job", active);
}

test "renameIn rolls back when the new name is invalid or taken" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");
    try fx.addProfile(alloc, "job");

    try std.testing.expectError(error.ProfileAlreadyExists, renameIn(alloc, fx.base, "work", "job", .{}));
    try std.testing.expectError(error.InvalidNewName, renameIn(alloc, fx.base, "work", "a b", .{}));
    try std.testing.expect(try fx.has(alloc, ".claude.work.json"));
    try std.testing.expect(try fx.has(alloc, ".claude.work"));
}

test "renameIn puts the files back when re-linking fails" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");
    try fx.activate(alloc, "work");

    const cd = try paths.claudeDirIn(alloc, fx.base);
    defer alloc.free(cd);
    desktop.deletePathC(alloc, cd);
    try desktop.mkdirAllC(alloc, cd);

    try std.testing.expectError(error.NotASymlink, renameIn(alloc, fx.base, "work", "job", .{}));
    try std.testing.expect(try fx.has(alloc, ".claude.work.json"));
    try std.testing.expect(try fx.has(alloc, ".claude.work"));
    try std.testing.expect(!try fx.has(alloc, ".claude.job.json"));
    try std.testing.expect(!try fx.has(alloc, ".claude.job"));
}

test "renameIn with --desktop renames stored data and the owner marker" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");
    try fx.addProfile(alloc, "home");

    const stored = try paths.desktopProfileDirIn(alloc, fx.base, "work");
    defer alloc.free(stored);
    try desktop.mkdirAllC(alloc, stored);
    const main_dir = try paths.desktopDirIn(alloc, fx.base);
    defer alloc.free(main_dir);
    try desktop.mkdirAllC(alloc, main_dir);
    desktop.writeOwnerIn(alloc, fx.base, "home");

    const stored_only = try renameIn(alloc, fx.base, "work", "job", .{ .code = false, .desktop = true });
    try std.testing.expect(stored_only.desktop_renamed);
    try std.testing.expect(!stored_only.owner_updated);
    try std.testing.expect(!stored_only.code_renamed);
    try std.testing.expect(try fx.has(alloc, ".claude.work.json"));
    try std.testing.expect(try fx.has(alloc, "Library/Application Support/Claude.job"));

    const owner_home = (try desktop.ownerIn(alloc, fx.base)).?;
    defer alloc.free(owner_home);
    try std.testing.expectEqualStrings("home", owner_home);
}

test "renameIn with --all updates the owner marker of the main Desktop dir" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");

    const main_dir = try paths.desktopDirIn(alloc, fx.base);
    defer alloc.free(main_dir);
    try desktop.mkdirAllC(alloc, main_dir);
    desktop.writeOwnerIn(alloc, fx.base, "work");

    const report = try renameIn(alloc, fx.base, "work", "job", profile.Options.both);
    try std.testing.expect(report.code_renamed);
    try std.testing.expect(report.owner_updated);
    try std.testing.expect(!report.desktop_renamed);
    try std.testing.expect(!report.owner_dangling);

    const owner = (try desktop.ownerIn(alloc, fx.base)).?;
    defer alloc.free(owner);
    try std.testing.expectEqualStrings("job", owner);
}

test "renameIn without --desktop leaves Desktop alone and flags a dangling owner" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");

    const main_dir = try paths.desktopDirIn(alloc, fx.base);
    defer alloc.free(main_dir);
    try desktop.mkdirAllC(alloc, main_dir);
    desktop.writeOwnerIn(alloc, fx.base, "work");

    const report = try renameIn(alloc, fx.base, "work", "job", .{});
    try std.testing.expect(report.owner_dangling);
    try std.testing.expect(!report.owner_updated);

    const owner = (try desktop.ownerIn(alloc, fx.base)).?;
    defer alloc.free(owner);
    try std.testing.expectEqualStrings("work", owner);
}

test "renameWithCredentialsIn moves the per-dir login with the files" {
    if (!keychain.realKeychainEnabled()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const token = try testutil.uniqueToken(alloc);
    defer alloc.free(token);
    const old = try std.fmt.allocPrint(alloc, "csw-test-{s}-ren-old", .{token});
    defer alloc.free(old);
    const new = try std.fmt.allocPrint(alloc, "csw-test-{s}-ren-new", .{token});
    defer alloc.free(new);
    try fx.addProfile(alloc, old);

    const old_service = try credentials.profileService(alloc, fx.base, old);
    defer alloc.free(old_service);
    const new_service = try credentials.profileService(alloc, fx.base, new);
    defer alloc.free(new_service);
    keychain.delete(alloc, io, old_service) catch {};
    keychain.delete(alloc, io, new_service) catch {};
    defer keychain.delete(alloc, io, old_service) catch {};
    defer keychain.delete(alloc, io, new_service) catch {};

    try keychain.set(alloc, io, old_service, "tester", "{\"claudeAiOauth\":{\"expiresAt\":1}}");
    const report = try renameWithCredentialsIn(alloc, io, fx.base, old, new, .{});
    try std.testing.expect(report.code_renamed);
    try std.testing.expect(keychain.exists(alloc, io, new_service));
    try std.testing.expect(!keychain.exists(alloc, io, old_service));
}

test "renameWithCredentialsIn keeps the old login when the rename is refused" {
    if (!keychain.realKeychainEnabled()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const token = try testutil.uniqueToken(alloc);
    defer alloc.free(token);
    const old = try std.fmt.allocPrint(alloc, "csw-test-{s}-keep-old", .{token});
    defer alloc.free(old);
    const taken = try std.fmt.allocPrint(alloc, "csw-test-{s}-keep-new", .{token});
    defer alloc.free(taken);
    try fx.addProfile(alloc, old);
    try fx.addProfile(alloc, taken);

    const old_service = try credentials.profileService(alloc, fx.base, old);
    defer alloc.free(old_service);
    keychain.delete(alloc, io, old_service) catch {};
    defer keychain.delete(alloc, io, old_service) catch {};
    try keychain.set(alloc, io, old_service, "tester", "{}");

    try std.testing.expectError(error.ProfileAlreadyExists, renameWithCredentialsIn(alloc, io, fx.base, old, taken, .{}));
    try std.testing.expect(keychain.exists(alloc, io, old_service));
}

test "renameWithCredentialsIn skips the Keychain for Desktop-only renames" {
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.addProfile(alloc, "work");
    const stored = try paths.desktopProfileDirIn(alloc, fx.base, "work");
    defer alloc.free(stored);
    try desktop.mkdirAllC(alloc, stored);

    const report = try renameWithCredentialsIn(alloc, io, fx.base, "work", "job", .{ .code = false, .desktop = true });
    try std.testing.expect(report.desktop_renamed);
    try std.testing.expect(!report.code_renamed);
}

test "reportError covers every error kind" {
    reportError("a", "b", error.InvalidProfileName);
    reportError("a", "b", error.InvalidNewName);
    reportError("a", "b", error.SameName);
    reportError("a", "b", error.ProfileNotFound);
    reportError("a", "b", error.ProfileAlreadyExists);
    reportError("a", "b", error.RenameFailed);
}

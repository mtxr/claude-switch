//! run.zig — concurrent profiles via CLAUDE_CONFIG_DIR

const std = @import("std");
const credentials = @import("credentials.zig");
const desktop = @import("desktop.zig");
const display = @import("display.zig");
const paths = @import("paths.zig");
const platform = @import("platform.zig");
const profile = @import("profile.zig");

const c = @import("c");

const CONFIG_DIR_VAR = "CLAUDE_CONFIG_DIR";
const CLAUDE_BINARY = "claude";
const INNER_CLAUDE_JSON = ".claude.json";

pub fn cmdEnv(gpa: std.mem.Allocator, name: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const dir = prepareIn(gpa, h, name) catch |e| return reportPrepareError(gpa, name, e);
    defer gpa.free(dir);

    const line = try exportLine(gpa, dir);
    defer gpa.free(line);
    display.print("{s}\n", .{line});
}

pub fn cmdRun(gpa: std.mem.Allocator, io: std.Io, name: []const u8, claude_args: []const []const u8) !void {
    return runProfile(gpa, io, name, claude_args, false);
}

pub fn cmdLogin(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    return runProfile(gpa, io, name, &.{}, true);
}

fn runProfile(gpa: std.mem.Allocator, io: std.Io, name: []const u8, claude_args: []const []const u8, announce_login: bool) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const dir = prepareIn(gpa, h, name) catch |e| return reportPrepareError(gpa, name, e);
    defer gpa.free(dir);

    try reportCredentials(gpa, io, h, dir, name, if (announce_login) .login else .run);

    const argv = try buildArgv(gpa, claude_args);
    defer freeArgv(gpa, argv);

    const dir_z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(dir_z);
    if (c.setenv(CONFIG_DIR_VAR, dir_z, 1) != 0) return error.SetEnvFailed;

    _ = c.execvp(CLAUDE_BINARY, @ptrCast(argv.ptr));
    display.err("Could not execute 'claude'. Is it installed and on your PATH?");
    return error.ExecFailed;
}

pub const ReportMode = enum { run, login };

/// Seeds the per-dir Keychain entry of a profile and tells the user what happened.
pub fn reportCredentials(gpa: std.mem.Allocator, io: std.Io, base: []const u8, dir: []const u8, name: []const u8, mode: ReportMode) !void {
    if (comptime !platform.supports_keychain) return;
    const active = try profile.currentIn(gpa, base);
    defer if (active) |a| gpa.free(a);
    const adopt_live = active != null and std.mem.eql(u8, active.?, name);

    const status = credentials.ensure(gpa, io, dir, name, credentials.DEFAULT_SERVICE, adopt_live) catch |e| {
        display.err("Could not check the Keychain for this profile's login");
        return e;
    };
    const msg = (try credentialsMessage(gpa, status, mode, name)) orelse return;
    defer gpa.free(msg);
    display.info(msg);
}

/// What to tell the user about a profile's login, or null when there is nothing to say.
pub fn credentialsMessage(gpa: std.mem.Allocator, status: credentials.Status, mode: ReportMode, name: []const u8) !?[]const u8 {
    return switch (status) {
        .ready => if (mode == .login) try std.fmt.allocPrint(gpa, "Profile '{s}' is already logged in", .{name}) else null,
        .migratable => try std.fmt.allocPrint(gpa, "Reused the login saved for '{s}'", .{name}),
        .needs_login => try std.fmt.allocPrint(gpa, "No login for '{s}' on this machine yet. Run /login inside claude; it is remembered for this profile afterwards.", .{name}),
    };
}

fn reportPrepareError(gpa: std.mem.Allocator, name: []const u8, e: anyerror) anyerror {
    const msg = switch (e) {
        error.InvalidProfileName => std.fmt.allocPrint(gpa, "Invalid profile name '{s}'", .{name}),
        error.ProfileNotFound => std.fmt.allocPrint(gpa, "Profile '{s}' not found. Use: csw save {s}", .{ name, name }),
        else => std.fmt.allocPrint(gpa, "Could not prepare profile '{s}': {s}", .{ name, @errorName(e) }),
    } catch return e;
    defer gpa.free(msg);
    display.err(msg);
    return e;
}

/// Validates the profile, ensures its config dir exists and exposes the
/// profile JSON as `<dir>/.claude.json` (where Claude Code looks when
/// CLAUDE_CONFIG_DIR is set). Returns the config dir (caller frees).
pub fn prepareIn(gpa: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (!isValidName(name)) return error.InvalidProfileName;

    const p_json = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(p_json);
    if (!desktop.pathExists(gpa, p_json)) return error.ProfileNotFound;

    const dir = try paths.profileDirIn(gpa, base, name);
    errdefer gpa.free(dir);
    if (!desktop.pathExists(gpa, dir)) try desktop.mkdirAllC(gpa, dir);

    try ensureInnerConfigIn(gpa, dir);
    return dir;
}

/// Exposes `~/.claude.<name>.json` as `<dir>/.claude.json` when the dir has none.
pub fn ensureInnerConfigIn(gpa: std.mem.Allocator, dir: []const u8) !void {
    const inner = try std.fs.path.join(gpa, &.{ dir, INNER_CLAUDE_JSON });
    defer gpa.free(inner);
    if (desktop.pathExists(gpa, inner) or desktop.isSymlink(gpa, inner)) return;

    const name = profileNameOfDir(dir) orelse return error.NotAProfileDir;
    const base = std.fs.path.dirname(dir) orelse return error.NotAProfileDir;
    const p_json = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(p_json);
    const target_z = try gpa.dupeSentinel(u8, p_json, 0);
    defer gpa.free(target_z);
    const inner_z = try gpa.dupeSentinel(u8, inner, 0);
    defer gpa.free(inner_z);
    if (std.c.symlink(target_z, inner_z) != 0) return error.SymlinkFailed;
}

pub fn profileNameOfDir(dir: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(dir);
    const prefix = ".claude.";
    if (!std.mem.startsWith(u8, base, prefix) or base.len == prefix.len) return null;
    return base[prefix.len..];
}

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\x00") == null;
}

/// Single-quotes the path so the line is safe to `eval` in POSIX shells.
pub fn exportLine(gpa: std.mem.Allocator, dir: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "export " ++ CONFIG_DIR_VAR ++ "='");
    for (dir) |ch| {
        if (ch == '\'') {
            try out.appendSlice(gpa, "'\\''");
        } else {
            try out.append(gpa, ch);
        }
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

/// Drops a single leading `--` separator from the arguments forwarded to claude.
pub fn forwardedArgs(args: []const []const u8) []const []const u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) return args[1..];
    return args;
}

pub fn buildArgv(gpa: std.mem.Allocator, claude_args: []const []const u8) ![:null]?[*:0]u8 {
    const forwarded = forwardedArgs(claude_args);
    const argv = try gpa.allocSentinel(?[*:0]u8, forwarded.len + 1, null);
    var filled: usize = 0;
    errdefer {
        for (argv[0..filled]) |item| gpa.free(std.mem.span(item.?));
        gpa.free(argv);
    }
    argv[0] = try gpa.dupeSentinel(u8, CLAUDE_BINARY, 0);
    filled = 1;
    for (forwarded, 1..) |arg, i| {
        argv[i] = try gpa.dupeSentinel(u8, arg, 0);
        filled += 1;
    }
    return argv;
}

pub fn freeArgv(gpa: std.mem.Allocator, argv: [:null]?[*:0]u8) void {
    for (argv) |item| gpa.free(std.mem.span(item.?));
    gpa.free(argv);
}

// ── Tests ────────────────────────────────────────────────────────────────────

fn tmpBase(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
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

test "credentialsMessage says nothing for a ready run and speaks otherwise" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]const u8, null), try credentialsMessage(alloc, .ready, .run, "work"));

    const ready_login = (try credentialsMessage(alloc, .ready, .login, "work")).?;
    defer alloc.free(ready_login);
    try std.testing.expectEqualStrings("Profile 'work' is already logged in", ready_login);

    const migrated = (try credentialsMessage(alloc, .migratable, .run, "work")).?;
    defer alloc.free(migrated);
    try std.testing.expect(std.mem.indexOf(u8, migrated, "Reused") != null);

    const needs = (try credentialsMessage(alloc, .needs_login, .login, "work")).?;
    defer alloc.free(needs);
    try std.testing.expect(std.mem.indexOf(u8, needs, "/login") != null);
}

test "isValidName" {
    try std.testing.expect(isValidName("work"));
    try std.testing.expect(isValidName("my.profile-2"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("."));
    try std.testing.expect(!isValidName(".."));
    try std.testing.expect(!isValidName("a/b"));
    try std.testing.expect(!isValidName("a\x00b"));
}

test "exportLine quotes plain and tricky paths" {
    const alloc = std.testing.allocator;
    const plain = try exportLine(alloc, "/Users/m/.claude.work");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("export CLAUDE_CONFIG_DIR='/Users/m/.claude.work'", plain);

    const tricky = try exportLine(alloc, "/Users/o'brien/.claude.work");
    defer alloc.free(tricky);
    try std.testing.expectEqualStrings("export CLAUDE_CONFIG_DIR='/Users/o'\\''brien/.claude.work'", tricky);
}

test "forwardedArgs strips one leading separator" {
    const none: []const []const u8 = &.{};
    try std.testing.expectEqual(@as(usize, 0), forwardedArgs(none).len);
    const plain: []const []const u8 = &.{ "-p", "hi" };
    try std.testing.expectEqual(@as(usize, 2), forwardedArgs(plain).len);
    const sep: []const []const u8 = &.{ "--", "--resume", "--" };
    const out = forwardedArgs(sep);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("--resume", out[0]);
}

test "buildArgv puts claude first and forwards args" {
    const alloc = std.testing.allocator;
    const argv = try buildArgv(alloc, &.{ "--", "-p", "hello" });
    defer freeArgv(alloc, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("claude", std.mem.span(argv[0].?));
    try std.testing.expectEqualStrings("-p", std.mem.span(argv[1].?));
    try std.testing.expectEqualStrings("hello", std.mem.span(argv[2].?));
    try std.testing.expect(argv[3] == null);
}

test "buildArgv without args is just claude" {
    const alloc = std.testing.allocator;
    const argv = try buildArgv(alloc, &.{});
    defer freeArgv(alloc, argv);
    try std.testing.expectEqual(@as(usize, 1), argv.len);
}

test "prepareIn rejects invalid and unknown profiles" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    try std.testing.expectError(error.InvalidProfileName, prepareIn(alloc, base, "../x"));
    try std.testing.expectError(error.ProfileNotFound, prepareIn(alloc, base, "ghost"));
}

test "prepareIn creates dir and links inner .claude.json" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    const p_json = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(p_json);
    try touch(alloc, p_json);

    const dir = try prepareIn(alloc, base, "work");
    defer alloc.free(dir);
    const expected_dir = try paths.profileDirIn(alloc, base, "work");
    defer alloc.free(expected_dir);
    try std.testing.expectEqualStrings(expected_dir, dir);

    const inner = try std.fs.path.join(alloc, &.{ dir, ".claude.json" });
    defer alloc.free(inner);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try desktop.readLinkC(alloc, inner, &buf);
    try std.testing.expectEqualStrings(p_json, buf[0..n]);

    const again = try prepareIn(alloc, base, "work");
    defer alloc.free(again);
    try std.testing.expectEqualStrings(dir, again);
}

test "prepareIn keeps an existing regular inner .claude.json" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    const p_json = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(p_json);
    try touch(alloc, p_json);
    const dir = try paths.profileDirIn(alloc, base, "work");
    defer alloc.free(dir);
    try desktop.mkdirAllC(alloc, dir);
    const inner = try std.fs.path.join(alloc, &.{ dir, ".claude.json" });
    defer alloc.free(inner);
    try touch(alloc, inner);

    const out = try prepareIn(alloc, base, "work");
    defer alloc.free(out);
    try std.testing.expect(!desktop.isSymlink(alloc, inner));
}

test "profileNameOfDir extracts the profile name" {
    try std.testing.expectEqualStrings("work", profileNameOfDir("/Users/m/.claude.work").?);
    try std.testing.expect(profileNameOfDir("/Users/m/.claude.") == null);
    try std.testing.expect(profileNameOfDir("/Users/m/other") == null);
}

test "ensureInnerConfigIn links the profile json and is idempotent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    const p_json = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(p_json);
    try touch(alloc, p_json);
    const dir = try paths.profileDirIn(alloc, base, "work");
    defer alloc.free(dir);
    try desktop.mkdirAllC(alloc, dir);

    try ensureInnerConfigIn(alloc, dir);
    try ensureInnerConfigIn(alloc, dir);
    const inner = try std.fs.path.join(alloc, &.{ dir, ".claude.json" });
    defer alloc.free(inner);
    try std.testing.expect(desktop.isSymlink(alloc, inner));
}

test "ensureInnerConfigIn rejects a dir that is not a profile dir" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    const dir = try std.fs.path.join(alloc, &.{ base, "plain" });
    defer alloc.free(dir);
    try desktop.mkdirAllC(alloc, dir);
    try std.testing.expectError(error.NotAProfileDir, ensureInnerConfigIn(alloc, dir));
}

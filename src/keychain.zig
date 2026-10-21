//! keychain.zig — macOS Keychain access via the `security` CLI
//!
//! On Linux there is no keychain: Claude Code credentials live in
//! `<dir>/.credentials.json` and are read straight from the file. Writing and
//! deleting do not apply, since switching profiles already moves the whole
//! directory through a symlink.

const std = @import("std");
const c_time = @cImport(@cInclude("time.h"));
const paths = @import("paths.zig");
const platform = @import("platform.zig");

const CODE_SERVICE = "Claude Code-credentials";
const PROFILE_SERVICE_PREFIX = "csw-code-";
const CREDENTIALS_FILE = ".credentials.json";
const MAX_CREDENTIALS_BYTES = 64 * 1024;

/// Maps a Keychain service name to the equivalent credentials file on Linux.
pub fn credentialsPathIn(gpa: std.mem.Allocator, base: []const u8, service: []const u8) !?[]const u8 {
    const dir = if (std.mem.eql(u8, service, CODE_SERVICE))
        try paths.claudeDirIn(gpa, base)
    else if (std.mem.startsWith(u8, service, PROFILE_SERVICE_PREFIX) and service.len > PROFILE_SERVICE_PREFIX.len)
        try paths.profileDirIn(gpa, base, service[PROFILE_SERVICE_PREFIX.len..])
    else
        return null;
    defer gpa.free(dir);
    return @as(?[]const u8, try std.fs.path.join(gpa, &.{ dir, CREDENTIALS_FILE }));
}

pub fn fileGetIn(gpa: std.mem.Allocator, base: []const u8, service: []const u8) ![]const u8 {
    const path = (try credentialsPathIn(gpa, base, service)) orelse return error.KeychainNotFound;
    defer gpa.free(path);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    const fd = std.c.open(path_z, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return error.KeychainNotFound;
    defer _ = std.c.close(fd);

    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (content.items.len < MAX_CREDENTIALS_BYTES) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        try content.appendSlice(gpa, chunk[0..@intCast(n)]);
    }

    const trimmed = std.mem.trim(u8, content.items, " \t\r\n");
    if (trimmed.len == 0) return error.KeychainNotFound;
    const result = try gpa.dupe(u8, trimmed);
    content.deinit(gpa);
    return result;
}

fn fileGet(gpa: std.mem.Allocator, service: []const u8) ![]const u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    return fileGetIn(gpa, h, service);
}

pub fn get(gpa: std.mem.Allocator, io: std.Io, service: []const u8) ![]const u8 {
    if (comptime !platform.supports_keychain) return fileGet(gpa, service);
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "security", "find-generic-password", "-s", service, "-w" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(1024),
    });
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) return error.KeychainNotFound;

    const trimmed = std.mem.trimEnd(u8, result.stdout, "\n\r");
    return gpa.dupe(u8, trimmed);
}

pub fn getAccount(gpa: std.mem.Allocator, io: std.Io, service: []const u8) []const u8 {
    if (comptime !platform.supports_keychain) return gpa.dupe(u8, "user") catch "user";
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "security", "find-generic-password", "-s", service },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(1024),
    }) catch return gpa.dupe(u8, "user") catch "user";
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"acct\"") == null) continue;
        var parts = std.mem.splitScalar(u8, line, '"');
        var idx: usize = 0;
        while (parts.next()) |part| {
            if (idx == 3) return gpa.dupe(u8, part) catch "user";
            idx += 1;
        }
    }
    return gpa.dupe(u8, "user") catch "user";
}

pub fn set(gpa: std.mem.Allocator, io: std.Io, service: []const u8, account: []const u8, value: []const u8) !void {
    if (comptime !platform.supports_keychain) return error.UnsupportedPlatform;
    delete(gpa, io, service) catch {};

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "security", "add-generic-password", "-s", service, "-a", account, "-w", value },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) {
        @import("display.zig").err(std.mem.trimEnd(u8, result.stderr, "\n\r"));
        return error.KeychainWriteFailed;
    }
}

pub fn delete(gpa: std.mem.Allocator, io: std.Io, service: []const u8) !void {
    if (comptime !platform.supports_keychain) return error.UnsupportedPlatform;
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "security", "delete-generic-password", "-s", service },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

fn realKeychainEnabled() bool {
    if (!platform.supports_keychain) return false;
    const v = std.c.getenv("CSW_TEST_KEYCHAIN") orelse return false;
    return std.mem.eql(u8, std.mem.sliceTo(v, 0), "1");
}

test "get on a missing service returns an error" {
    if (!realKeychainEnabled()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    const svc = try std.fmt.allocPrint(alloc, "csw-test-{d}-missing", .{@as(i64, c_time.time(null))});
    defer alloc.free(svc);
    delete(alloc, io, svc) catch {};
    try std.testing.expectError(error.KeychainNotFound, get(alloc, io, svc));
}

test "set and get round-trip" {
    if (!realKeychainEnabled()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    const svc = try std.fmt.allocPrint(alloc, "csw-test-{d}-rt", .{@as(i64, c_time.time(null))});
    defer alloc.free(svc);
    delete(alloc, io, svc) catch {};
    defer delete(alloc, io, svc) catch {};

    try set(alloc, io, svc, "testuser", "secret-value");
    const val = try get(alloc, io, svc);
    defer alloc.free(val);
    try std.testing.expectEqualStrings("secret-value", val);
}

test "set overwrites existing entry" {
    if (!realKeychainEnabled()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    const svc = try std.fmt.allocPrint(alloc, "csw-test-{d}-ow", .{@as(i64, c_time.time(null))});
    defer alloc.free(svc);
    delete(alloc, io, svc) catch {};
    defer delete(alloc, io, svc) catch {};

    try set(alloc, io, svc, "user", "first");
    try set(alloc, io, svc, "user", "second");
    const val = try get(alloc, io, svc);
    defer alloc.free(val);
    try std.testing.expectEqualStrings("second", val);
}

test "delete of a missing entry does not fail" {
    if (!realKeychainEnabled()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    const svc = try std.fmt.allocPrint(alloc, "csw-test-{d}-del", .{@as(i64, c_time.time(null))});
    defer alloc.free(svc);
    delete(alloc, io, svc) catch {};
    try delete(alloc, io, svc);
}

fn tmpBase(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    return alloc.dupe(u8, base_buf[0..base_len]);
}

fn writeCredentials(alloc: std.mem.Allocator, dir: []const u8, content: []const u8) !void {
    try @import("desktop.zig").mkdirAllC(alloc, dir);
    const file = try std.fs.path.join(alloc, &.{ dir, CREDENTIALS_FILE });
    defer alloc.free(file);
    const file_z = try alloc.dupeZ(u8, file);
    defer alloc.free(file_z);
    const fd = std.c.open(file_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    _ = std.c.write(fd, content.ptr, content.len);
    _ = std.c.close(fd);
}

test "credentialsPathIn maps active and profile services" {
    const alloc = std.testing.allocator;
    const active = (try credentialsPathIn(alloc, "/h", CODE_SERVICE)).?;
    defer alloc.free(active);
    try std.testing.expectEqualStrings("/h/.claude/.credentials.json", active);

    const saved = (try credentialsPathIn(alloc, "/h", "csw-code-work")).?;
    defer alloc.free(saved);
    try std.testing.expectEqualStrings("/h/.claude.work/.credentials.json", saved);
}

test "credentialsPathIn rejects unknown services" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]const u8, null), try credentialsPathIn(alloc, "/h", "Claude Safe Storage"));
    try std.testing.expectEqual(@as(?[]const u8, null), try credentialsPathIn(alloc, "/h", "csw-code-"));
}

test "fileGetIn reads active profile credentials" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    const dir = try paths.claudeDirIn(alloc, base);
    defer alloc.free(dir);
    try writeCredentials(alloc, dir, "{\"claudeAiOauth\":{}}\n");

    const value = try fileGetIn(alloc, base, CODE_SERVICE);
    defer alloc.free(value);
    try std.testing.expectEqualStrings("{\"claudeAiOauth\":{}}", value);
}

test "fileGetIn reads saved profile credentials" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    const dir = try paths.profileDirIn(alloc, base, "work");
    defer alloc.free(dir);
    try writeCredentials(alloc, dir, "{\"a\":1}");

    const value = try fileGetIn(alloc, base, "csw-code-work");
    defer alloc.free(value);
    try std.testing.expectEqualStrings("{\"a\":1}", value);
}

test "fileGetIn fails on missing file, empty file or unknown service" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    try std.testing.expectError(error.KeychainNotFound, fileGetIn(alloc, base, CODE_SERVICE));
    try std.testing.expectError(error.KeychainNotFound, fileGetIn(alloc, base, "other"));

    const dir = try paths.claudeDirIn(alloc, base);
    defer alloc.free(dir);
    try writeCredentials(alloc, dir, "  \n");
    try std.testing.expectError(error.KeychainNotFound, fileGetIn(alloc, base, CODE_SERVICE));
}

test "fileGetIn follows the active profile symlink" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    const profile_dir = try paths.profileDirIn(alloc, base, "work");
    defer alloc.free(profile_dir);
    try writeCredentials(alloc, profile_dir, "{\"w\":true}");

    const link = try paths.claudeDirIn(alloc, base);
    defer alloc.free(link);
    const link_z = try alloc.dupeZ(u8, link);
    defer alloc.free(link_z);
    const target_z = try alloc.dupeZ(u8, profile_dir);
    defer alloc.free(target_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target_z, link_z));

    const value = try fileGetIn(alloc, base, CODE_SERVICE);
    defer alloc.free(value);
    try std.testing.expectEqualStrings("{\"w\":true}", value);
}

test "platform without keychain refuses writes and deletes" {
    if (platform.supports_keychain) return error.SkipZigTest;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    try std.testing.expectError(error.UnsupportedPlatform, set(std.testing.allocator, io, "s", "a", "v"));
    try std.testing.expectError(error.UnsupportedPlatform, delete(std.testing.allocator, io, "s"));
    const account = getAccount(std.testing.allocator, io, "s");
    defer std.testing.allocator.free(account);
    try std.testing.expectEqualStrings("user", account);
}

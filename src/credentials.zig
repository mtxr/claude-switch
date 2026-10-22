//! credentials.zig — Keychain credentials Claude Code keeps per CLAUDE_CONFIG_DIR

const std = @import("std");
const keychain = @import("keychain.zig");
const paths = @import("paths.zig");
const platform = @import("platform.zig");

const c = @import("c");

pub const DEFAULT_SERVICE = "Claude Code-credentials";
const SERVICE_PREFIX = "Claude Code-credentials-";
const LEGACY_PREFIX = "csw-code-";

/// Keychain service Claude Code uses for a config dir: the prefix plus the
/// first 8 hex chars of the SHA-256 of the absolute path. Caller frees.
pub fn serviceForDir(gpa: std.mem.Allocator, dir: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(dir, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..4].*, .lower);
    return std.fmt.allocPrint(gpa, SERVICE_PREFIX ++ "{s}", .{hex});
}

pub fn expiresAtMs(gpa: std.mem.Allocator, blob: []const u8) ?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, blob, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const oauth = parsed.value.object.get("claudeAiOauth") orelse return null;
    if (oauth != .object) return null;
    const expires = oauth.object.get("expiresAt") orelse return null;
    return if (expires == .integer) expires.integer else null;
}

/// Index of the blob whose OAuth token expires last; absent blobs are skipped
/// and a blob without a readable expiry ranks lowest.
pub fn freshest(gpa: std.mem.Allocator, blobs: []const ?[]const u8) ?usize {
    var best: ?usize = null;
    var best_expiry: i64 = 0;
    for (blobs, 0..) |maybe_blob, i| {
        const blob = maybe_blob orelse continue;
        const expiry = expiresAtMs(gpa, blob) orelse 0;
        if (best == null or expiry > best_expiry) {
            best = i;
            best_expiry = expiry;
        }
    }
    return best;
}

/// Keychain service Claude Code uses for the config dir of a profile.
pub fn profileService(gpa: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    const dir = try paths.profileDirIn(gpa, base, name);
    defer gpa.free(dir);
    return serviceForDir(gpa, dir);
}

fn legacyService(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, LEGACY_PREFIX ++ "{s}", .{name});
}

fn read(gpa: std.mem.Allocator, io: std.Io, service: []const u8) ?[]const u8 {
    return keychain.get(gpa, io, service) catch null;
}

fn copyEntry(gpa: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8, blob: []const u8) !void {
    const account = keychain.getAccount(gpa, io, from);
    defer gpa.free(account);
    try keychain.set(gpa, io, to, account, blob);
}

/// Converts a legacy `csw-code-<name>` entry into the per-dir entry (keeping
/// whichever token expires last) and deletes the legacy entry.
pub fn migrateLegacy(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8) !void {
    if (comptime !platform.supports_keychain) return;
    const legacy_service = try legacyService(gpa, name);
    defer gpa.free(legacy_service);
    const legacy = read(gpa, io, legacy_service) orelse return;
    defer gpa.free(legacy);

    const dir_service = try profileService(gpa, base, name);
    defer gpa.free(dir_service);
    const current = read(gpa, io, dir_service);
    defer if (current) |blob| gpa.free(blob);

    const blobs = [_]?[]const u8{ current, legacy };
    if (freshest(gpa, &blobs) == 1) try copyEntry(gpa, io, legacy_service, dir_service, legacy);
    keychain.delete(gpa, io, legacy_service) catch {};
}

/// Stores the freshest known login of a profile in its per-dir entry. The
/// `live` entry only counts when `include_live` is set. Returns false when no
/// login was found anywhere.
pub fn capture(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8, live: []const u8, include_live: bool) !bool {
    if (comptime !platform.supports_keychain) return false;
    try migrateLegacy(gpa, io, base, name);
    const dir_service = try profileService(gpa, base, name);
    defer gpa.free(dir_service);

    var blobs: [2]?[]const u8 = .{
        read(gpa, io, dir_service),
        if (include_live) read(gpa, io, live) else null,
    };
    defer for (blobs) |maybe_blob| if (maybe_blob) |blob| gpa.free(blob);

    const source = freshest(gpa, &blobs) orelse return false;
    if (source == 1) try copyEntry(gpa, io, live, dir_service, blobs[1].?);
    return true;
}

/// Puts the stored login of a profile in the `live` entry (what Claude Code
/// reads without CLAUDE_CONFIG_DIR). Returns false when the profile has none.
pub fn activate(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8, live: []const u8) !bool {
    if (comptime !platform.supports_keychain) return false;
    try migrateLegacy(gpa, io, base, name);
    const dir_service = try profileService(gpa, base, name);
    defer gpa.free(dir_service);

    const blob = read(gpa, io, dir_service) orelse return false;
    defer gpa.free(blob);
    try copyEntry(gpa, io, dir_service, live, blob);
    return true;
}

/// Stored login blob of a profile, or null. Caller frees.
pub fn readProfile(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8) !?[]const u8 {
    if (comptime !platform.supports_keychain) return null;
    try migrateLegacy(gpa, io, base, name);
    const dir_service = try profileService(gpa, base, name);
    defer gpa.free(dir_service);
    return read(gpa, io, dir_service);
}

pub fn forget(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8) !void {
    if (comptime !platform.supports_keychain) return;
    const dir_service = try profileService(gpa, base, name);
    defer gpa.free(dir_service);
    const legacy_service = try legacyService(gpa, name);
    defer gpa.free(legacy_service);
    keychain.delete(gpa, io, dir_service) catch {};
    keychain.delete(gpa, io, legacy_service) catch {};
}

test "serviceForDir matches the hash Claude Code uses" {
    const alloc = std.testing.allocator;
    const service = try serviceForDir(alloc, "/Users/m/.claude.me");
    defer alloc.free(service);
    try std.testing.expectEqualStrings("Claude Code-credentials-356779c5", service);
}

test "serviceForDir hashes the exact path text" {
    const alloc = std.testing.allocator;
    const a = try serviceForDir(alloc, "/Users/m/.claude.me");
    defer alloc.free(a);
    const b = try serviceForDir(alloc, "/Users/m/.claude.me/");
    defer alloc.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "expiresAtMs reads the oauth expiry" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?i64, 1234), expiresAtMs(alloc, "{\"claudeAiOauth\":{\"expiresAt\":1234}}"));
}

test "expiresAtMs returns null for malformed or missing data" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?i64, null), expiresAtMs(alloc, "not json"));
    try std.testing.expectEqual(@as(?i64, null), expiresAtMs(alloc, "[]"));
    try std.testing.expectEqual(@as(?i64, null), expiresAtMs(alloc, "{}"));
    try std.testing.expectEqual(@as(?i64, null), expiresAtMs(alloc, "{\"claudeAiOauth\":1}"));
    try std.testing.expectEqual(@as(?i64, null), expiresAtMs(alloc, "{\"claudeAiOauth\":{\"expiresAt\":\"x\"}}"));
}

test "freshest picks the latest expiry and skips absent blobs" {
    const alloc = std.testing.allocator;
    const older = "{\"claudeAiOauth\":{\"expiresAt\":100}}";
    const newer = "{\"claudeAiOauth\":{\"expiresAt\":200}}";
    try std.testing.expectEqual(@as(?usize, 1), freshest(alloc, &.{ older, newer }));
    try std.testing.expectEqual(@as(?usize, 0), freshest(alloc, &.{ newer, older }));
    try std.testing.expectEqual(@as(?usize, 1), freshest(alloc, &.{ null, older }));
    try std.testing.expectEqual(@as(?usize, 1), freshest(alloc, &.{ "garbage", older }));
    try std.testing.expectEqual(@as(?usize, 0), freshest(alloc, &.{ "garbage", "junk" }));
    try std.testing.expectEqual(@as(?usize, null), freshest(alloc, &.{ null, null }));
    try std.testing.expectEqual(@as(?usize, null), freshest(alloc, &.{}));
}

test "profileService hashes the profile config dir" {
    const alloc = std.testing.allocator;
    const service = try profileService(alloc, "/Users/m", "me");
    defer alloc.free(service);
    try std.testing.expectEqualStrings("Claude Code-credentials-356779c5", service);
}

const fixture_old = "{\"claudeAiOauth\":{\"expiresAt\":100}}";
const fixture_new = "{\"claudeAiOauth\":{\"expiresAt\":200}}";

const Sandbox = struct {
    base: []const u8,
    live: []const u8,
    dir_service: []const u8,
    legacy_service: []const u8,

    fn init(alloc: std.mem.Allocator, io: std.Io, tag: []const u8) !Sandbox {
        const stamp = c.time(null);
        const base = try std.fmt.allocPrint(alloc, "/tmp/csw-cred-test-{d}-{s}", .{ @as(i64, stamp), tag });
        const live = try std.fmt.allocPrint(alloc, "csw-test-{d}-{s}-live", .{ @as(i64, stamp), tag });
        const dir_service = try profileService(alloc, base, "p");
        const legacy_service = try legacyService(alloc, "p");
        const sandbox: Sandbox = .{ .base = base, .live = live, .dir_service = dir_service, .legacy_service = legacy_service };
        sandbox.wipe(alloc, io);
        return sandbox;
    }

    fn wipe(self: Sandbox, alloc: std.mem.Allocator, io: std.Io) void {
        for ([_][]const u8{ self.live, self.dir_service, self.legacy_service }) |service| keychain.delete(alloc, io, service) catch {};
    }

    fn deinit(self: Sandbox, alloc: std.mem.Allocator, io: std.Io) void {
        self.wipe(alloc, io);
        alloc.free(self.base);
        alloc.free(self.live);
        alloc.free(self.dir_service);
        alloc.free(self.legacy_service);
    }
};

fn put(alloc: std.mem.Allocator, io: std.Io, service: []const u8, blob: []const u8) !void {
    try keychain.set(alloc, io, service, "tester", blob);
}

fn expectEntry(alloc: std.mem.Allocator, io: std.Io, service: []const u8, expected: ?[]const u8) !void {
    const actual = read(alloc, io, service);
    defer if (actual) |blob| alloc.free(blob);
    if (expected) |want| {
        try std.testing.expectEqualStrings(want, actual.?);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), actual);
    }
}

fn sandboxIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.heap.page_allocator, .{});
}

test "migrateLegacy keeps the fresher legacy token and removes the legacy entry" {
    if (comptime !platform.supports_keychain) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = sandboxIo();
    defer tio.deinit();
    const io = tio.io();
    const sb = try Sandbox.init(alloc, io, "mig-new");
    defer sb.deinit(alloc, io);

    try put(alloc, io, sb.legacy_service, fixture_new);
    try put(alloc, io, sb.dir_service, fixture_old);
    try migrateLegacy(alloc, io, sb.base, "p");
    try expectEntry(alloc, io, sb.dir_service, fixture_new);
    try expectEntry(alloc, io, sb.legacy_service, null);
}

test "migrateLegacy keeps a fresher per-dir token and still removes the legacy entry" {
    if (comptime !platform.supports_keychain) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = sandboxIo();
    defer tio.deinit();
    const io = tio.io();
    const sb = try Sandbox.init(alloc, io, "mig-old");
    defer sb.deinit(alloc, io);

    try put(alloc, io, sb.legacy_service, fixture_old);
    try put(alloc, io, sb.dir_service, fixture_new);
    try migrateLegacy(alloc, io, sb.base, "p");
    try expectEntry(alloc, io, sb.dir_service, fixture_new);
    try expectEntry(alloc, io, sb.legacy_service, null);
}

test "migrateLegacy does nothing without a legacy entry" {
    if (comptime !platform.supports_keychain) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = sandboxIo();
    defer tio.deinit();
    const io = tio.io();
    const sb = try Sandbox.init(alloc, io, "mig-none");
    defer sb.deinit(alloc, io);

    try migrateLegacy(alloc, io, sb.base, "p");
    try expectEntry(alloc, io, sb.dir_service, null);
}

test "capture stores the live login only when it is allowed and fresher" {
    if (comptime !platform.supports_keychain) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = sandboxIo();
    defer tio.deinit();
    const io = tio.io();
    const sb = try Sandbox.init(alloc, io, "cap");
    defer sb.deinit(alloc, io);

    try std.testing.expect(!try capture(alloc, io, sb.base, "p", sb.live, true));

    try put(alloc, io, sb.live, fixture_new);
    try std.testing.expect(!try capture(alloc, io, sb.base, "p", sb.live, false));
    try expectEntry(alloc, io, sb.dir_service, null);

    try std.testing.expect(try capture(alloc, io, sb.base, "p", sb.live, true));
    try expectEntry(alloc, io, sb.dir_service, fixture_new);

    try put(alloc, io, sb.live, fixture_old);
    try std.testing.expect(try capture(alloc, io, sb.base, "p", sb.live, true));
    try expectEntry(alloc, io, sb.dir_service, fixture_new);
}

test "activate copies the profile login to the live entry" {
    if (comptime !platform.supports_keychain) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = sandboxIo();
    defer tio.deinit();
    const io = tio.io();
    const sb = try Sandbox.init(alloc, io, "act");
    defer sb.deinit(alloc, io);

    try std.testing.expect(!try activate(alloc, io, sb.base, "p", sb.live));
    try put(alloc, io, sb.legacy_service, fixture_new);
    try std.testing.expect(try activate(alloc, io, sb.base, "p", sb.live));
    try expectEntry(alloc, io, sb.live, fixture_new);
    try expectEntry(alloc, io, sb.dir_service, fixture_new);
}

test "readProfile returns the stored login or null" {
    if (comptime !platform.supports_keychain) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = sandboxIo();
    defer tio.deinit();
    const io = tio.io();
    const sb = try Sandbox.init(alloc, io, "rd");
    defer sb.deinit(alloc, io);

    try std.testing.expectEqual(@as(?[]const u8, null), try readProfile(alloc, io, sb.base, "p"));
    try put(alloc, io, sb.dir_service, fixture_old);
    const blob = (try readProfile(alloc, io, sb.base, "p")).?;
    defer alloc.free(blob);
    try std.testing.expectEqualStrings(fixture_old, blob);
}

test "forget removes the per-dir and legacy entries" {
    if (comptime !platform.supports_keychain) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = sandboxIo();
    defer tio.deinit();
    const io = tio.io();
    const sb = try Sandbox.init(alloc, io, "fg");
    defer sb.deinit(alloc, io);

    try put(alloc, io, sb.dir_service, fixture_old);
    try put(alloc, io, sb.legacy_service, fixture_old);
    try forget(alloc, io, sb.base, "p");
    try expectEntry(alloc, io, sb.dir_service, null);
    try expectEntry(alloc, io, sb.legacy_service, null);
}

test "keychain operations are no-ops without Keychain support" {
    if (comptime platform.supports_keychain) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = sandboxIo();
    defer tio.deinit();
    const io = tio.io();

    try migrateLegacy(alloc, io, "/nowhere", "p");
    try std.testing.expect(!try capture(alloc, io, "/nowhere", "p", DEFAULT_SERVICE, true));
    try std.testing.expect(!try activate(alloc, io, "/nowhere", "p", DEFAULT_SERVICE));
    try std.testing.expectEqual(@as(?[]const u8, null), try readProfile(alloc, io, "/nowhere", "p"));
    try forget(alloc, io, "/nowhere", "p");
}

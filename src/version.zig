//! version.zig — version comparison and update check cache

const std = @import("std");

pub const UpdateCache = struct {
    version: ?[]const u8,
    checked: i64,
};

pub fn parseSemver(v: []const u8) [3]u32 {
    var parts = std.mem.splitScalar(u8, v, '.');
    var result = [3]u32{ 0, 0, 0 };
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i >= 3) break;
        result[i] = std.fmt.parseInt(u32, part, 10) catch 0;
    }
    return result;
}

pub fn isNewerVersion(candidate: []const u8, current: []const u8) bool {
    const c = parseSemver(candidate);
    const cur = parseSemver(current);
    if (c[0] != cur[0]) return c[0] > cur[0];
    if (c[1] != cur[1]) return c[1] > cur[1];
    return c[2] > cur[2];
}

pub fn trimTag(tag: []const u8) []const u8 {
    return std.mem.trimStart(u8, tag, "v");
}

pub fn parseUpdateCache(gpa: std.mem.Allocator, bytes: []const u8) UpdateCache {
    const empty = UpdateCache{ .version = null, .checked = 0 };
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return empty;
    defer parsed.deinit();
    if (parsed.value != .object) return empty;
    var checked: i64 = 0;
    var version: ?[]const u8 = null;
    if (parsed.value.object.get("checked")) |v| {
        if (v == .integer) checked = v.integer;
    }
    if (parsed.value.object.get("latest")) |v| {
        if (v == .string) version = gpa.dupe(u8, v.string) catch null;
    }
    return .{ .version = version, .checked = checked };
}

pub fn formatUpdateCache(gpa: std.mem.Allocator, checked: i64, latest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{{\"checked\":{d},\"latest\":\"{s}\"}}\n", .{ checked, latest });
}

/// Extracts the version (without the "v" prefix) from a GitHub release response.
/// Returns error.ParseError if the body is not JSON and null if there is no textual tag_name.
pub fn latestFromRelease(gpa: std.mem.Allocator, body: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return error.ParseError;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const tag = parsed.value.object.get("tag_name") orelse return null;
    if (tag != .string) return null;
    return @as(?[]const u8, try gpa.dupe(u8, trimTag(tag.string)));
}

test "parseSemver reads three components" {
    try std.testing.expectEqual([3]u32{ 1, 2, 3 }, parseSemver("1.2.3"));
}

test "parseSemver tolerates incomplete and invalid input" {
    try std.testing.expectEqual([3]u32{ 1, 0, 0 }, parseSemver("1"));
    try std.testing.expectEqual([3]u32{ 0, 0, 0 }, parseSemver(""));
    try std.testing.expectEqual([3]u32{ 1, 0, 3 }, parseSemver("1.x.3"));
    try std.testing.expectEqual([3]u32{ 1, 2, 3 }, parseSemver("1.2.3.4"));
}

test "isNewerVersion compares major, minor and patch" {
    try std.testing.expect(isNewerVersion("2.0.0", "1.9.9"));
    try std.testing.expect(!isNewerVersion("1.9.9", "2.0.0"));
    try std.testing.expect(isNewerVersion("1.3.0", "1.2.9"));
    try std.testing.expect(!isNewerVersion("1.2.9", "1.3.0"));
    try std.testing.expect(isNewerVersion("1.2.4", "1.2.3"));
    try std.testing.expect(!isNewerVersion("1.2.3", "1.2.4"));
    try std.testing.expect(!isNewerVersion("1.2.3", "1.2.3"));
}

test "trimTag removes the v prefix" {
    try std.testing.expectEqualStrings("0.2.6", trimTag("v0.2.6"));
    try std.testing.expectEqualStrings("0.2.6", trimTag("0.2.6"));
}

test "parseUpdateCache reads version and timestamp" {
    const alloc = std.testing.allocator;
    const cache = parseUpdateCache(alloc, "{\"checked\":100,\"latest\":\"0.3.0\"}");
    defer if (cache.version) |v| alloc.free(v);
    try std.testing.expectEqual(@as(i64, 100), cache.checked);
    try std.testing.expectEqualStrings("0.3.0", cache.version.?);
}

test "parseUpdateCache ignores wrong types" {
    const alloc = std.testing.allocator;
    const cache = parseUpdateCache(alloc, "{\"checked\":\"x\",\"latest\":5}");
    try std.testing.expectEqual(@as(i64, 0), cache.checked);
    try std.testing.expectEqual(@as(?[]const u8, null), cache.version);
}

test "parseUpdateCache handles invalid and non-object JSON" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]const u8, null), parseUpdateCache(alloc, "nope").version);
    try std.testing.expectEqual(@as(?[]const u8, null), parseUpdateCache(alloc, "[1]").version);
}

test "formatUpdateCache round-trips with parseUpdateCache" {
    const alloc = std.testing.allocator;
    const text = try formatUpdateCache(alloc, 42, "1.0.0");
    defer alloc.free(text);
    const cache = parseUpdateCache(alloc, text);
    defer if (cache.version) |v| alloc.free(v);
    try std.testing.expectEqual(@as(i64, 42), cache.checked);
    try std.testing.expectEqualStrings("1.0.0", cache.version.?);
}

test "latestFromRelease extracts the tag without prefix" {
    const alloc = std.testing.allocator;
    const latest = try latestFromRelease(alloc, "{\"tag_name\":\"v1.2.3\"}");
    defer if (latest) |l| alloc.free(l);
    try std.testing.expectEqualStrings("1.2.3", latest.?);
}

test "latestFromRelease returns null without a valid tag" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]const u8, null), try latestFromRelease(alloc, "{}"));
    try std.testing.expectEqual(@as(?[]const u8, null), try latestFromRelease(alloc, "{\"tag_name\":1}"));
    try std.testing.expectEqual(@as(?[]const u8, null), try latestFromRelease(alloc, "[]"));
}

test "latestFromRelease fails on invalid JSON" {
    try std.testing.expectError(error.ParseError, latestFromRelease(std.testing.allocator, "garbage"));
}

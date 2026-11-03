//! paths.zig — filesystem path builders
//!
//! Functions that build paths take an allocator and return `[]const u8`; the caller frees them.

const std = @import("std");

/// Returns the user's HOME directory. Caller frees.
pub fn home(allocator: std.mem.Allocator) ![]const u8 {
    const val = std.c.getenv("HOME") orelse return error.HomeNotSet;
    return allocator.dupe(u8, std.mem.sliceTo(val, 0));
}

pub fn claudeJsonIn(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ base, ".claude.json" });
}

pub fn claudeDirIn(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ base, ".claude" });
}

/// Name of the config file Claude Code keeps inside a config dir.
pub const CONFIG_FILE = ".claude.json";

/// The profile's config file: `~/.claude.<name>/.claude.json`, the file Claude
/// Code reads and writes when CLAUDE_CONFIG_DIR is the profile directory.
pub fn profileJsonIn(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    const dirname = try std.fmt.allocPrint(allocator, ".claude.{s}", .{name});
    defer allocator.free(dirname);
    return std.fs.path.join(allocator, &.{ base, dirname, CONFIG_FILE });
}

/// Where versions before the layout change kept the profile config: `~/.claude.<name>.json`.
pub fn legacyProfileJsonIn(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    const filename = try std.fmt.allocPrint(allocator, ".claude.{s}.json", .{name});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ base, filename });
}

pub fn profileDirIn(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    const filename = try std.fmt.allocPrint(allocator, ".claude.{s}", .{name});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ base, filename });
}

pub fn desktopDirIn(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ base, "Library", "Application Support", "Claude" });
}

pub fn desktopProfileDirIn(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    const dirname = try std.fmt.allocPrint(allocator, "Claude.{s}", .{name});
    defer allocator.free(dirname);
    return std.fs.path.join(allocator, &.{ base, "Library", "Application Support", dirname });
}

test "home returns an absolute path" {
    const alloc = std.testing.allocator;
    const h = try home(alloc);
    defer alloc.free(h);
    try std.testing.expect(std.fs.path.isAbsolute(h));
}

test "paths are relative to the base" {
    const alloc = std.testing.allocator;
    const base = "/tmp/testbase";

    const cj = try claudeJsonIn(alloc, base);
    defer alloc.free(cj);
    try std.testing.expectEqualStrings("/tmp/testbase/.claude.json", cj);

    const cd = try claudeDirIn(alloc, base);
    defer alloc.free(cd);
    try std.testing.expectEqualStrings("/tmp/testbase/.claude", cd);

    const pj = try profileJsonIn(alloc, base, "work");
    defer alloc.free(pj);
    try std.testing.expectEqualStrings("/tmp/testbase/.claude.work/.claude.json", pj);

    const lj = try legacyProfileJsonIn(alloc, base, "work");
    defer alloc.free(lj);
    try std.testing.expectEqualStrings("/tmp/testbase/.claude.work.json", lj);

    const pd = try profileDirIn(alloc, base, "work");
    defer alloc.free(pd);
    try std.testing.expectEqualStrings("/tmp/testbase/.claude.work", pd);

    const dd = try desktopDirIn(alloc, base);
    defer alloc.free(dd);
    try std.testing.expectEqualStrings("/tmp/testbase/Library/Application Support/Claude", dd);

    const dpd = try desktopProfileDirIn(alloc, base, "work");
    defer alloc.free(dpd);
    try std.testing.expectEqualStrings("/tmp/testbase/Library/Application Support/Claude.work", dpd);
}

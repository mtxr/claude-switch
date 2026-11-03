//! testutil.zig — helpers shared by tests; only referenced from test blocks

const std = @import("std");
const desktop = @import("desktop.zig");
const paths = @import("paths.zig");

var counter = std.atomic.Value(u32).init(0);

/// Process id, nanosecond clock and a per-process counter joined into a token
/// that differs between concurrent runs and between calls in one run. Caller frees.
pub fn uniqueToken(alloc: std.mem.Allocator) ![]u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const nanos = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    const n = counter.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(alloc, "{x}-{x}-{x}", .{ @as(u32, @intCast(std.c.getpid())), nanos, n });
}

/// Creates profile `name` under `base` the way csw lays it out: a directory
/// holding its own `.claude.json` with `content`.
pub fn addProfile(alloc: std.mem.Allocator, base: []const u8, name: []const u8, content: []const u8) !void {
    const dir = try paths.profileDirIn(alloc, base, name);
    defer alloc.free(dir);
    try desktop.mkdirAllC(alloc, dir);
    const json = try paths.profileJsonIn(alloc, base, name);
    defer alloc.free(json);
    const json_z = try alloc.dupeSentinel(u8, json, 0);
    defer alloc.free(json_z);
    const fd = std.c.open(json_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.CreateFileFailed;
    defer _ = std.c.close(fd);
    if (content.len > 0) _ = std.c.write(fd, content.ptr, content.len);
}

test "uniqueToken differs between calls" {
    const alloc = std.testing.allocator;
    const a = try uniqueToken(alloc);
    defer alloc.free(a);
    const b = try uniqueToken(alloc);
    defer alloc.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

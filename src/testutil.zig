//! testutil.zig — helpers shared by tests; only referenced from test blocks

const std = @import("std");

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

test "uniqueToken differs between calls" {
    const alloc = std.testing.allocator;
    const a = try uniqueToken(alloc);
    defer alloc.free(a);
    const b = try uniqueToken(alloc);
    defer alloc.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

//! display.zig — formatted terminal output

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("time.h");
});

fn writeStdout(bytes: []const u8) void {
    const fd = if (builtin.is_test) std.posix.STDERR_FILENO else std.posix.STDOUT_FILENO;
    _ = std.c.write(fd, bytes.ptr, bytes.len);
}

fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDERR_FILENO, bytes.ptr, bytes.len);
}

fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdout(s);
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStderr(s);
}

pub fn info(msg: []const u8) void {
    printOut("➜   {s}\n", .{msg});
}

pub fn ok(msg: []const u8) void {
    printOut("✅  {s}\n", .{msg});
}

pub fn err(msg: []const u8) void {
    printErr("❌  {s}\n", .{msg});
}

pub fn row(label: []const u8, value: []const u8) void {
    printOut("  {s:<16} {s}\n", .{ label, value });
}

pub fn section(title: []const u8) void {
    printOut("\n  {s}\n", .{title});
    var sep_buf: [256]u8 = undefined;
    const sep = "─";
    const sep_bytes = sep.len;
    const count = @min(title.len + 20, sep_buf.len / sep_bytes);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(sep_buf[i * sep_bytes ..][0..sep_bytes], sep);
    }
    printOut("  {s}\n", .{sep_buf[0 .. count * sep_bytes]});
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    printOut(fmt, args);
}

/// Formats an expiry in ms as a human-readable string. Caller frees.
pub fn fmtExpiry(allocator: std.mem.Allocator, expires_ms: i64) ![]const u8 {
    if (expires_ms == 0) return allocator.dupe(u8, "?");

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const now_ms = @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    const remaining_hours = @divTrunc(expires_ms - now_ms, 1000 * 3600);
    const expires_sec: c.time_t = @intCast(@divTrunc(expires_ms, 1000));
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&expires_sec, &tm);

    var date_buf: [64]u8 = undefined;
    const n = c.strftime(&date_buf, date_buf.len, "%d %b %Y %H:%M %Z", &tm);
    const date_str = date_buf[0..n];

    if (remaining_hours <= 0) {
        return std.fmt.allocPrint(allocator, "{s}  ⚠️  EXPIRED", .{date_str});
    } else if (remaining_hours < 24) {
        return std.fmt.allocPrint(allocator, "{s}  ({d}h remaining)", .{ date_str, remaining_hours });
    } else {
        return std.fmt.allocPrint(allocator, "{s}  ({d}d remaining)", .{ date_str, @divTrunc(remaining_hours, 24) });
    }
}

/// Formats JSON scopes as a string. Caller frees.
pub fn fmtScopes(allocator: std.mem.Allocator, scopes: []const std.json.Value) ![]const u8 {
    if (scopes.len == 0) return allocator.dupe(u8, "?");

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    for (scopes) |scope| {
        if (scope != .string) continue;
        const s = scope.string;
        const stripped = if (std.mem.startsWith(u8, s, "user:")) s["user:".len..] else s;
        try parts.append(allocator, stripped);
    }

    if (parts.items.len == 0) return allocator.dupe(u8, "?");
    return std.mem.join(allocator, ", ", parts.items);
}

test "fmtExpiry returns ? for zero" {
    const alloc = std.testing.allocator;
    const result = try fmtExpiry(alloc, 0);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("?", result);
}

test "fmtExpiry in the past shows EXPIRED" {
    const alloc = std.testing.allocator;
    const past_ms = (c.time(null) - 3600) * 1000;
    const result = try fmtExpiry(alloc, past_ms);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "EXPIRED") != null);
}

test "fmtExpiry within 24h shows hours" {
    const alloc = std.testing.allocator;
    const soon_ms = (c.time(null) + 12 * 3600) * 1000;
    const result = try fmtExpiry(alloc, soon_ms);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "h remaining") != null);
}

test "fmtExpiry beyond 24h shows days" {
    const alloc = std.testing.allocator;
    const future_ms = (c.time(null) + 3 * 24 * 3600) * 1000;
    const result = try fmtExpiry(alloc, future_ms);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "d remaining") != null);
}

test "fmtScopes empty returns ?" {
    const alloc = std.testing.allocator;
    const result = try fmtScopes(alloc, &.{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("?", result);
}

test "fmtScopes strips user: prefix" {
    const alloc = std.testing.allocator;
    const scopes = [_]std.json.Value{
        .{ .string = "user:inference" },
        .{ .string = "user:profile" },
    };
    const result = try fmtScopes(alloc, &scopes);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("inference, profile", result);
}

test "fmtScopes ignores non-strings" {
    const alloc = std.testing.allocator;
    const scopes = [_]std.json.Value{
        .{ .string = "user:inference" },
        .{ .integer = 42 },
        .null,
    };
    const result = try fmtScopes(alloc, &scopes);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("inference", result);
}

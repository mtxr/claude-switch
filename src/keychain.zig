//! keychain.zig — acesso ao Keychain do macOS via CLI `security`
//!
//! Zig 0.16: std.process.run agora requer (gpa, io, options).
//! O campo term passou de .Exited para .exited (snake_case).

const std = @import("std");
const c_time = @cImport(@cInclude("time.h"));

pub fn get(gpa: std.mem.Allocator, io: std.Io, service: []const u8) ![]const u8 {
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
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "security", "delete-generic-password", "-s", service },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

// ── Tests ─────────────────────────────────────────────────────────────────────
// Esses testes requerem Keychain real — rodam no macOS com permissão.

test "get em serviço inexistente retorna erro" {
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    const svc = try std.fmt.allocPrint(alloc, "csw-test-{d}-missing", .{@as(i64, c_time.time(null))});
    defer alloc.free(svc);
    delete(alloc, io, svc) catch {};
    try std.testing.expectError(error.KeychainNotFound, get(alloc, io, svc));
}

test "set e get round-trip" {
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

test "set sobrescreve entrada existente" {
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

test "delete de entrada inexistente não falha" {
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    const svc = try std.fmt.allocPrint(alloc, "csw-test-{d}-del", .{@as(i64, c_time.time(null))});
    defer alloc.free(svc);
    delete(alloc, io, svc) catch {};
    try delete(alloc, io, svc);
}

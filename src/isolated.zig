//! isolated.zig — open a profile's own Claude Desktop next to the main one

const std = @import("std");
const desktop = @import("desktop.zig");
const display = @import("display.zig");
const paths = @import("paths.zig");
const platform = @import("platform.zig");
const run = @import("run.zig");

pub fn cmdDesktop(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    if (comptime !platform.supports_desktop) {
        platform.notSupported("Claude Desktop");
        return error.UnsupportedPlatform;
    }
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const had_data = desktop.hasDataIn(gpa, h, name);
    const dir = prepareIn(gpa, h, name) catch |e| return reportError(gpa, name, e);
    defer gpa.free(dir);

    if (desktop.isolatedRunning(gpa, io, dir)) {
        const msg = try std.fmt.allocPrint(gpa, "Claude Desktop for '{s}' is already open", .{name});
        defer gpa.free(msg);
        display.info(msg);
        return;
    }
    if (!had_data) display.info(FIRST_RUN_HINT);

    desktop.launchIsolated(gpa, io, dir) catch |e| return reportError(gpa, name, e);
    const msg = try std.fmt.allocPrint(gpa, "Claude Desktop opened for '{s}'", .{name});
    defer gpa.free(msg);
    display.ok(msg);
}

const FIRST_RUN_HINT = "First time for this profile: sign in inside that window. Login links open in your main Claude Desktop; copy the code from the browser and paste it into this one.";

/// Validates the profile and returns its Desktop data dir (caller frees).
pub fn prepareIn(gpa: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (!run.isValidName(name)) return error.InvalidProfileName;
    const p_json = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(p_json);
    if (!desktop.pathExists(gpa, p_json) and !desktop.hasDataIn(gpa, base, name)) return error.ProfileNotFound;
    return desktop.prepareIsolatedIn(gpa, base, name);
}

/// Refuses an operation that would move or delete the data dir of a profile
/// whose isolated Desktop is open.
pub fn refuseWhenOpen(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8) !void {
    if (comptime !platform.supports_desktop) return;
    const dir = try paths.desktopProfileDirIn(gpa, base, name);
    defer gpa.free(dir);
    if (!desktop.isolatedRunning(gpa, io, dir)) return;
    const msg = try openMessage(gpa, name);
    defer gpa.free(msg);
    display.err(msg);
    return error.DesktopInUse;
}

pub fn openMessage(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "Claude Desktop for '{s}' is open (csw desktop {s}). Quit it first.", .{ name, name });
}

pub fn errorMessage(gpa: std.mem.Allocator, name: []const u8, e: anyerror) ![]u8 {
    return switch (e) {
        error.InvalidProfileName => std.fmt.allocPrint(gpa, "Invalid profile name '{s}'", .{name}),
        error.ProfileNotFound => std.fmt.allocPrint(gpa, "Profile '{s}' not found. Use: csw new {s}", .{ name, name }),
        error.ProfileOwnsMainDesktop => std.fmt.allocPrint(gpa, "'{s}' owns the main Claude Desktop. Open Claude normally, or run: csw use <other> --desktop", .{name}),
        error.LaunchFailed => std.fmt.allocPrint(gpa, "Could not open Claude Desktop for '{s}'. Is Claude installed in /Applications?", .{name}),
        else => std.fmt.allocPrint(gpa, "Could not open Claude Desktop for '{s}': {s}", .{ name, @errorName(e) }),
    };
}

fn reportError(gpa: std.mem.Allocator, name: []const u8, e: anyerror) anyerror {
    const msg = errorMessage(gpa, name, e) catch return e;
    defer gpa.free(msg);
    display.err(msg);
    return e;
}

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

test "prepareIn validates the name and the profile" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    try std.testing.expectError(error.InvalidProfileName, prepareIn(alloc, base, "a/b"));
    try std.testing.expectError(error.ProfileNotFound, prepareIn(alloc, base, "work"));

    const p_json = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(p_json);
    try touch(alloc, p_json);
    const dir = try prepareIn(alloc, base, "work");
    defer alloc.free(dir);
    try std.testing.expect(desktop.pathExists(alloc, dir));
}

test "prepareIn accepts a Desktop-only profile" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    const stored = try paths.desktopProfileDirIn(alloc, base, "oss");
    defer alloc.free(stored);
    try desktop.mkdirAllC(alloc, stored);
    const marker = try std.fs.path.join(alloc, &.{ stored, "Cookies" });
    defer alloc.free(marker);
    try touch(alloc, marker);
    const dir = try prepareIn(alloc, base, "oss");
    defer alloc.free(dir);
    try std.testing.expectEqualStrings(stored, dir);
}

test "messages name the profile and the way out" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { e: anyerror, needle: []const u8 }{
        .{ .e = error.InvalidProfileName, .needle = "Invalid profile name 'work'" },
        .{ .e = error.ProfileNotFound, .needle = "csw new work" },
        .{ .e = error.ProfileOwnsMainDesktop, .needle = "owns the main Claude Desktop" },
        .{ .e = error.LaunchFailed, .needle = "/Applications" },
        .{ .e = error.OutOfMemory, .needle = "OutOfMemory" },
    };
    for (cases) |case| {
        const msg = try errorMessage(alloc, "work", case.e);
        defer alloc.free(msg);
        try std.testing.expect(std.mem.indexOf(u8, msg, case.needle) != null);
    }
    const open_msg = try openMessage(alloc, "work");
    defer alloc.free(open_msg);
    try std.testing.expect(std.mem.indexOf(u8, open_msg, "csw desktop work") != null);
}

test "desktop is inert without support" {
    if (platform.supports_desktop) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    try std.testing.expectError(error.UnsupportedPlatform, cmdDesktop(alloc, io, "work"));
    try refuseWhenOpen(alloc, io, "/nonexistent", "work");
}

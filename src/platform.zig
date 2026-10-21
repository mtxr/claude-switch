//! platform.zig — per-OS capabilities and release asset selection

const std = @import("std");
const builtin = @import("builtin");
const display = @import("display.zig");

pub const is_macos = builtin.os.tag == .macos;
pub const supports_keychain = is_macos;
pub const supports_desktop = is_macos;

pub const picker_install_hint = if (is_macos) "brew install sk" else "your package manager (sk or fzf)";

pub fn notSupported(feature: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} is not supported on {s}", .{ feature, @tagName(builtin.os.tag) }) catch return;
    display.err(msg);
}

pub fn releaseAssetFor(buf: []u8, arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag) ![]const u8 {
    const arch_name = switch (arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return error.UnsupportedPlatform,
    };
    const target = switch (os) {
        .macos => "apple-darwin",
        .linux => "unknown-linux-musl",
        else => return error.UnsupportedPlatform,
    };
    return std.fmt.bufPrint(buf, "csw-{s}-{s}", .{ arch_name, target });
}

pub fn releaseAsset(buf: []u8) ![]const u8 {
    return releaseAssetFor(buf, builtin.cpu.arch, builtin.os.tag);
}

pub fn executablePath(buf: []u8) ?[]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            var size: u32 = @intCast(buf.len);
            if (std.c._NSGetExecutablePath(buf.ptr, &size) != 0) return null;
            return std.mem.sliceTo(buf, 0);
        },
        .linux => {
            const n = std.c.readlink("/proc/self/exe", buf.ptr, buf.len);
            if (n <= 0) return null;
            return buf[0..@intCast(n)];
        },
        else => return null,
    }
}

test "releaseAssetFor keeps macOS names" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("csw-aarch64-apple-darwin", try releaseAssetFor(&buf, .aarch64, .macos));
    try std.testing.expectEqualStrings("csw-x86_64-apple-darwin", try releaseAssetFor(&buf, .x86_64, .macos));
}

test "releaseAssetFor selects Linux assets" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("csw-aarch64-unknown-linux-musl", try releaseAssetFor(&buf, .aarch64, .linux));
    try std.testing.expectEqualStrings("csw-x86_64-unknown-linux-musl", try releaseAssetFor(&buf, .x86_64, .linux));
}

test "releaseAssetFor rejects unknown platforms" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.UnsupportedPlatform, releaseAssetFor(&buf, .riscv64, .linux));
    try std.testing.expectError(error.UnsupportedPlatform, releaseAssetFor(&buf, .x86_64, .windows));
}

test "releaseAssetFor fails with a small buffer" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, releaseAssetFor(&buf, .x86_64, .linux));
}

test "releaseAsset matches the host" {
    var buf: [64]u8 = undefined;
    const name = try releaseAsset(&buf);
    try std.testing.expect(std.mem.startsWith(u8, name, "csw-"));
}

test "executablePath resolves the test binary" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = executablePath(&buf) orelse return error.SkipZigTest;
    try std.testing.expect(std.fs.path.isAbsolute(path));
}

test "picker_install_hint is not empty" {
    try std.testing.expect(picker_install_hint.len > 0);
}

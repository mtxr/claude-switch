//! update.zig — checksum-verified, atomic self-update and install-kind detection

const std = @import("std");
const channel = @import("channel.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const MAX_SUMS_BYTES = 64 * 1024;
const TMP_BINARY_SUFFIX = "_update_tmp";
const TMP_SUMS_SUFFIX = "_update_sums";
const TMP_COMMIT_SUFFIX = "_update_commit";
const TMP_EDGE_SUMS_SUFFIX = "_update_edge_sums";

pub const InstallKind = enum { standalone, homebrew, nix, system };

pub const Download = *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io, url: []const u8, dest: []const u8) anyerror!void;

pub const Transport = struct {
    ctx: ?*anyopaque = null,
    download: Download,
};

pub const UpdateError = error{
    DownloadFailed,
    ChecksumsUnavailable,
    ChecksumMissing,
    ChecksumMismatch,
    ReplaceFailed,
    EdgeCommitUnavailable,
    EdgeCommitInvalid,
};

pub const EdgeStatus = enum { current, updated };

pub const EdgeResult = struct {
    status: EdgeStatus,
    commit: [channel.EDGE_COMMIT_LEN]u8,
};

pub fn detectInstall(exe_path: []const u8) InstallKind {
    const homebrew_roots = [_][]const u8{ "/opt/homebrew/", "/home/linuxbrew/.linuxbrew/" };
    for (homebrew_roots) |root| {
        if (std.mem.startsWith(u8, exe_path, root)) return .homebrew;
    }
    if (std.mem.indexOf(u8, exe_path, "/Cellar/") != null) return .homebrew;
    if (std.mem.startsWith(u8, exe_path, "/nix/store/")) return .nix;
    const system_roots = [_][]const u8{ "/usr/bin/", "/usr/sbin/", "/bin/", "/sbin/" };
    for (system_roots) |root| {
        if (std.mem.startsWith(u8, exe_path, root)) return .system;
    }
    return .standalone;
}

pub fn upgradeCommand(kind: InstallKind) []const u8 {
    return switch (kind) {
        .standalone => "csw update",
        .homebrew => "brew upgrade csw",
        .nix => "nix profile upgrade csw (or update your flake input)",
        .system => "your package manager (apt, dnf or pacman)",
    };
}

/// Resolves symlinks so a Homebrew or Nix link is judged by where it points and
/// a symlinked standalone install is replaced at its real location.
pub fn resolveExecutable(buf: []u8, exe_path: []const u8) []const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (exe_path.len >= path_buf.len) return exe_path;
    @memcpy(path_buf[0..exe_path.len], exe_path);
    path_buf[exe_path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.c.realpath(path_z, &resolved) orelse return exe_path;
    const real_slice = std.mem.sliceTo(real, 0);
    if (real_slice.len > buf.len) return exe_path;
    @memcpy(buf[0..real_slice.len], real_slice);
    return buf[0..real_slice.len];
}

pub fn managedMessage(gpa: std.mem.Allocator, kind: InstallKind) ![]u8 {
    const manager = switch (kind) {
        .standalone => return gpa.dupe(u8, ""),
        .homebrew => "Homebrew",
        .nix => "Nix",
        .system => "a system package",
    };
    return std.fmt.allocPrint(gpa, "csw is managed by {s}; update with: {s}", .{ manager, upgradeCommand(kind) });
}

pub const EDGE_INSTALL_COMMAND = "curl -fsSL https://raw.githubusercontent.com/mtxr/claude-switch/main/install.sh | CSW_CHANNEL=edge bash";

pub fn managedEdgeMessage(gpa: std.mem.Allocator, kind: InstallKind) ![]u8 {
    const manager = switch (kind) {
        .standalone => return gpa.dupe(u8, ""),
        .homebrew => "Homebrew",
        .nix => "Nix",
        .system => "a system package",
    };
    const alternative = switch (kind) {
        .standalone => unreachable,
        .homebrew => "Uninstall it first (brew uninstall csw), then run:",
        .nix => "`nix run github:mtxr/claude-switch` already follows main. To install the edge binary instead, remove the Nix one first, then run:",
        .system => "Remove the package first with your package manager, then run:",
    };
    return std.fmt.allocPrint(
        gpa,
        "The edge channel is only available for standalone installs (install.sh or a downloaded binary).\n  This csw is managed by {s}, so it was left untouched. {s}\n  {s}",
        .{ manager, alternative, EDGE_INSTALL_COMMAND },
    );
}

pub fn updateNotice(gpa: std.mem.Allocator, current: []const u8, latest: []const u8, kind: InstallKind) ![]u8 {
    return std.fmt.allocPrint(gpa, "Update available: v{s} → v{s}  (run: {s})", .{ current, latest, upgradeCommand(kind) });
}

fn isHexDigest(text: []const u8) bool {
    if (text.len != Sha256.digest_length * 2) return false;
    for (text) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

/// Digest listed for `asset` in a `sha256sum`-style file (`<hex>  <name>` or
/// `<hex> *<name>`), or null when the asset is absent or the line is malformed.
pub fn expectedDigest(sums: []const u8, asset: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const split = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const digest = line[0..split];
        const name = std.mem.trimStart(u8, std.mem.trim(u8, line[split..], " \t"), "*");
        if (!std.mem.eql(u8, name, asset)) continue;
        return if (isHexDigest(digest)) digest else null;
    }
    return null;
}

pub fn digestMatches(expected: []const u8, actual: []const u8) bool {
    return std.ascii.eqlIgnoreCase(expected, actual);
}

pub fn fileDigestHex(path: []const u8) ![Sha256.digest_length * 2]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    const fd = std.c.open(path_z, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    var hasher = Sha256.init(.{});
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        hasher.update(chunk[0..@intCast(n)]);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn readSmallFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);
    const fd = std.c.open(path_z, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (content.items.len < MAX_SUMS_BYTES) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        try content.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    return content.toOwnedSlice(gpa);
}

fn removeFile(gpa: std.mem.Allocator, path: []const u8) void {
    const path_z = gpa.dupeSentinel(u8, path, 0) catch return;
    defer gpa.free(path_z);
    _ = std.c.unlink(path_z);
}

pub fn curlDownload(ctx: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io, url: []const u8, dest: []const u8) anyerror!void {
    _ = ctx;
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "curl", "-L", "--fail", "-s", "-o", dest, url },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.DownloadFailed;
}

/// Downloads the asset and the release SHA256SUMS next to `exe_path`, verifies
/// the digest and only then renames the new binary over the old one. Any
/// failure leaves the installed binary untouched and removes the temp files.
pub fn applyUpdate(gpa: std.mem.Allocator, io: std.Io, transport: Transport, exe_path: []const u8, base_url: []const u8, asset: []const u8) !void {
    const tmp_binary = try std.fmt.allocPrint(gpa, "{s}" ++ TMP_BINARY_SUFFIX, .{exe_path});
    defer gpa.free(tmp_binary);
    const tmp_sums = try std.fmt.allocPrint(gpa, "{s}" ++ TMP_SUMS_SUFFIX, .{exe_path});
    defer gpa.free(tmp_sums);
    defer removeFile(gpa, tmp_sums);
    errdefer removeFile(gpa, tmp_binary);

    const binary_url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_url, asset });
    defer gpa.free(binary_url);
    const sums_url = try std.fmt.allocPrint(gpa, "{s}/SHA256SUMS", .{base_url});
    defer gpa.free(sums_url);

    transport.download(transport.ctx, gpa, io, binary_url, tmp_binary) catch return UpdateError.DownloadFailed;
    transport.download(transport.ctx, gpa, io, sums_url, tmp_sums) catch return UpdateError.ChecksumsUnavailable;

    const sums = readSmallFile(gpa, tmp_sums) catch return UpdateError.ChecksumsUnavailable;
    defer gpa.free(sums);
    const expected = expectedDigest(sums, asset) orelse return UpdateError.ChecksumMissing;
    const actual = fileDigestHex(tmp_binary) catch return UpdateError.DownloadFailed;
    if (!digestMatches(expected, &actual)) return UpdateError.ChecksumMismatch;

    const tmp_binary_z = try gpa.dupeSentinel(u8, tmp_binary, 0);
    defer gpa.free(tmp_binary_z);
    const exe_path_z = try gpa.dupeSentinel(u8, exe_path, 0);
    defer gpa.free(exe_path_z);
    if (std.c.chmod(tmp_binary_z, 0o755) != 0) return UpdateError.ReplaceFailed;
    if (std.c.rename(tmp_binary_z, exe_path_z) != 0) return UpdateError.ReplaceFailed;
}

/// Reads the EDGE_COMMIT asset, authenticated against the release SHA256SUMS,
/// and applies the edge binary unless `embedded` already is that commit.
pub fn applyEdgeUpdate(gpa: std.mem.Allocator, io: std.Io, transport: Transport, exe_path: []const u8, base_url: []const u8, asset: []const u8, embedded: []const u8) !EdgeResult {
    const tmp_commit = try std.fmt.allocPrint(gpa, "{s}" ++ TMP_COMMIT_SUFFIX, .{exe_path});
    defer gpa.free(tmp_commit);
    const tmp_sums = try std.fmt.allocPrint(gpa, "{s}" ++ TMP_EDGE_SUMS_SUFFIX, .{exe_path});
    defer gpa.free(tmp_sums);
    defer removeFile(gpa, tmp_commit);
    defer removeFile(gpa, tmp_sums);

    const commit_url = try std.fmt.allocPrint(gpa, "{s}/" ++ channel.EDGE_COMMIT_ASSET, .{base_url});
    defer gpa.free(commit_url);
    const sums_url = try std.fmt.allocPrint(gpa, "{s}/SHA256SUMS", .{base_url});
    defer gpa.free(sums_url);

    transport.download(transport.ctx, gpa, io, commit_url, tmp_commit) catch return UpdateError.EdgeCommitUnavailable;
    transport.download(transport.ctx, gpa, io, sums_url, tmp_sums) catch return UpdateError.ChecksumsUnavailable;

    const sums = readSmallFile(gpa, tmp_sums) catch return UpdateError.ChecksumsUnavailable;
    defer gpa.free(sums);
    const expected = expectedDigest(sums, channel.EDGE_COMMIT_ASSET) orelse return UpdateError.ChecksumMissing;
    const actual = fileDigestHex(tmp_commit) catch return UpdateError.EdgeCommitUnavailable;
    if (!digestMatches(expected, &actual)) return UpdateError.ChecksumMismatch;

    const content = readSmallFile(gpa, tmp_commit) catch return UpdateError.EdgeCommitUnavailable;
    defer gpa.free(content);
    const commit = channel.parseEdgeCommit(content) orelse return UpdateError.EdgeCommitInvalid;

    var result: EdgeResult = .{ .status = .current, .commit = undefined };
    _ = std.ascii.lowerString(&result.commit, commit);
    if (channel.sameCommit(embedded, commit)) return result;

    try applyUpdate(gpa, io, transport, exe_path, base_url, asset);
    result.status = .updated;
    return result;
}

test "detectInstall recognises Homebrew, Nix and system paths" {
    try std.testing.expectEqual(InstallKind.homebrew, detectInstall("/opt/homebrew/bin/csw"));
    try std.testing.expectEqual(InstallKind.homebrew, detectInstall("/opt/homebrew/Cellar/csw/1.0.0/bin/csw"));
    try std.testing.expectEqual(InstallKind.homebrew, detectInstall("/usr/local/Cellar/csw/1.0.0/bin/csw"));
    try std.testing.expectEqual(InstallKind.homebrew, detectInstall("/home/linuxbrew/.linuxbrew/bin/csw"));
    try std.testing.expectEqual(InstallKind.nix, detectInstall("/nix/store/abc-csw-1.0.0/bin/csw"));
    try std.testing.expectEqual(InstallKind.system, detectInstall("/usr/bin/csw"));
    try std.testing.expectEqual(InstallKind.system, detectInstall("/usr/sbin/csw"));
    try std.testing.expectEqual(InstallKind.system, detectInstall("/bin/csw"));
    try std.testing.expectEqual(InstallKind.system, detectInstall("/sbin/csw"));
}

test "detectInstall treats user and manual installs as standalone" {
    try std.testing.expectEqual(InstallKind.standalone, detectInstall("/Users/m/.local/bin/csw"));
    try std.testing.expectEqual(InstallKind.standalone, detectInstall("/usr/local/bin/csw"));
    try std.testing.expectEqual(InstallKind.standalone, detectInstall("/home/u/bin/csw"));
    try std.testing.expectEqual(InstallKind.standalone, detectInstall("/opt/homebrewed/csw"));
}

test "upgradeCommand names the right tool for each install kind" {
    try std.testing.expectEqualStrings("csw update", upgradeCommand(.standalone));
    try std.testing.expectEqualStrings("brew upgrade csw", upgradeCommand(.homebrew));
    try std.testing.expect(std.mem.indexOf(u8, upgradeCommand(.nix), "nix profile upgrade") != null);
    try std.testing.expect(std.mem.indexOf(u8, upgradeCommand(.system), "apt") != null);
}

test "managedMessage is empty for standalone and explicit otherwise" {
    const alloc = std.testing.allocator;
    const standalone = try managedMessage(alloc, .standalone);
    defer alloc.free(standalone);
    try std.testing.expectEqualStrings("", standalone);

    const brew = try managedMessage(alloc, .homebrew);
    defer alloc.free(brew);
    try std.testing.expectEqualStrings("csw is managed by Homebrew; update with: brew upgrade csw", brew);

    const nix = try managedMessage(alloc, .nix);
    defer alloc.free(nix);
    try std.testing.expect(std.mem.startsWith(u8, nix, "csw is managed by Nix;"));

    const system = try managedMessage(alloc, .system);
    defer alloc.free(system);
    try std.testing.expect(std.mem.startsWith(u8, system, "csw is managed by a system package;"));
}

test "managedEdgeMessage explains the edge channel for every managed install" {
    const alloc = std.testing.allocator;
    const standalone = try managedEdgeMessage(alloc, .standalone);
    defer alloc.free(standalone);
    try std.testing.expectEqualStrings("", standalone);

    const kinds = [_]InstallKind{ .homebrew, .nix, .system };
    const managers = [_][]const u8{ "Homebrew", "Nix", "a system package" };
    for (kinds, managers) |kind, manager| {
        const msg = try managedEdgeMessage(alloc, kind);
        defer alloc.free(msg);
        try std.testing.expect(std.mem.indexOf(u8, msg, "only available for standalone installs") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, manager) != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "left untouched") != null);
        try std.testing.expect(std.mem.endsWith(u8, msg, EDGE_INSTALL_COMMAND));
    }

    const brew = try managedEdgeMessage(alloc, .homebrew);
    defer alloc.free(brew);
    try std.testing.expect(std.mem.indexOf(u8, brew, "brew uninstall csw") != null);
    const nix = try managedEdgeMessage(alloc, .nix);
    defer alloc.free(nix);
    try std.testing.expect(std.mem.indexOf(u8, nix, "nix run github:mtxr/claude-switch") != null);
    const system = try managedEdgeMessage(alloc, .system);
    defer alloc.free(system);
    try std.testing.expect(std.mem.indexOf(u8, system, "your package manager") != null);
}

test "updateNotice suggests the command for the install kind" {
    const alloc = std.testing.allocator;
    const standalone = try updateNotice(alloc, "1.0.0", "1.1.0", .standalone);
    defer alloc.free(standalone);
    try std.testing.expectEqualStrings("Update available: v1.0.0 → v1.1.0  (run: csw update)", standalone);

    const brew = try updateNotice(alloc, "1.0.0", "1.1.0", .homebrew);
    defer alloc.free(brew);
    try std.testing.expectEqualStrings("Update available: v1.0.0 → v1.1.0  (run: brew upgrade csw)", brew);
}

fn repeatedDigest(comptime ch: u8) *const [Sha256.digest_length * 2]u8 {
    const digest: [Sha256.digest_length * 2]u8 = @splat(ch);
    return &digest;
}

const digest_a = repeatedDigest('a');
const digest_b = repeatedDigest('b');

test "expectedDigest reads both sha256sum formats" {
    const sums = digest_a ++ "  csw-aarch64-apple-darwin\n" ++ digest_b ++ " *csw-x86_64-unknown-linux-musl\n";
    try std.testing.expectEqualStrings(digest_a, expectedDigest(sums, "csw-aarch64-apple-darwin").?);
    try std.testing.expectEqualStrings(digest_b, expectedDigest(sums, "csw-x86_64-unknown-linux-musl").?);
}

test "expectedDigest is exact about asset names" {
    const sums = digest_a ++ "  csw-aarch64-apple-darwin.deb\n";
    try std.testing.expectEqual(@as(?[]const u8, null), expectedDigest(sums, "csw-aarch64-apple-darwin"));
    try std.testing.expectEqual(@as(?[]const u8, null), expectedDigest("", "csw"));
    try std.testing.expectEqual(@as(?[]const u8, null), expectedDigest("garbage\n\n   \n", "csw"));
}

test "expectedDigest rejects malformed digests" {
    try std.testing.expectEqual(@as(?[]const u8, null), expectedDigest("abc  csw\n", "csw"));
    try std.testing.expectEqual(@as(?[]const u8, null), expectedDigest(repeatedDigest('z') ++ "  csw\n", "csw"));
    try std.testing.expect(expectedDigest(digest_a ++ "  csw\r\n", "csw") != null);
}

test "digestMatches ignores case" {
    try std.testing.expect(digestMatches("ABCDEF", "abcdef"));
    try std.testing.expect(!digestMatches("abcdef", "abcdee"));
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: []u8,
    exe: []u8,

    fn init(alloc: std.mem.Allocator, initial: []const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(std.Options.debug_io, &buf);
        const base = try alloc.dupe(u8, buf[0..len]);
        errdefer alloc.free(base);
        const exe = try std.fs.path.join(alloc, &.{ base, "csw" });
        errdefer alloc.free(exe);
        try writeFile(alloc, exe, initial);
        return .{ .tmp = tmp, .base = base, .exe = exe };
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        alloc.free(self.base);
        alloc.free(self.exe);
        self.tmp.cleanup();
    }

    fn installed(self: Fixture, alloc: std.mem.Allocator) ![]u8 {
        return readSmallFile(alloc, self.exe);
    }

    fn leftovers(self: Fixture, alloc: std.mem.Allocator) !bool {
        for ([_][]const u8{ TMP_BINARY_SUFFIX, TMP_SUMS_SUFFIX, TMP_COMMIT_SUFFIX, TMP_EDGE_SUMS_SUFFIX }) |suffix| {
            const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ self.exe, suffix });
            defer alloc.free(path);
            const path_z = try alloc.dupeSentinel(u8, path, 0);
            defer alloc.free(path_z);
            if (std.c.access(path_z, 0) == 0) return true;
        }
        return false;
    }
};

fn writeFile(alloc: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const path_z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.CreateFileFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, content.ptr, content.len) != content.len) return error.WriteFailed;
}

const FakeRelease = struct {
    alloc: std.mem.Allocator,
    binary: ?[]const u8,
    sums: ?[]const u8,
    commit: ?[]const u8 = null,
    silent_commit: bool = false,
    silent_sums: bool = false,

    fn download(ctx: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io, url: []const u8, dest: []const u8) anyerror!void {
        _ = gpa;
        _ = io;
        const self: *FakeRelease = @ptrCast(@alignCast(ctx.?));
        if (self.silent_commit and std.mem.endsWith(u8, url, "/" ++ channel.EDGE_COMMIT_ASSET)) return;
        if (self.silent_sums and std.mem.endsWith(u8, url, "/SHA256SUMS")) return;
        const content = if (std.mem.endsWith(u8, url, "/SHA256SUMS"))
            self.sums
        else if (std.mem.endsWith(u8, url, "/" ++ channel.EDGE_COMMIT_ASSET))
            self.commit
        else
            self.binary;
        return writeFile(self.alloc, dest, content orelse return error.DownloadFailed);
    }

    fn transport(self: *FakeRelease) Transport {
        return .{ .ctx = self, .download = download };
    }
};

fn sumsFor(alloc: std.mem.Allocator, content: []const u8, asset: []const u8) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(alloc, "{s}  {s}\n", .{ &hex, asset });
}

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.heap.page_allocator, .{});
}

test "fileDigestHex hashes the file content" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "hello");
    defer fx.deinit(alloc);
    const digest = try fileDigestHex(fx.exe);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", &digest);
    try std.testing.expectError(error.FileNotFound, fileDigestHex("/nonexistent/csw"));
}

test "applyUpdate replaces the binary when the checksum matches" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    const sums = try sumsFor(alloc, "new-binary", "csw-asset");
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = "new-binary", .sums = sums };

    try applyUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/v1", "csw-asset");
    const installed = try fx.installed(alloc);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("new-binary", installed);
    try std.testing.expect(!try fx.leftovers(alloc));
}

test "applyUpdate keeps the old binary on a checksum mismatch" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    const sums = try sumsFor(alloc, "expected-binary", "csw-asset");
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = "tampered", .sums = sums };

    try std.testing.expectError(UpdateError.ChecksumMismatch, applyUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/v1", "csw-asset"));
    const installed = try fx.installed(alloc);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("old", installed);
    try std.testing.expect(!try fx.leftovers(alloc));
}

test "applyUpdate fails closed without usable checksums" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);

    var no_sums: FakeRelease = .{ .alloc = alloc, .binary = "new", .sums = null };
    try std.testing.expectError(UpdateError.ChecksumsUnavailable, applyUpdate(alloc, tio.io(), no_sums.transport(), fx.exe, "https://example.test/v1", "csw-asset"));

    const other = try sumsFor(alloc, "new", "some-other-asset");
    defer alloc.free(other);
    var unlisted: FakeRelease = .{ .alloc = alloc, .binary = "new", .sums = other };
    try std.testing.expectError(UpdateError.ChecksumMissing, applyUpdate(alloc, tio.io(), unlisted.transport(), fx.exe, "https://example.test/v1", "csw-asset"));

    const installed = try fx.installed(alloc);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("old", installed);
    try std.testing.expect(!try fx.leftovers(alloc));
}

test "applyUpdate reports a failed binary download" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    var release: FakeRelease = .{ .alloc = alloc, .binary = null, .sums = null };

    try std.testing.expectError(UpdateError.DownloadFailed, applyUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/v1", "csw-asset"));
    const installed = try fx.installed(alloc);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("old", installed);
    try std.testing.expect(!try fx.leftovers(alloc));
}

test "applyUpdate fails when the target directory cannot be replaced" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    const sums = try sumsFor(alloc, "new-binary", "csw-asset");
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = "new-binary", .sums = sums };

    const dir_target = try std.fs.path.join(alloc, &.{ fx.base, "target" });
    defer alloc.free(dir_target);
    const dir_target_z = try alloc.dupeSentinel(u8, dir_target, 0);
    defer alloc.free(dir_target_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(dir_target_z, 0o755));

    try std.testing.expectError(UpdateError.ReplaceFailed, applyUpdate(alloc, tio.io(), release.transport(), dir_target, "https://example.test/v1", "csw-asset"));
}

test "curlDownload copies a local file and fails on a missing one" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "payload");
    defer fx.deinit(alloc);

    const source_url = try std.fmt.allocPrint(alloc, "file://{s}", .{fx.exe});
    defer alloc.free(source_url);
    const dest = try std.fs.path.join(alloc, &.{ fx.base, "copy" });
    defer alloc.free(dest);
    curlDownload(null, alloc, tio.io(), source_url, dest) catch |e| switch (e) {
        error.FileNotFound => return error.SkipZigTest,
        else => return e,
    };
    const copied = try readSmallFile(alloc, dest);
    defer alloc.free(copied);
    try std.testing.expectEqualStrings("payload", copied);

    const missing_url = try std.fmt.allocPrint(alloc, "file://{s}/absent", .{fx.base});
    defer alloc.free(missing_url);
    try std.testing.expectError(error.DownloadFailed, curlDownload(null, alloc, tio.io(), missing_url, dest));
}

test "resolveExecutable follows symlinks and falls back to the input" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "bin");
    defer fx.deinit(alloc);
    const link = try std.fs.path.join(alloc, &.{ fx.base, "link" });
    defer alloc.free(link);
    const link_z = try alloc.dupeSentinel(u8, link, 0);
    defer alloc.free(link_z);
    const exe_z = try alloc.dupeSentinel(u8, fx.exe, 0);
    defer alloc.free(exe_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(exe_z, link_z));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = resolveExecutable(&buf, link);
    try std.testing.expectEqualStrings(fx.exe, resolved);
    try std.testing.expectEqualStrings("/nonexistent/csw", resolveExecutable(&buf, "/nonexistent/csw"));

    var tiny: [2]u8 = undefined;
    try std.testing.expectEqualStrings(link, resolveExecutable(&tiny, link));
}

const edge_sha = "abcdef0123456789abcdef0123456789abcdef01";
const older_sha = "1111111111111111111111111111111111111111";

fn edgeSums(alloc: std.mem.Allocator, binary: []const u8, commit: []const u8) ![]u8 {
    const binary_line = try sumsFor(alloc, binary, "csw-asset");
    defer alloc.free(binary_line);
    const commit_line = try sumsFor(alloc, commit, channel.EDGE_COMMIT_ASSET);
    defer alloc.free(commit_line);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ binary_line, commit_line });
}

test "applyEdgeUpdate installs a newer edge build and reports its commit" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    const sums = try edgeSums(alloc, "edge-binary", edge_sha ++ "\n");
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = "edge-binary", .sums = sums, .commit = edge_sha ++ "\n" };

    const result = try applyEdgeUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/edge", "csw-asset", older_sha);
    try std.testing.expectEqual(EdgeStatus.updated, result.status);
    try std.testing.expectEqualStrings(edge_sha, &result.commit);
    const installed = try fx.installed(alloc);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("edge-binary", installed);
    try std.testing.expect(!try fx.leftovers(alloc));
}

test "applyEdgeUpdate lets a stable build switch to edge and lowercases the commit" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "stable");
    defer fx.deinit(alloc);
    const upper = "ABCDEF0123456789ABCDEF0123456789ABCDEF01\n";
    const sums = try edgeSums(alloc, "edge-binary", upper);
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = "edge-binary", .sums = sums, .commit = upper };

    const result = try applyEdgeUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/edge", "csw-asset", "");
    try std.testing.expectEqual(EdgeStatus.updated, result.status);
    try std.testing.expectEqualStrings(edge_sha, &result.commit);
}

test "applyEdgeUpdate does nothing when already on that commit" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "current");
    defer fx.deinit(alloc);
    const sums = try edgeSums(alloc, "unused", edge_sha ++ "\n");
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = null, .sums = sums, .commit = edge_sha ++ "\n" };

    const result = try applyEdgeUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/edge", "csw-asset", edge_sha);
    try std.testing.expectEqual(EdgeStatus.current, result.status);
    try std.testing.expectEqualStrings(edge_sha, &result.commit);
    const installed = try fx.installed(alloc);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("current", installed);
    try std.testing.expect(!try fx.leftovers(alloc));
}

test "applyEdgeUpdate refuses a commit that does not match SHA256SUMS" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    const sums = try edgeSums(alloc, "edge-binary", older_sha ++ "\n");
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = "edge-binary", .sums = sums, .commit = edge_sha ++ "\n" };

    try std.testing.expectError(UpdateError.ChecksumMismatch, applyEdgeUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/edge", "csw-asset", older_sha));
    const installed = try fx.installed(alloc);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("old", installed);
    try std.testing.expect(!try fx.leftovers(alloc));
}

test "applyEdgeUpdate fails closed when SHA256SUMS does not list EDGE_COMMIT" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    const sums = try sumsFor(alloc, "edge-binary", "csw-asset");
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = "edge-binary", .sums = sums, .commit = edge_sha ++ "\n" };

    try std.testing.expectError(UpdateError.ChecksumMissing, applyEdgeUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/edge", "csw-asset", ""));
}

test "applyEdgeUpdate rejects a malformed commit even when it is listed" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    const sums = try edgeSums(alloc, "edge-binary", "not-a-sha\n");
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = "edge-binary", .sums = sums, .commit = "not-a-sha\n" };

    try std.testing.expectError(UpdateError.EdgeCommitInvalid, applyEdgeUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/edge", "csw-asset", ""));
}

test "applyEdgeUpdate reports unavailable commit or checksums" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    const sums = try edgeSums(alloc, "edge-binary", edge_sha ++ "\n");
    defer alloc.free(sums);

    var no_commit: FakeRelease = .{ .alloc = alloc, .binary = "edge-binary", .sums = sums, .commit = null };
    try std.testing.expectError(UpdateError.EdgeCommitUnavailable, applyEdgeUpdate(alloc, tio.io(), no_commit.transport(), fx.exe, "https://example.test/edge", "csw-asset", ""));

    var silent_commit: FakeRelease = .{ .alloc = alloc, .binary = "edge-binary", .sums = sums, .commit = edge_sha ++ "\n", .silent_commit = true };
    try std.testing.expectError(UpdateError.EdgeCommitUnavailable, applyEdgeUpdate(alloc, tio.io(), silent_commit.transport(), fx.exe, "https://example.test/edge", "csw-asset", ""));

    var no_sums: FakeRelease = .{ .alloc = alloc, .binary = "edge-binary", .sums = null, .commit = edge_sha ++ "\n" };
    try std.testing.expectError(UpdateError.ChecksumsUnavailable, applyEdgeUpdate(alloc, tio.io(), no_sums.transport(), fx.exe, "https://example.test/edge", "csw-asset", ""));

    var silent_sums: FakeRelease = .{ .alloc = alloc, .binary = "edge-binary", .sums = sums, .commit = edge_sha ++ "\n", .silent_sums = true };
    try std.testing.expectError(UpdateError.ChecksumsUnavailable, applyEdgeUpdate(alloc, tio.io(), silent_sums.transport(), fx.exe, "https://example.test/edge", "csw-asset", ""));
    try std.testing.expect(!try fx.leftovers(alloc));
}

test "applyEdgeUpdate keeps the old binary when the edge binary is tampered" {
    const alloc = std.testing.allocator;
    var tio = testIo();
    defer tio.deinit();
    var fx = try Fixture.init(alloc, "old");
    defer fx.deinit(alloc);
    const sums = try edgeSums(alloc, "edge-binary", edge_sha ++ "\n");
    defer alloc.free(sums);
    var release: FakeRelease = .{ .alloc = alloc, .binary = "tampered", .sums = sums, .commit = edge_sha ++ "\n" };

    try std.testing.expectError(UpdateError.ChecksumMismatch, applyEdgeUpdate(alloc, tio.io(), release.transport(), fx.exe, "https://example.test/edge", "csw-asset", ""));
    const installed = try fx.installed(alloc);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("old", installed);
    try std.testing.expect(!try fx.leftovers(alloc));
}

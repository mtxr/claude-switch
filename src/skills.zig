//! Optional one-way sharing of local Claude Code skills between profiles.
//! Claude's account-synced `skills/synced` cache is never shared.

const std = @import("std");
const desktop = @import("desktop.zig");
const paths = @import("paths.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("unistd.h");
});

const marker_name = ".csw-skills-source";

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

fn markerPath(gpa: std.mem.Allocator, base: []const u8, target: []const u8) ![]const u8 {
    const dir = try paths.profileDirIn(gpa, base, target);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, marker_name });
}

pub fn sourceForIn(gpa: std.mem.Allocator, base: []const u8, target: []const u8) !?[]const u8 {
    const marker = try markerPath(gpa, base, target);
    defer gpa.free(marker);
    const marker_z = try gpa.dupeZ(u8, marker);
    defer gpa.free(marker_z);
    const fd = std.c.open(marker_z, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);

    var buf: [129]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0 or n > 128) return error.InvalidSkillsSource;
    const name = std.mem.trim(u8, buf[0..@intCast(n)], "\r\n");
    if (!validName(name)) return error.InvalidSkillsSource;
    return try gpa.dupe(u8, name);
}

fn skillDir(gpa: std.mem.Allocator, base: []const u8, profile: []const u8) ![]const u8 {
    const dir = try paths.profileDirIn(gpa, base, profile);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "skills" });
}

fn syncFromIn(gpa: std.mem.Allocator, base: []const u8, source: []const u8, target: []const u8) !usize {
    const from = try skillDir(gpa, base, source);
    defer gpa.free(from);
    const to = try skillDir(gpa, base, target);
    defer gpa.free(to);
    if (desktop.isSymlink(gpa, to)) return error.SkillsDirectoryIsSymlink;

    const from_z = try gpa.dupeZ(u8, from);
    defer gpa.free(from_z);
    const dir = c.opendir(from_z) orelse return 0; // source may not have skills yet
    defer _ = c.closedir(dir);

    try desktop.mkdirAllC(gpa, to);
    var added: usize = 0;
    while (c.readdir(dir)) |entry| {
        const raw = entry.*.d_name;
        const end = std.mem.indexOfScalar(u8, &raw, 0) orelse raw.len;
        const name = raw[0..end];
        if (name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "synced")) continue;

        const source_skill = try std.fs.path.join(gpa, &.{ from, name });
        defer gpa.free(source_skill);
        const manifest = try std.fs.path.join(gpa, &.{ source_skill, "SKILL.md" });
        defer gpa.free(manifest);
        if (!desktop.pathExists(gpa, manifest)) continue;

        const target_skill = try std.fs.path.join(gpa, &.{ to, name });
        defer gpa.free(target_skill);
        if (desktop.pathExists(gpa, target_skill) or desktop.isSymlink(gpa, target_skill)) continue;

        const source_z = try gpa.dupeZ(u8, source_skill);
        defer gpa.free(source_z);
        const target_z = try gpa.dupeZ(u8, target_skill);
        defer gpa.free(target_z);
        if (std.c.symlink(source_z, target_z) != 0) return error.SymlinkFailed;
        added += 1;
    }
    return added;
}

pub fn shareIn(gpa: std.mem.Allocator, base: []const u8, source: []const u8, target: []const u8) !usize {
    if (!validName(source) or !validName(target) or std.mem.eql(u8, source, target)) return error.InvalidProfileName;
    const source_profile = try paths.profileDirIn(gpa, base, source);
    defer gpa.free(source_profile);
    const target_profile = try paths.profileDirIn(gpa, base, target);
    defer gpa.free(target_profile);
    if (!desktop.pathExists(gpa, source_profile) or !desktop.pathExists(gpa, target_profile)) return error.ProfileNotFound;

    const existing = try sourceForIn(gpa, base, target);
    defer if (existing) |name| gpa.free(name);
    if (existing) |name| {
        if (!std.mem.eql(u8, name, source)) return error.DifferentSkillsSource;
        return syncFromIn(gpa, base, source, target);
    }

    const added = try syncFromIn(gpa, base, source, target);
    const marker = try markerPath(gpa, base, target);
    defer gpa.free(marker);
    const marker_z = try gpa.dupeZ(u8, marker);
    defer gpa.free(marker_z);
    const fd = std.c.open(marker_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.CreateMarkerFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, source.ptr, source.len) != source.len) return error.WriteMarkerFailed;
    return added;
}

pub fn syncIn(gpa: std.mem.Allocator, base: []const u8, target: []const u8) !usize {
    const source = try sourceForIn(gpa, base, target) orelse return 0;
    defer gpa.free(source);
    const source_profile = try paths.profileDirIn(gpa, base, source);
    defer gpa.free(source_profile);
    if (!desktop.pathExists(gpa, source_profile)) return error.ProfileNotFound;
    return syncFromIn(gpa, base, source, target);
}

pub fn unshareIn(gpa: std.mem.Allocator, base: []const u8, target: []const u8) !usize {
    const source = try sourceForIn(gpa, base, target) orelse return 0;
    defer gpa.free(source);
    const to = try skillDir(gpa, base, target);
    defer gpa.free(to);
    if (desktop.isSymlink(gpa, to)) return error.SkillsDirectoryIsSymlink;
    const to_z = try gpa.dupeZ(u8, to);
    defer gpa.free(to_z);
    const dir = c.opendir(to_z);
    var removed: usize = 0;
    if (dir) |handle| {
        defer _ = c.closedir(handle);
        while (c.readdir(handle)) |entry| {
            const raw = entry.*.d_name;
            const end = std.mem.indexOfScalar(u8, &raw, 0) orelse raw.len;
            const name = raw[0..end];
            if (name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "synced")) continue;
            const link = try std.fs.path.join(gpa, &.{ to, name });
            defer gpa.free(link);
            if (!desktop.isSymlink(gpa, link)) continue;
            const expected_source_dir = try skillDir(gpa, base, source);
            defer gpa.free(expected_source_dir);
            const expected = try std.fs.path.join(gpa, &.{ expected_source_dir, name });
            defer gpa.free(expected);
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = desktop.readLinkC(gpa, link, &buf) catch continue;
            if (!std.mem.eql(u8, buf[0..n], expected)) continue;
            desktop.deletePathC(gpa, link);
            removed += 1;
        }
    }
    const marker = try markerPath(gpa, base, target);
    defer gpa.free(marker);
    desktop.deletePathC(gpa, marker);
    return removed;
}

fn makeTestFile(gpa: std.mem.Allocator, path: []const u8) !void {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.CreateFileFailed;
    _ = std.c.close(fd);
}

test "share skills refreshes additions without touching synced or conflicting skills" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.Options.debug_io, &buf);
    const base = try alloc.dupe(u8, buf[0..n]);
    defer alloc.free(base);

    for (&[_][]const u8{ "primary", "overflow" }) |name| {
        const dir = try skillDir(alloc, base, name);
        defer alloc.free(dir);
        try desktop.mkdirAllC(alloc, dir);
    }

    const first = try std.fs.path.join(alloc, &.{ base, ".claude.primary", "skills", "first" });
    defer alloc.free(first);
    try desktop.mkdirAllC(alloc, first);
    const first_manifest = try std.fs.path.join(alloc, &.{ first, "SKILL.md" });
    defer alloc.free(first_manifest);
    try makeTestFile(alloc, first_manifest);

    const source_synced = try std.fs.path.join(alloc, &.{ base, ".claude.primary", "skills", "synced", "cloud" });
    defer alloc.free(source_synced);
    try desktop.mkdirAllC(alloc, source_synced);
    const synced_manifest = try std.fs.path.join(alloc, &.{ source_synced, "SKILL.md" });
    defer alloc.free(synced_manifest);
    try makeTestFile(alloc, synced_manifest);

    const local_conflict = try std.fs.path.join(alloc, &.{ base, ".claude.overflow", "skills", "first" });
    defer alloc.free(local_conflict);
    try desktop.mkdirAllC(alloc, local_conflict);
    const local_manifest = try std.fs.path.join(alloc, &.{ local_conflict, "SKILL.md" });
    defer alloc.free(local_manifest);
    try makeTestFile(alloc, local_manifest);

    try std.testing.expectEqual(@as(usize, 0), try shareIn(alloc, base, "primary", "overflow"));
    try std.testing.expect(!desktop.isSymlink(alloc, local_conflict));
    const target_synced = try std.fs.path.join(alloc, &.{ base, ".claude.overflow", "skills", "synced" });
    defer alloc.free(target_synced);
    try std.testing.expect(!desktop.pathExists(alloc, target_synced));

    const second = try std.fs.path.join(alloc, &.{ base, ".claude.primary", "skills", "second" });
    defer alloc.free(second);
    try desktop.mkdirAllC(alloc, second);
    const second_manifest = try std.fs.path.join(alloc, &.{ second, "SKILL.md" });
    defer alloc.free(second_manifest);
    try makeTestFile(alloc, second_manifest);

    try std.testing.expectEqual(@as(usize, 1), try syncIn(alloc, base, "overflow"));
    const linked = try std.fs.path.join(alloc, &.{ base, ".claude.overflow", "skills", "second" });
    defer alloc.free(linked);
    try std.testing.expect(desktop.isSymlink(alloc, linked));
    try std.testing.expectEqual(@as(usize, 0), try syncIn(alloc, base, "overflow"));
    try std.testing.expectEqual(@as(usize, 1), try unshareIn(alloc, base, "overflow"));
    try std.testing.expect(!desktop.isSymlink(alloc, linked));
    try std.testing.expect(desktop.pathExists(alloc, local_manifest));
    try std.testing.expect(desktop.pathExists(alloc, second_manifest));
    try std.testing.expectEqual(@as(?[]const u8, null), try sourceForIn(alloc, base, "overflow"));
}

test "share skills rejects unsafe names and a different source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.Options.debug_io, &buf);
    const base = try alloc.dupe(u8, buf[0..n]);
    defer alloc.free(base);
    try std.testing.expectError(error.InvalidProfileName, shareIn(alloc, base, "../primary", "overflow"));
    for (&[_][]const u8{ "primary", "other", "overflow" }) |name| {
        const dir = try paths.profileDirIn(alloc, base, name);
        defer alloc.free(dir);
        try desktop.mkdirAllC(alloc, dir);
    }
    try std.testing.expectEqual(@as(usize, 0), try shareIn(alloc, base, "primary", "overflow"));
    try std.testing.expectError(error.DifferentSkillsSource, shareIn(alloc, base, "other", "overflow"));
}

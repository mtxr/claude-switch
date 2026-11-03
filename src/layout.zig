//! layout.zig — where a profile lives on disk, and the move from the old layout
//!
//! A profile is one directory, `~/.claude.<name>/`, and the config Claude Code
//! keeps for it is a real file inside: `~/.claude.<name>/.claude.json`. That is
//! where Claude Code looks when CLAUDE_CONFIG_DIR points at the directory, so
//! nothing has to be linked and nothing can be broken by Claude Code replacing
//! the file when it saves.
//!
//! The active profile is `~/.claude` pointing at a profile directory, and
//! `~/.claude.json` follows it through `~/.claude/.claude.json`, so switching
//! profiles changes a single link.
//!
//! Versions before this layout kept the config next to the directory as
//! `~/.claude.<name>.json` and linked it into the directory. `migrateAllIn`
//! and `migrateProfileIn` move those files in; both are safe to repeat.

const std = @import("std");
const desktop = @import("desktop.zig");
const paths = @import("paths.zig");

const c = @import("c");

/// What `~/.claude.json` points at: the config file of whatever `~/.claude` is linked to.
pub const OUTER_LINK_TARGET = ".claude/" ++ paths.CONFIG_FILE;

/// Suffix of the copy kept when two versions of a config meet and one has to give way.
pub const BACKUP_SUFFIX = ".csw-bak";

const LEGACY_PREFIX = ".claude.";
const LEGACY_SUFFIX = ".json";

/// The profile `~/.claude` points at, or null when it is not a link to a profile directory.
pub fn activeIn(gpa: std.mem.Allocator, base: []const u8) !?[]u8 {
    const link = try paths.claudeDirIn(gpa, base);
    defer gpa.free(link);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = desktop.readLinkC(gpa, link, &buf) catch return null;

    const dirname = std.fs.path.basename(buf[0..n]);
    if (!std.mem.startsWith(u8, dirname, LEGACY_PREFIX)) return null;
    const stem = dirname[LEGACY_PREFIX.len..];
    if (stem.len == 0) return null;
    return try gpa.dupe(u8, stem);
}

/// Names of profiles still stored the old way (`~/.claude.<name>.json` as a regular file).
pub fn legacyNamesIn(gpa: std.mem.Allocator, base: []const u8) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |item| gpa.free(item);
        results.deinit(gpa);
    }

    const base_z = try gpa.dupeSentinel(u8, base, 0);
    defer gpa.free(base_z);
    const handle = std.c.opendir(base_z) orelse return results.toOwnedSlice(gpa);
    defer _ = std.c.closedir(handle);

    while (std.c.readdir(handle)) |entry| {
        const full = entry.*.name;
        const end = std.mem.indexOfScalar(u8, &full, 0) orelse full.len;
        const name = full[0..end];
        if (!std.mem.startsWith(u8, name, LEGACY_PREFIX)) continue;
        if (!std.mem.endsWith(u8, name, LEGACY_SUFFIX)) continue;
        if (name.len <= LEGACY_PREFIX.len + LEGACY_SUFFIX.len) continue;
        const stem = name[LEGACY_PREFIX.len .. name.len - LEGACY_SUFFIX.len];

        const path = try std.fs.path.join(gpa, &.{ base, name });
        defer gpa.free(path);
        if (desktop.isSymlink(gpa, path)) continue;
        try results.append(gpa, try gpa.dupe(u8, stem));
    }

    const result = try results.toOwnedSlice(gpa);
    std.mem.sort([]const u8, result, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return result;
}

pub fn freeNames(gpa: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// Moves one profile's `~/.claude.<name>.json` into `~/.claude.<name>/.claude.json`.
/// Returns whether anything moved. The usual inner link to the old file is
/// dropped. When the directory already holds a regular `.claude.json` (Claude
/// Code replaced the link), the newer of the two stays and the other is kept
/// next to it with `BACKUP_SUFFIX`. An inner link that points somewhere else
/// is not ours, so that profile is left exactly as it is.
pub fn migrateProfileIn(gpa: std.mem.Allocator, base: []const u8, name: []const u8) !bool {
    const legacy = try paths.legacyProfileJsonIn(gpa, base, name);
    defer gpa.free(legacy);
    if (desktop.isSymlink(gpa, legacy) or !desktop.pathExists(gpa, legacy)) return false;

    const dir = try paths.profileDirIn(gpa, base, name);
    defer gpa.free(dir);
    if (!desktop.pathExists(gpa, dir)) try desktop.mkdirAllC(gpa, dir);

    const inner = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(inner);

    if (desktop.isSymlink(gpa, inner)) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = desktop.readLinkC(gpa, inner, &buf) catch return false;
        if (!std.mem.eql(u8, buf[0..n], legacy)) return false;
        desktop.deletePathC(gpa, inner);
        try desktop.renameC(gpa, legacy, inner);
        return true;
    }

    if (!desktop.pathExists(gpa, inner)) {
        try desktop.renameC(gpa, legacy, inner);
        return true;
    }

    const backup = try backupPathFor(gpa, inner);
    defer gpa.free(backup);
    const inner_ns = regularFileMtimeNs(inner);
    const legacy_ns = regularFileMtimeNs(legacy);
    if (inner_ns != null and legacy_ns != null and inner_ns.? > legacy_ns.?) {
        try desktop.renameC(gpa, legacy, backup);
    } else {
        try desktop.renameC(gpa, inner, backup);
        try desktop.renameC(gpa, legacy, inner);
    }
    return true;
}

/// Brings `~/.claude.json` in line with the active profile: a link to
/// `OUTER_LINK_TARGET`. Handles a link to an old-style file and a regular file
/// left by Claude Code replacing the link (the newer content stays in the
/// profile, the other is kept with `BACKUP_SUFFIX`). Does nothing when
/// `~/.claude` is not a link to a profile or `~/.claude.json` is a foreign link.
pub fn repairOuterLinkIn(gpa: std.mem.Allocator, base: []const u8) !bool {
    const name = (try activeIn(gpa, base)) orelse return false;
    defer gpa.free(name);

    const inner = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(inner);
    if (!desktop.pathExists(gpa, inner)) return false;

    const outer = try paths.claudeJsonIn(gpa, base);
    defer gpa.free(outer);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (desktop.readLinkC(gpa, outer, &buf)) |n| {
        const target = buf[0..n];
        if (std.mem.eql(u8, target, OUTER_LINK_TARGET)) return false;
        const legacy = try paths.legacyProfileJsonIn(gpa, base, name);
        defer gpa.free(legacy);
        const ours = std.mem.eql(u8, target, legacy) or std.mem.eql(u8, target, inner);
        if (!ours) return false;
    } else |_| {
        if (desktop.pathExists(gpa, outer)) try keepNewerIn(gpa, outer, inner);
    }

    try replaceWithLink(gpa, OUTER_LINK_TARGET, outer);
    return true;
}

/// Moves every old-style profile in and repairs the outer link. Returns how
/// many profiles moved; a profile that fails is skipped so one bad file cannot
/// block the rest.
pub fn migrateAllIn(gpa: std.mem.Allocator, base: []const u8) !usize {
    const names = try legacyNamesIn(gpa, base);
    defer freeNames(gpa, names);

    var moved: usize = 0;
    for (names) |name| {
        if (migrateProfileIn(gpa, base, name) catch false) moved += 1;
    }
    _ = repairOuterLinkIn(gpa, base) catch false;
    return moved;
}

/// A regular file `loose` and the profile's `inner` config disagree: the newer
/// one ends up as `inner` and the other is kept next to it.
fn keepNewerIn(gpa: std.mem.Allocator, loose: []const u8, inner: []const u8) !void {
    const backup = try backupPathFor(gpa, inner);
    defer gpa.free(backup);
    const loose_ns = regularFileMtimeNs(loose) orelse return error.NotARegularFile;
    const inner_ns = regularFileMtimeNs(inner);
    if (inner_ns == null or loose_ns > inner_ns.?) {
        if (inner_ns != null) try desktop.renameC(gpa, inner, backup);
        try desktop.renameC(gpa, loose, inner);
    } else {
        try desktop.renameC(gpa, loose, backup);
    }
}

fn backupPathFor(gpa: std.mem.Allocator, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ file, BACKUP_SUFFIX });
}

/// Creates (or replaces) the symlink `link` pointing at `target`, atomically.
pub fn replaceWithLink(gpa: std.mem.Allocator, target: []const u8, link: []const u8) !void {
    const staging = try std.fmt.allocPrint(gpa, "{s}.csw-tmp", .{link});
    defer gpa.free(staging);
    desktop.deletePathC(gpa, staging);
    const target_z = try gpa.dupeSentinel(u8, target, 0);
    defer gpa.free(target_z);
    const staging_z = try gpa.dupeSentinel(u8, staging, 0);
    defer gpa.free(staging_z);
    if (std.c.symlink(target_z, staging_z) != 0) return error.SymlinkFailed;
    desktop.renameC(gpa, staging, link) catch |e| {
        desktop.deletePathC(gpa, staging);
        return e;
    };
}

fn regularFileMtimeNs(path: []const u8) ?i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    return st.mtime.nanoseconds;
}

// --- tests ---

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: []u8,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(std.Options.debug_io, &buf);
        return .{ .tmp = tmp, .base = try alloc.dupe(u8, buf[0..len]) };
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        alloc.free(self.base);
        self.tmp.cleanup();
    }

    fn path(self: Fixture, alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.base, rel });
    }

    fn mkdir(self: *Fixture, rel: []const u8) !void {
        try self.tmp.dir.createDir(std.Options.debug_io, rel, .default_dir);
    }

    /// Writes `content` at `rel` and stamps its mtime in seconds so tests can order files.
    fn write(self: *Fixture, alloc: std.mem.Allocator, rel: []const u8, content: []const u8, mtime_s: i64) !void {
        try self.tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = rel, .data = content });
        const full = try self.path(alloc, rel);
        defer alloc.free(full);
        const full_z = try alloc.dupeSentinel(u8, full, 0);
        defer alloc.free(full_z);
        const times = [2]std.c.timespec{
            .{ .sec = @intCast(mtime_s), .nsec = 0 },
            .{ .sec = @intCast(mtime_s), .nsec = 0 },
        };
        _ = std.c.utimensat(std.c.AT.FDCWD, full_z, &times, 0);
    }

    fn link(self: Fixture, alloc: std.mem.Allocator, target: []const u8, rel: []const u8) !void {
        const full = try self.path(alloc, rel);
        defer alloc.free(full);
        const full_z = try alloc.dupeSentinel(u8, full, 0);
        defer alloc.free(full_z);
        const target_z = try alloc.dupeSentinel(u8, target, 0);
        defer alloc.free(target_z);
        if (std.c.symlink(target_z, full_z) != 0) return error.SymlinkFailed;
    }

    fn read(self: Fixture, alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.Options.debug_io, rel, alloc, .limited(1 << 20));
    }

    fn exists(self: Fixture, alloc: std.mem.Allocator, rel: []const u8) bool {
        const full = self.path(alloc, rel) catch return false;
        defer alloc.free(full);
        return desktop.pathExists(alloc, full);
    }

    fn linkTarget(self: Fixture, alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
        const full = try self.path(alloc, rel);
        defer alloc.free(full);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try desktop.readLinkC(alloc, full, &buf);
        return alloc.dupe(u8, buf[0..n]);
    }
};

test "activeIn reads the profile ~/.claude points at" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try std.testing.expect((try activeIn(alloc, fx.base)) == null);

    try fx.mkdir(".claude.work");
    const target = try fx.path(alloc, ".claude.work");
    defer alloc.free(target);
    try fx.link(alloc, target, ".claude");
    const name = (try activeIn(alloc, fx.base)).?;
    defer alloc.free(name);
    try std.testing.expectEqualStrings("work", name);
}

test "activeIn ignores a real directory and a link to something that is not a profile" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.mkdir(".claude");
    try std.testing.expect((try activeIn(alloc, fx.base)) == null);

    var other = try Fixture.init(alloc);
    defer other.deinit(alloc);
    try other.link(alloc, "/somewhere/else", ".claude");
    try std.testing.expect((try activeIn(alloc, other.base)) == null);
    var empty = try Fixture.init(alloc);
    defer empty.deinit(alloc);
    try empty.link(alloc, "/h/.claude.", ".claude");
    try std.testing.expect((try activeIn(alloc, empty.base)) == null);
}

test "migrateProfileIn moves the json in and drops the inner link" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.write(alloc, ".claude.work.json", "mine", 1000);
    try fx.mkdir(".claude.work");
    const legacy = try fx.path(alloc, ".claude.work.json");
    defer alloc.free(legacy);
    try fx.link(alloc, legacy, ".claude.work/.claude.json");

    try std.testing.expect(try migrateProfileIn(alloc, fx.base, "work"));

    try std.testing.expect(!fx.exists(alloc, ".claude.work.json"));
    const inner = try fx.path(alloc, ".claude.work/.claude.json");
    defer alloc.free(inner);
    try std.testing.expect(!desktop.isSymlink(alloc, inner));
    const content = try fx.read(alloc, ".claude.work/.claude.json");
    defer alloc.free(content);
    try std.testing.expectEqualStrings("mine", content);
}

test "migrateProfileIn creates a missing directory" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.write(alloc, ".claude.work.json", "mine", 1000);
    try std.testing.expect(try migrateProfileIn(alloc, fx.base, "work"));
    const content = try fx.read(alloc, ".claude.work/.claude.json");
    defer alloc.free(content);
    try std.testing.expectEqualStrings("mine", content);
}

test "migrateProfileIn is a no-op when there is nothing to move, and idempotent" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try std.testing.expect(!try migrateProfileIn(alloc, fx.base, "work"));

    try fx.mkdir(".claude.work");
    try fx.write(alloc, ".claude.work/.claude.json", "new", 1000);
    try std.testing.expect(!try migrateProfileIn(alloc, fx.base, "work"));

    try fx.write(alloc, ".claude.old.json", "x", 1000);
    try std.testing.expect(try migrateProfileIn(alloc, fx.base, "old"));
    try std.testing.expect(!try migrateProfileIn(alloc, fx.base, "old"));
}

test "migrateProfileIn keeps the newer regular inner config and backs up the other" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.mkdir(".claude.work");
    try fx.write(alloc, ".claude.work.json", "old", 1000);
    try fx.write(alloc, ".claude.work/.claude.json", "new", 2000);

    try std.testing.expect(try migrateProfileIn(alloc, fx.base, "work"));

    const kept = try fx.read(alloc, ".claude.work/.claude.json");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("new", kept);
    const backup = try fx.read(alloc, ".claude.work/.claude.json" ++ BACKUP_SUFFIX);
    defer alloc.free(backup);
    try std.testing.expectEqualStrings("old", backup);
    try std.testing.expect(!fx.exists(alloc, ".claude.work.json"));
}

test "migrateProfileIn prefers the old file when it is newer or equal" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.mkdir(".claude.work");
    try fx.write(alloc, ".claude.work.json", "fresh", 2000);
    try fx.write(alloc, ".claude.work/.claude.json", "stale", 1000);

    try std.testing.expect(try migrateProfileIn(alloc, fx.base, "work"));

    const kept = try fx.read(alloc, ".claude.work/.claude.json");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("fresh", kept);
    const backup = try fx.read(alloc, ".claude.work/.claude.json" ++ BACKUP_SUFFIX);
    defer alloc.free(backup);
    try std.testing.expectEqualStrings("stale", backup);
}

test "migrateProfileIn leaves a profile whose inner link is foreign alone" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.write(alloc, ".claude.work.json", "mine", 1000);
    try fx.mkdir(".claude.work");
    try fx.link(alloc, "/elsewhere/config.json", ".claude.work/.claude.json");

    try std.testing.expect(!try migrateProfileIn(alloc, fx.base, "work"));
    try std.testing.expect(fx.exists(alloc, ".claude.work.json"));
    const target = try fx.linkTarget(alloc, ".claude.work/.claude.json");
    defer alloc.free(target);
    try std.testing.expectEqualStrings("/elsewhere/config.json", target);
}

test "legacyNamesIn lists old-style files and skips links and other files" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.write(alloc, ".claude.b.json", "{}", 1000);
    try fx.write(alloc, ".claude.a.json", "{}", 1000);
    try fx.write(alloc, ".claude.json", "{}", 1000);
    try fx.write(alloc, ".claude.json.backup", "{}", 1000);
    try fx.write(alloc, ".claude..json", "{}", 1000);
    try fx.link(alloc, "/h/.claude.a.json", ".claude.linked.json");

    const names = try legacyNamesIn(alloc, fx.base);
    defer freeNames(alloc, names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("a", names[0]);
    try std.testing.expectEqualStrings("b", names[1]);
}

test "repairOuterLinkIn turns a link to the old file into the relative link" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.mkdir(".claude.work");
    try fx.write(alloc, ".claude.work/.claude.json", "mine", 1000);
    const dir = try fx.path(alloc, ".claude.work");
    defer alloc.free(dir);
    try fx.link(alloc, dir, ".claude");
    const legacy = try fx.path(alloc, ".claude.work.json");
    defer alloc.free(legacy);
    try fx.link(alloc, legacy, ".claude.json");

    try std.testing.expect(try repairOuterLinkIn(alloc, fx.base));
    const target = try fx.linkTarget(alloc, ".claude.json");
    defer alloc.free(target);
    try std.testing.expectEqualStrings(OUTER_LINK_TARGET, target);
    const through = try fx.read(alloc, ".claude.json");
    defer alloc.free(through);
    try std.testing.expectEqualStrings("mine", through);

    try std.testing.expect(!try repairOuterLinkIn(alloc, fx.base));
}

test "repairOuterLinkIn keeps a newer regular ~/.claude.json and backs up the profile's" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.mkdir(".claude.work");
    try fx.write(alloc, ".claude.work/.claude.json", "profile", 1000);
    const dir = try fx.path(alloc, ".claude.work");
    defer alloc.free(dir);
    try fx.link(alloc, dir, ".claude");
    try fx.write(alloc, ".claude.json", "loose", 2000);

    try std.testing.expect(try repairOuterLinkIn(alloc, fx.base));

    const kept = try fx.read(alloc, ".claude.work/.claude.json");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("loose", kept);
    const backup = try fx.read(alloc, ".claude.work/.claude.json" ++ BACKUP_SUFFIX);
    defer alloc.free(backup);
    try std.testing.expectEqualStrings("profile", backup);
    const target = try fx.linkTarget(alloc, ".claude.json");
    defer alloc.free(target);
    try std.testing.expectEqualStrings(OUTER_LINK_TARGET, target);
}

test "repairOuterLinkIn keeps the profile's config when the loose file is older" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.mkdir(".claude.work");
    try fx.write(alloc, ".claude.work/.claude.json", "profile", 2000);
    const dir = try fx.path(alloc, ".claude.work");
    defer alloc.free(dir);
    try fx.link(alloc, dir, ".claude");
    try fx.write(alloc, ".claude.json", "loose", 1000);

    try std.testing.expect(try repairOuterLinkIn(alloc, fx.base));

    const kept = try fx.read(alloc, ".claude.work/.claude.json");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("profile", kept);
    const backup = try fx.read(alloc, ".claude.work/.claude.json" ++ BACKUP_SUFFIX);
    defer alloc.free(backup);
    try std.testing.expectEqualStrings("loose", backup);
}

test "repairOuterLinkIn leaves a foreign link and an unmanaged home alone" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.write(alloc, ".claude.json", "mine", 1000);
    try std.testing.expect(!try repairOuterLinkIn(alloc, fx.base));
    const untouched = try fx.read(alloc, ".claude.json");
    defer alloc.free(untouched);
    try std.testing.expectEqualStrings("mine", untouched);

    var linked = try Fixture.init(alloc);
    defer linked.deinit(alloc);
    try linked.mkdir(".claude.work");
    try linked.write(alloc, ".claude.work/.claude.json", "p", 1000);
    const dir = try linked.path(alloc, ".claude.work");
    defer alloc.free(dir);
    try linked.link(alloc, dir, ".claude");
    try linked.link(alloc, "/somewhere/else.json", ".claude.json");
    try std.testing.expect(!try repairOuterLinkIn(alloc, linked.base));
    const target = try linked.linkTarget(alloc, ".claude.json");
    defer alloc.free(target);
    try std.testing.expectEqualStrings("/somewhere/else.json", target);
}

test "migrateAllIn moves every profile and repairs the outer link" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.write(alloc, ".claude.a.json", "a", 1000);
    try fx.write(alloc, ".claude.b.json", "b", 1000);
    try fx.mkdir(".claude.a");
    const a_json = try fx.path(alloc, ".claude.a.json");
    defer alloc.free(a_json);
    try fx.link(alloc, a_json, ".claude.a/.claude.json");
    const a_dir = try fx.path(alloc, ".claude.a");
    defer alloc.free(a_dir);
    try fx.link(alloc, a_dir, ".claude");
    try fx.link(alloc, a_json, ".claude.json");

    try std.testing.expectEqual(@as(usize, 2), try migrateAllIn(alloc, fx.base));
    try std.testing.expectEqual(@as(usize, 0), try migrateAllIn(alloc, fx.base));

    const a = try fx.read(alloc, ".claude.a/.claude.json");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("a", a);
    const b = try fx.read(alloc, ".claude.b/.claude.json");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("b", b);
    const through = try fx.read(alloc, ".claude.json");
    defer alloc.free(through);
    try std.testing.expectEqualStrings("a", through);
}

test "replaceWithLink replaces a link and clears a leftover staging link" {
    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    try fx.link(alloc, "/old", "l");
    try fx.link(alloc, "/stale", "l.csw-tmp");
    const link = try fx.path(alloc, "l");
    defer alloc.free(link);
    try replaceWithLink(alloc, "/new", link);
    const target = try fx.linkTarget(alloc, "l");
    defer alloc.free(target);
    try std.testing.expectEqualStrings("/new", target);
    try std.testing.expect(!fx.exists(alloc, "l.csw-tmp"));
}

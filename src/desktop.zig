//! desktop.zig — Claude Desktop: quit, launch, swap, leitura de sessão via SQLite C FFI

const std = @import("std");
const crypto = @import("crypto.zig");
const display = @import("display.zig");
const keychain = @import("keychain.zig");
const paths = @import("paths.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const KEYCHAIN_DESKTOP = "Claude Safe Storage";

pub fn isRunning(gpa: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "pgrep", "-x", "Claude" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn quit(gpa: std.mem.Allocator, io: std.Io) void {
    if (!isRunning(gpa, io)) return;
    display.info("Quitting Claude Desktop...");
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "pkill", "-9", "-x", "Claude" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    std.Io.sleep(io, .{ .nanoseconds = 3 * std.time.ns_per_s }, .real) catch {};
}

pub fn launch(gpa: std.mem.Allocator, io: std.Io) void {
    display.info("Reopening Claude Desktop...");
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "open", "-a", "Claude" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

pub fn hasData(gpa: std.mem.Allocator, name: []const u8) bool {
    const h = paths.home(gpa) catch return false;
    defer gpa.free(h);
    return hasDataIn(gpa, h, name);
}

pub fn swap(gpa: std.mem.Allocator, current_name: ?[]const u8, to_name: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    return swapIn(gpa, h, current_name, to_name);
}

pub fn getSessionKey(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    const raw_key = keychain.get(gpa, io, KEYCHAIN_DESKTOP) catch {
        display.err("Claude Safe Storage não encontrado no Keychain. Claude Desktop está instalado?");
        return error.KeychainNotFound;
    };
    defer gpa.free(raw_key);
    const h = try paths.home(gpa);
    defer gpa.free(h);
    return getSessionKeyWithKeyIn(gpa, h, raw_key);
}

// ── Variantes _in ─────────────────────────────────────────────────────────────

pub fn hasDataIn(gpa: std.mem.Allocator, base: []const u8, name: []const u8) bool {
    const d = paths.desktopProfileDirIn(gpa, base, name) catch return false;
    defer gpa.free(d);
    const d_z = gpa.dupeZ(u8, d) catch return false;
    defer gpa.free(d_z);
    // Use opendir to check if dir has any entries
    const dir_handle = std.c.opendir(d_z) orelse return false;
    defer _ = std.c.closedir(dir_handle);
    var found = false;
    while (std.c.readdir(dir_handle)) |entry| {
        const full = entry.*.name;
        const end = std.mem.indexOfScalar(u8, &full, 0) orelse full.len;
        const n = full[0..end];
        if (!std.mem.eql(u8, n, ".") and !std.mem.eql(u8, n, "..")) {
            found = true;
            break;
        }
    }
    return found;
}

pub fn migrateIn(gpa: std.mem.Allocator, base: []const u8) !void {
    const dd = try paths.desktopDirIn(gpa, base);
    defer gpa.free(dd);
    if (!isSymlink(gpa, dd)) return;

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = readLinkC(gpa, dd, &link_buf) catch return;
    const real = link_buf[0..real_len];

    deletePathC(gpa, dd);

    const real_exists = pathExists(gpa, real);
    const dd_exists = pathExists(gpa, dd);
    if (real_exists and !dd_exists) try renameC(gpa, real, dd);
}

pub fn swapIn(gpa: std.mem.Allocator, base: []const u8, current_name: ?[]const u8, to_name: []const u8) !void {
    const dd = try paths.desktopDirIn(gpa, base);
    defer gpa.free(dd);
    const d_to = try paths.desktopProfileDirIn(gpa, base, to_name);
    defer gpa.free(d_to);

    if (isSymlink(gpa, dd)) {
        deletePathC(gpa, dd);
    } else if (pathExists(gpa, dd)) {
        if (current_name) |cur| {
            const d_from = try paths.desktopProfileDirIn(gpa, base, cur);
            defer gpa.free(d_from);
            if (pathExists(gpa, d_from)) deleteDirC(gpa, d_from);
            try renameC(gpa, dd, d_from);
        }
    }

    if (pathExists(gpa, d_to)) {
        try renameC(gpa, d_to, dd);
    } else {
        try mkdirAllC(gpa, dd);
    }
}

pub fn getSessionKeyWithKeyIn(gpa: std.mem.Allocator, base: []const u8, raw_key: []const u8) ![]const u8 {
    const desktop_dir = try paths.desktopDirIn(gpa, base);
    defer gpa.free(desktop_dir);
    const cookies_path = try std.fs.path.join(gpa, &.{ desktop_dir, "Cookies" });
    defer gpa.free(cookies_path);

    if (!pathExists(gpa, cookies_path)) {
        display.err("Cookies DB não encontrado");
        return error.CookiesDbNotFound;
    }

    const key = crypto.deriveKey(raw_key);

    const db_path_z = try gpa.dupeZ(u8, cookies_path);
    defer gpa.free(db_path_z);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(db_path_z, &db, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX, null) != c.SQLITE_OK) {
        return error.SqliteOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    var stmt: ?*c.sqlite3_stmt = null;
    const query = "SELECT encrypted_value FROM cookies WHERE name='sessionKey'";
    if (c.sqlite3_prepare_v2(db, query, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
        display.err("Claude Desktop: cookie sessionKey não encontrado");
        return error.SessionKeyNotFound;
    }

    const blob_ptr = c.sqlite3_column_blob(stmt, 0);
    const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    const encrypted = @as([*]const u8, @ptrCast(blob_ptr))[0..blob_len];

    const decrypted = try crypto.decryptV10(gpa, encrypted, key);
    defer gpa.free(decrypted);

    const idx = std.mem.indexOf(u8, decrypted, "sk-ant") orelse {
        display.err("Claude Desktop: token não encontrado no cookie");
        return error.TokenNotFound;
    };
    return gpa.dupe(u8, decrypted[idx..]);
}

// ── Helpers via std.c (sem io) ────────────────────────────────────────────────

pub fn pathExists(gpa: std.mem.Allocator, path: []const u8) bool {
    const path_z = gpa.dupeZ(u8, path) catch return false;
    defer gpa.free(path_z);
    return std.c.access(path_z, 0) == 0;
}

pub fn isSymlink(gpa: std.mem.Allocator, path: []const u8) bool {
    const path_z = gpa.dupeZ(u8, path) catch return false;
    defer gpa.free(path_z);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return std.c.readlink(path_z, &buf, buf.len) >= 0;
}

pub fn readLinkC(gpa: std.mem.Allocator, path: []const u8, buf: []u8) !usize {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const n = std.c.readlink(path_z, buf.ptr, buf.len);
    if (n < 0) return error.NotASymlink;
    return @intCast(n);
}

pub fn deletePathC(gpa: std.mem.Allocator, path: []const u8) void {
    const path_z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(path_z);
    _ = std.c.unlink(path_z);
}

pub fn deleteDirC(gpa: std.mem.Allocator, path: []const u8) void {
    // recursive rmdir via rm -rf would need subprocess; use rmdir for non-recursive
    const path_z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(path_z);
    _ = std.c.rmdir(path_z);
}

pub fn renameC(gpa: std.mem.Allocator, old: []const u8, new: []const u8) !void {
    const old_z = try gpa.dupeZ(u8, old);
    defer gpa.free(old_z);
    const new_z = try gpa.dupeZ(u8, new);
    defer gpa.free(new_z);
    if (std.c.rename(old_z, new_z) != 0) return error.RenameFailed;
}

pub fn mkdirAllC(gpa: std.mem.Allocator, abs_path: []const u8) !void {
    // Create all path components via mkdir
    var i: usize = 1;
    while (i <= abs_path.len) : (i += 1) {
        if (i < abs_path.len and abs_path[i] != '/') continue;
        const segment = abs_path[0..i];
        const seg_z = try gpa.dupeZ(u8, segment);
        defer gpa.free(seg_z);
        _ = std.c.mkdir(seg_z, 0o755); // ignore errors (dir may already exist)
    }
}

pub fn hasSessionKeyCookie(gpa: std.mem.Allocator, base: []const u8) bool {
    const desktop_dir = paths.desktopDirIn(gpa, base) catch return false;
    defer gpa.free(desktop_dir);
    const cookies_path = std.fs.path.join(gpa, &.{ desktop_dir, "Cookies" }) catch return false;
    defer gpa.free(cookies_path);

    if (!pathExists(gpa, cookies_path)) return false;

    const db_path_z = gpa.dupeZ(u8, cookies_path) catch return false;
    defer gpa.free(db_path_z);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(db_path_z, &db, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_close(db);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT 1 FROM cookies WHERE name='sessionKey' LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_finalize(stmt);

    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "hasData false quando dir não existe" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);
    try std.testing.expect(!hasDataIn(alloc, base, "work"));
}

test "hasData true quando dir tem arquivos" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    const dir_path = try paths.desktopProfileDirIn(alloc, base, "work");
    defer alloc.free(dir_path);
    try mkdirAllC(alloc, dir_path);

    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "somefile" });
    defer alloc.free(file_path);
    const fp_z = try alloc.dupeZ(u8, file_path);
    defer alloc.free(fp_z);
    const fd = std.c.open(fp_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) _ = std.c.close(fd);

    try std.testing.expect(hasDataIn(alloc, base, "work"));
}

test "swap move dirs corretamente" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    const dd = try paths.desktopDirIn(alloc, base);
    defer alloc.free(dd);
    const d_personal = try paths.desktopProfileDirIn(alloc, base, "personal");
    defer alloc.free(d_personal);
    const d_work = try paths.desktopProfileDirIn(alloc, base, "work");
    defer alloc.free(d_work);

    try mkdirAllC(alloc, dd);
    const marker_path = try std.fs.path.join(alloc, &.{ dd, "marker" });
    defer alloc.free(marker_path);
    const mp_z = try alloc.dupeZ(u8, marker_path);
    defer alloc.free(mp_z);
    const fd = std.c.open(mp_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) _ = std.c.close(fd);

    try mkdirAllC(alloc, d_personal);
    const pfile_path = try std.fs.path.join(alloc, &.{ d_personal, "pfile" });
    defer alloc.free(pfile_path);
    const pp_z = try alloc.dupeZ(u8, pfile_path);
    defer alloc.free(pp_z);
    const fd2 = std.c.open(pp_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    if (fd2 >= 0) _ = std.c.close(fd2);

    try swapIn(alloc, base, "work", "personal");

    const dd_pfile = try std.fs.path.join(alloc, &.{ dd, "pfile" });
    defer alloc.free(dd_pfile);
    try std.testing.expect(pathExists(alloc, dd_pfile));

    const work_marker = try std.fs.path.join(alloc, &.{ d_work, "marker" });
    defer alloc.free(work_marker);
    try std.testing.expect(pathExists(alloc, work_marker));
}

test "getSessionKey decripta cookie" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    const raw_key = "test_storage_key";
    const token = "sk-ant-sid01-test-token-abc123";
    try makeCookiesDb(alloc, base, raw_key, token);

    const result = try getSessionKeyWithKeyIn(alloc, base, raw_key);
    defer alloc.free(result);
    try std.testing.expectEqualStrings(token, result);
}

test "getSessionKey encontra sk-ant no meio de ruído" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    try makeCookiesDb(alloc, base, "key", "\x00\x01noise\x00sk-ant-sid01-real-token");
    const result = try getSessionKeyWithKeyIn(alloc, base, "key");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("sk-ant-sid01-real-token", result);
}

test "getSessionKey falha quando DB não existe" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);
    try std.testing.expectError(error.CookiesDbNotFound, getSessionKeyWithKeyIn(alloc, base, "key"));
}

fn makeCookiesDb(alloc: std.mem.Allocator, base: []const u8, raw_key: []const u8, token: []const u8) !void {
    const claude_dir = try paths.desktopDirIn(alloc, base);
    defer alloc.free(claude_dir);
    try mkdirAllC(alloc, claude_dir);

    const db_path = try std.fs.path.join(alloc, &.{ claude_dir, "Cookies" });
    defer alloc.free(db_path);

    const key = crypto.deriveKey(raw_key);
    const encrypted = try crypto.encryptV10(alloc, token, key);
    defer alloc.free(encrypted);

    const db_path_z = try alloc.dupeZ(u8, db_path);
    defer alloc.free(db_path_z);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(db_path_z, &db) != c.SQLITE_OK) return error.SqliteOpenFailed;
    defer _ = c.sqlite3_close(db);

    if (c.sqlite3_exec(db, "CREATE TABLE cookies (name TEXT, encrypted_value BLOB)", null, null, null) != c.SQLITE_OK)
        return error.SqliteExecFailed;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "INSERT INTO cookies (name, encrypted_value) VALUES ('sessionKey', ?)", -1, &stmt, null) != c.SQLITE_OK)
        return error.SqlitePrepFailed;
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_bind_blob(stmt, 1, encrypted.ptr, @intCast(encrypted.len), c.SQLITE_STATIC) != c.SQLITE_OK)
        return error.SqliteBindFailed;
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

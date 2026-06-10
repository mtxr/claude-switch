//! paths.zig — construtores de caminhos do filesystem
//!
//! Em Rust, PathBuf é heap-allocated e owned.
//! Em Zig, strings são []u8 ou []const u8 — simples slices de bytes.
//! Funções que constroem paths precisam de um allocator e retornam []const u8.
//! O caller é sempre responsável por `allocator.free`.

const std = @import("std");

/// Retorna o diretório HOME do usuário (alocado — caller libera).
pub fn home(allocator: std.mem.Allocator) ![]const u8 {
    // std.process.getEnvVarOwned aloca a string e retorna erro se a variável não existir
    const val = std.c.getenv("HOME") orelse return error.HomeNotSet;
    return allocator.dupe(u8, std.mem.sliceTo(val, 0));
}

// Variantes `_in` recebem um base explícito (útil em testes com tmpdir)

pub fn claudeJsonIn(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ base, ".claude.json" });
}

pub fn claudeDirIn(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ base, ".claude" });
}

pub fn profileJsonIn(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    // std.fmt.allocPrint é equivalente ao format!() do Rust, mas retorna um slice alocado
    const filename = try std.fmt.allocPrint(allocator, ".claude.{s}.json", .{name});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ base, filename });
}

pub fn profileDirIn(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    const filename = try std.fmt.allocPrint(allocator, ".claude.{s}", .{name});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ base, filename });
}

pub fn desktopDirIn(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ base, "Library", "Application Support", "Claude" });
}

pub fn desktopProfileDirIn(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    const dirname = try std.fmt.allocPrint(allocator, "Claude.{s}", .{name});
    defer allocator.free(dirname);
    return std.fs.path.join(allocator, &.{ base, "Library", "Application Support", dirname });
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "home retorna caminho absoluto" {
    const alloc = std.testing.allocator;
    const h = try home(alloc);
    defer alloc.free(h);
    try std.testing.expect(std.fs.path.isAbsolute(h));
}

test "paths são relativos à base" {
    const alloc = std.testing.allocator;
    const base = "/tmp/testbase";

    const cj = try claudeJsonIn(alloc, base);
    defer alloc.free(cj);
    try std.testing.expectEqualStrings("/tmp/testbase/.claude.json", cj);

    const cd = try claudeDirIn(alloc, base);
    defer alloc.free(cd);
    try std.testing.expectEqualStrings("/tmp/testbase/.claude", cd);

    const pj = try profileJsonIn(alloc, base, "work");
    defer alloc.free(pj);
    try std.testing.expectEqualStrings("/tmp/testbase/.claude.work.json", pj);

    const pd = try profileDirIn(alloc, base, "work");
    defer alloc.free(pd);
    try std.testing.expectEqualStrings("/tmp/testbase/.claude.work", pd);

    const dd = try desktopDirIn(alloc, base);
    defer alloc.free(dd);
    try std.testing.expectEqualStrings("/tmp/testbase/Library/Application Support/Claude", dd);

    const dpd = try desktopProfileDirIn(alloc, base, "work");
    defer alloc.free(dpd);
    try std.testing.expectEqualStrings("/tmp/testbase/Library/Application Support/Claude.work", dpd);
}

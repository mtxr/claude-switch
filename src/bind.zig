//! bind.zig — per-directory profiles (`.csw`) and the shell hook

const std = @import("std");
const completion = @import("completion.zig");
const desktop = @import("desktop.zig");
const display = @import("display.zig");
const paths = @import("paths.zig");
const profile = @import("profile.zig");
const run = @import("run.zig");

pub const BINDING_FILE = ".csw";
pub const BOUND_VAR = "__CSW_BOUND";
pub const WARNED_VAR = "__CSW_WARNED";
const CONFIG_VAR = "CLAUDE_CONFIG_DIR";
const MAX_NAME_LEN = 64;
const MAX_FILE_BYTES = 256;

pub const Shell = completion.Shell;

pub const Syntax = enum { posix, fish };

pub fn syntaxFor(shell: Shell) Syntax {
    return if (shell == .fish) .fish else .posix;
}

const ZSH_HOOK =
    \\__csw_hook() { eval "$(command csw env --from-cwd)"; }
    \\autoload -Uz add-zsh-hook
    \\add-zsh-hook precmd __csw_hook
    \\__csw_hook
    \\
;

const FISH_HOOK =
    \\function __csw_hook --on-event fish_prompt
    \\    command csw env --from-cwd --shell fish | source
    \\end
    \\__csw_hook
    \\
;

const BASH_HOOK =
    \\__csw_hook() { eval "$(command csw env --from-cwd)"; }
    \\case ";${PROMPT_COMMAND};" in
    \\  *";__csw_hook;"*) ;;
    \\  *) PROMPT_COMMAND="__csw_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    \\esac
    \\__csw_hook
    \\
;

pub fn cmdBind(gpa: std.mem.Allocator, name: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    const cwd = try currentDir(gpa);
    defer gpa.free(cwd);
    bindIn(gpa, h, cwd, name) catch |e| {
        switch (e) {
            error.InvalidProfileName => display.print("❌  Invalid profile name '{s}'. Use only A-Z a-z 0-9 . _ - (max {d} chars)\n", .{ name, MAX_NAME_LEN }),
            error.ProfileNotFound => display.print("❌  Profile '{s}' not found. Use: csw save {s}\n", .{ name, name }),
            else => display.print("❌  Could not write {s} in the current directory\n", .{BINDING_FILE}),
        }
        return e;
    };
    const msg = try std.fmt.allocPrint(gpa, "Bound this directory to profile '{s}'", .{name});
    defer gpa.free(msg);
    display.ok(msg);
}

pub fn cmdUnbind(gpa: std.mem.Allocator) !void {
    const cwd = try currentDir(gpa);
    defer gpa.free(cwd);
    if (!try unbindIn(gpa, cwd)) {
        display.print("❌  No {s} file in the current directory\n", .{BINDING_FILE});
        return error.NotBound;
    }
    display.ok("Removed directory binding");
}

pub fn cmdEnvFromCwd(gpa: std.mem.Allocator, io: std.Io, syntax: Syntax) !void {
    const h = paths.home(gpa) catch return;
    defer gpa.free(h);
    const cwd = currentDir(gpa) catch return;
    defer gpa.free(cwd);
    const target = try resolveHookTargetIn(gpa, h, cwd);
    defer if (target) |t| gpa.free(t);
    const bound = envVar(BOUND_VAR);
    const current = envVar(CONFIG_VAR);
    if (target) |dir| {
        run.ensureInnerConfigIn(gpa, dir) catch {};
        if (isNewExport(dir, bound, current)) {
            if (run.profileNameOfDir(dir)) |name| run.reportCredentials(gpa, io, h, dir, name, .hook) catch {};
        }
    }
    const missing = try missingBindingIn(gpa, h, cwd);
    defer if (missing) |m| m.deinit(gpa);
    const key = if (missing) |m| try warnKey(gpa, m) else null;
    defer if (key) |k| gpa.free(k);
    const action = decideWarning(key, envVar(WARNED_VAR), bound, current);
    if (action == .warn) {
        const fallback = if (target) |t| run.profileNameOfDir(t) else null;
        const message = try warningMessage(gpa, missing.?, fallback);
        defer gpa.free(message);
        display.warnErr(message);
    }

    const script = try renderEnv(gpa, syntax, target, bound, current);
    defer gpa.free(script);
    const warned_script = try renderWarned(gpa, syntax, action, key);
    defer gpa.free(warned_script);
    display.print("{s}{s}", .{ script, warned_script });
}

pub fn cmdHook(gpa: std.mem.Allocator, shell_name: []const u8) !void {
    const shell = parseShell(shell_name) orelse {
        display.print("❌  Unsupported shell '{s}'. Use: csw hook zsh | bash | fish\n", .{shell_name});
        return error.UnsupportedShell;
    };
    const script = try renderHook(gpa, shell);
    defer gpa.free(script);
    display.print("{s}", .{script});
}

/// The hook followed by the completions, so one eval sets up both.
pub fn renderHook(gpa: std.mem.Allocator, shell: Shell) ![]u8 {
    const completions = try completion.render(gpa, shell);
    defer gpa.free(completions);
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ hookScript(shell), completions });
}

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |ch| {
        const allowed = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-';
        if (!allowed) return false;
    }
    return true;
}

pub fn parseBinding(content: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const name = std.mem.trim(u8, content[0..line_end], " \t\r");
    if (!isValidName(name)) return null;
    return name;
}

pub const parseShell = completion.parseShell;

pub fn hookScript(shell: Shell) []const u8 {
    return switch (shell) {
        .zsh => ZSH_HOOK,
        .bash => BASH_HOOK,
        .fish => FISH_HOOK,
    };
}

pub fn fishQuote(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '\'');
    for (value) |ch| {
        if (ch == '\'' or ch == '\\') try out.append(gpa, '\\');
        try out.append(gpa, ch);
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

fn quoteFor(gpa: std.mem.Allocator, syntax: Syntax, value: []const u8) ![]u8 {
    return switch (syntax) {
        .posix => shellQuote(gpa, value),
        .fish => fishQuote(gpa, value),
    };
}

fn exportLine(gpa: std.mem.Allocator, syntax: Syntax, name: []const u8, quoted: []const u8) ![]u8 {
    return switch (syntax) {
        .posix => std.fmt.allocPrint(gpa, "export {s}={s}", .{ name, quoted }),
        .fish => std.fmt.allocPrint(gpa, "set -gx {s} {s}", .{ name, quoted }),
    };
}

fn unsetLine(gpa: std.mem.Allocator, syntax: Syntax, name: []const u8) ![]u8 {
    return switch (syntax) {
        .posix => std.fmt.allocPrint(gpa, "unset {s}", .{name}),
        .fish => std.fmt.allocPrint(gpa, "set -e {s}", .{name}),
    };
}

pub fn shellQuote(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(gpa, "'\\''");
        } else {
            try out.append(gpa, ch);
        }
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

fn isHookOwned(bound: ?[]const u8, current: ?[]const u8) bool {
    const cur = current orelse return false;
    const b = bound orelse return false;
    return std.mem.eql(u8, cur, b);
}

/// True when the hook is about to point CLAUDE_CONFIG_DIR at `dir` for the
/// first time in this shell, which is when its credentials must be seeded.
pub fn isNewExport(dir: []const u8, bound: ?[]const u8, current: ?[]const u8) bool {
    if (current != null and !isHookOwned(bound, current)) return false;
    const cur = current orelse return true;
    return !std.mem.eql(u8, cur, dir);
}

/// Renders the eval-able script. `target` is the config dir the hook should use,
/// `bound` the value the hook exported before and `current` the present CLAUDE_CONFIG_DIR.
/// Never overwrites or removes a CLAUDE_CONFIG_DIR set by hand.
pub fn renderEnv(gpa: std.mem.Allocator, syntax: Syntax, target: ?[]const u8, bound: ?[]const u8, current: ?[]const u8) ![]u8 {
    const set_by_hook = isHookOwned(bound, current);
    const user_owned = current != null and !set_by_hook;

    if (target) |dir| {
        if (user_owned) return gpa.dupe(u8, "");
        const quoted = try quoteFor(gpa, syntax, dir);
        defer gpa.free(quoted);
        const config = try exportLine(gpa, syntax, CONFIG_VAR, quoted);
        defer gpa.free(config);
        const bound_line = try exportLine(gpa, syntax, BOUND_VAR, quoted);
        defer gpa.free(bound_line);
        return std.fmt.allocPrint(gpa, "{s}; {s}\n", .{ config, bound_line });
    }

    if (bound == null) return gpa.dupe(u8, "");
    const unset_bound = try unsetLine(gpa, syntax, BOUND_VAR);
    defer gpa.free(unset_bound);
    if (!set_by_hook) return std.fmt.allocPrint(gpa, "{s}\n", .{unset_bound});
    const unset_config = try unsetLine(gpa, syntax, CONFIG_VAR);
    defer gpa.free(unset_config);
    return std.fmt.allocPrint(gpa, "{s}; {s}\n", .{ unset_config, unset_bound });
}

pub fn bindIn(gpa: std.mem.Allocator, base: []const u8, dir: []const u8, name: []const u8) !void {
    if (!isValidName(name)) return error.InvalidProfileName;
    if (!profileExistsIn(gpa, base, name)) return error.ProfileNotFound;
    const file = try bindingPathIn(gpa, dir);
    defer gpa.free(file);
    const content = try std.fmt.allocPrint(gpa, "{s}\n", .{name});
    defer gpa.free(content);
    try writeFile(gpa, file, content);
}

pub fn unbindIn(gpa: std.mem.Allocator, dir: []const u8) !bool {
    const file = try bindingPathIn(gpa, dir);
    defer gpa.free(file);
    const file_z = try gpa.dupeSentinel(u8, file, 0);
    defer gpa.free(file_z);
    return std.c.unlink(file_z) == 0;
}

pub const Binding = struct {
    dir: []u8,
    name: []u8,

    pub fn deinit(self: Binding, gpa: std.mem.Allocator) void {
        gpa.free(self.dir);
        gpa.free(self.name);
    }
};

/// Nearest valid `.csw` walking up from `start`, with the directory that holds it.
pub fn findBindingAtIn(gpa: std.mem.Allocator, start: []const u8) !?Binding {
    var dir: ?[]const u8 = start;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        if (try readBindingIn(gpa, d)) |name| {
            errdefer gpa.free(name);
            return .{ .dir = try gpa.dupe(u8, d), .name = name };
        }
    }
    return null;
}

pub fn findBindingIn(gpa: std.mem.Allocator, start: []const u8) !?[]u8 {
    const binding = (try findBindingAtIn(gpa, start)) orelse return null;
    gpa.free(binding.dir);
    return binding.name;
}

/// The nearest `.csw` when it names a profile that does not exist.
pub fn missingBindingIn(gpa: std.mem.Allocator, base: []const u8, start: []const u8) !?Binding {
    const binding = (try findBindingAtIn(gpa, start)) orelse return null;
    if (profileExistsIn(gpa, base, binding.name)) {
        binding.deinit(gpa);
        return null;
    }
    return binding;
}

pub const WarnAction = enum { none, warn, clear };

pub fn warnKey(gpa: std.mem.Allocator, binding: Binding) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}|{s}", .{ binding.dir, binding.name });
}

/// Decides whether the hook should warn about a dangling `.csw` now. The key of
/// the last warning lives in the shell, so each (directory, name) warns once.
/// A CLAUDE_CONFIG_DIR set by hand silences the hook entirely.
pub fn decideWarning(key: ?[]const u8, warned: ?[]const u8, bound: ?[]const u8, current: ?[]const u8) WarnAction {
    const user_owned = current != null and !isHookOwned(bound, current);
    if (user_owned) return .none;
    if (key) |k| {
        const already = warned != null and std.mem.eql(u8, warned.?, k);
        return if (already) .none else .warn;
    }
    return if (warned != null) .clear else .none;
}

pub fn renderWarned(gpa: std.mem.Allocator, syntax: Syntax, action: WarnAction, key: ?[]const u8) ![]u8 {
    switch (action) {
        .none => return gpa.dupe(u8, ""),
        .clear => {
            const line = try unsetLine(gpa, syntax, WARNED_VAR);
            defer gpa.free(line);
            return std.fmt.allocPrint(gpa, "{s}\n", .{line});
        },
        .warn => {
            const quoted = try quoteFor(gpa, syntax, key.?);
            defer gpa.free(quoted);
            const line = try exportLine(gpa, syntax, WARNED_VAR, quoted);
            defer gpa.free(line);
            return std.fmt.allocPrint(gpa, "{s}\n", .{line});
        },
    }
}

pub fn warningMessage(gpa: std.mem.Allocator, binding: Binding, fallback: ?[]const u8) ![]u8 {
    if (fallback) |name| {
        return std.fmt.allocPrint(gpa, "{s} in {s} names profile '{s}', which does not exist; using '{s}'", .{ BINDING_FILE, binding.dir, binding.name, name });
    }
    return std.fmt.allocPrint(gpa, "{s} in {s} names profile '{s}', which does not exist; no profile is active", .{ BINDING_FILE, binding.dir, binding.name });
}

pub fn resolveHookTargetIn(gpa: std.mem.Allocator, base: []const u8, start: []const u8) !?[]const u8 {
    if (try resolveTargetIn(gpa, base, start)) |bound| return bound;
    const active = (try profile.currentIn(gpa, base)) orelse return null;
    defer gpa.free(active);
    if (!profileExistsIn(gpa, base, active)) return null;
    return try paths.profileDirIn(gpa, base, active);
}

pub fn resolveTargetIn(gpa: std.mem.Allocator, base: []const u8, start: []const u8) !?[]const u8 {
    const name = (try findBindingIn(gpa, start)) orelse return null;
    defer gpa.free(name);
    if (!profileExistsIn(gpa, base, name)) return null;
    return try paths.profileDirIn(gpa, base, name);
}

pub fn profileExistsIn(gpa: std.mem.Allocator, base: []const u8, name: []const u8) bool {
    const p_json = paths.profileJsonIn(gpa, base, name) catch return false;
    defer gpa.free(p_json);
    return desktop.pathExists(gpa, p_json);
}

fn bindingPathIn(gpa: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ dir, BINDING_FILE });
}

fn readBindingIn(gpa: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const file = try bindingPathIn(gpa, dir);
    defer gpa.free(file);
    const file_z = try gpa.dupeSentinel(u8, file, 0);
    defer gpa.free(file_z);
    const fd = std.c.open(file_z, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var buf: [MAX_FILE_BYTES]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const name = parseBinding(buf[0..@intCast(n)]) orelse return null;
    return try gpa.dupe(u8, name);
}

fn writeFile(gpa: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.WriteFailed;
    defer _ = std.c.close(fd);
    const n = std.c.write(fd, content.ptr, content.len);
    if (n != content.len) return error.WriteFailed;
}

pub fn currentDir(gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return error.CwdUnavailable;
    return gpa.dupe(u8, std.mem.sliceTo(cwd, 0));
}

pub fn envVar(name: [*:0]const u8) ?[]const u8 {
    const val = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(val, 0);
}

fn tmpBase(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.Options.debug_io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

fn touch(alloc: std.mem.Allocator, path: []const u8) !void {
    try writeFile(alloc, path, "{}");
}

test "decideWarning warns once per key and clears when no longer dangling" {
    try std.testing.expectEqual(WarnAction.warn, decideWarning("d|x", null, null, null));
    try std.testing.expectEqual(WarnAction.warn, decideWarning("d|y", "d|x", null, null));
    try std.testing.expectEqual(WarnAction.none, decideWarning("d|x", "d|x", null, null));
    try std.testing.expectEqual(WarnAction.clear, decideWarning(null, "d|x", null, null));
    try std.testing.expectEqual(WarnAction.none, decideWarning(null, null, null, null));
}

test "decideWarning stays silent for a CLAUDE_CONFIG_DIR set by hand" {
    try std.testing.expectEqual(WarnAction.none, decideWarning("d|x", null, null, "/manual"));
    try std.testing.expectEqual(WarnAction.none, decideWarning("d|x", null, "/h/.claude.a", "/manual"));
    try std.testing.expectEqual(WarnAction.warn, decideWarning("d|x", null, "/h/.claude.a", "/h/.claude.a"));
}

test "renderWarned exports the key, unsets it or stays empty" {
    const alloc = std.testing.allocator;
    const none = try renderWarned(alloc, .posix, .none, null);
    defer alloc.free(none);
    try std.testing.expectEqualStrings("", none);
    const clear = try renderWarned(alloc, .posix, .clear, null);
    defer alloc.free(clear);
    try std.testing.expectEqualStrings("unset __CSW_WARNED\n", clear);
    const warn = try renderWarned(alloc, .posix, .warn, "/p'q|x");
    defer alloc.free(warn);
    try std.testing.expectEqualStrings("export __CSW_WARNED='/p'\\''q|x'\n", warn);
}

test "warningMessage names the fallback or the lack of one" {
    const alloc = std.testing.allocator;
    var dir = [_]u8{ '/', 'p' };
    var name = [_]u8{'x'};
    const binding: Binding = .{ .dir = &dir, .name = &name };
    const with = try warningMessage(alloc, binding, "work");
    defer alloc.free(with);
    try std.testing.expectEqualStrings(".csw in /p names profile 'x', which does not exist; using 'work'", with);
    const without = try warningMessage(alloc, binding, null);
    defer alloc.free(without);
    try std.testing.expectEqualStrings(".csw in /p names profile 'x', which does not exist; no profile is active", without);
}

test "warnKey joins directory and name" {
    const alloc = std.testing.allocator;
    var dir = [_]u8{ '/', 'p' };
    var name = [_]u8{'x'};
    const key = try warnKey(alloc, .{ .dir = &dir, .name = &name });
    defer alloc.free(key);
    try std.testing.expectEqualStrings("/p|x", key);
}

test "missingBindingIn reports only a dangling nearest binding" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    const proj = try std.fs.path.join(alloc, &.{ base, "proj" });
    defer alloc.free(proj);
    try desktop.mkdirAllC(alloc, proj);

    const file = try bindingPathIn(alloc, proj);
    defer alloc.free(file);
    try writeFile(alloc, file, "ghost\n");
    const missing = (try missingBindingIn(alloc, base, proj)).?;
    defer missing.deinit(alloc);
    try std.testing.expectEqualStrings("ghost", missing.name);
    try std.testing.expectEqualStrings(proj, missing.dir);

    const pj = try paths.profileJsonIn(alloc, base, "ghost");
    defer alloc.free(pj);
    try touch(alloc, pj);
    try std.testing.expect(try missingBindingIn(alloc, base, proj) == null);
}

test "isValidName accepts and rejects" {
    try std.testing.expect(isValidName("work"));
    try std.testing.expect(isValidName("a.b_c-1"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("."));
    try std.testing.expect(!isValidName(".."));
    try std.testing.expect(!isValidName("a/b"));
    try std.testing.expect(!isValidName("a b"));
    try std.testing.expect(!isValidName("a;rm"));
    try std.testing.expect(!isValidName("$(x)"));
    const too_long: [65]u8 = @splat('a');
    const longest: [64]u8 = @splat('a');
    try std.testing.expect(!isValidName(&too_long));
    try std.testing.expect(isValidName(&longest));
}

test "parseBinding uses the first validated line" {
    try std.testing.expectEqualStrings("work", parseBinding("work\n").?);
    try std.testing.expectEqualStrings("work", parseBinding("  work \r\nignored").?);
    try std.testing.expectEqualStrings("work", parseBinding("work").?);
    try std.testing.expect(parseBinding("") == null);
    try std.testing.expect(parseBinding("\nwork") == null);
    try std.testing.expect(parseBinding("$(evil)\n") == null);
    try std.testing.expect(parseBinding("../x\n") == null);
}

test "isNewExport fires only for the first export of a dir" {
    try std.testing.expect(isNewExport("/h/.claude.a", null, null));
    try std.testing.expect(isNewExport("/h/.claude.b", "/h/.claude.a", "/h/.claude.a"));
    try std.testing.expect(!isNewExport("/h/.claude.a", "/h/.claude.a", "/h/.claude.a"));
    try std.testing.expect(!isNewExport("/h/.claude.a", null, "/h/.claude.manual"));
}

test "renderHook appends the completions to the hook" {
    const alloc = std.testing.allocator;
    for ([_]Shell{ .zsh, .bash, .fish }) |shell| {
        const script = try renderHook(alloc, shell);
        defer alloc.free(script);
        try std.testing.expect(std.mem.startsWith(u8, script, hookScript(shell)));
        const marker = if (shell == .fish) "function __csw_command_is" else "_csw()";
        try std.testing.expect(std.mem.indexOf(u8, script, marker) != null);
    }
}

test "parseShell and hookScript" {
    try std.testing.expectEqual(Shell.zsh, parseShell("zsh").?);
    try std.testing.expectEqual(Shell.bash, parseShell("bash").?);
    try std.testing.expectEqual(Shell.fish, parseShell("fish").?);
    try std.testing.expect(parseShell("nushell") == null);
    try std.testing.expect(std.mem.indexOf(u8, hookScript(.zsh), "add-zsh-hook precmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, hookScript(.bash), "PROMPT_COMMAND") != null);
    try std.testing.expect(std.mem.indexOf(u8, hookScript(.zsh), "csw env --from-cwd") != null);
    try std.testing.expect(std.mem.indexOf(u8, hookScript(.fish), "--on-event fish_prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, hookScript(.fish), "csw env --from-cwd --shell fish | source") != null);
}

test "syntaxFor maps fish to fish syntax and the rest to posix" {
    try std.testing.expectEqual(Syntax.fish, syntaxFor(.fish));
    try std.testing.expectEqual(Syntax.posix, syntaxFor(.zsh));
    try std.testing.expectEqual(Syntax.posix, syntaxFor(.bash));
}

test "fishQuote escapes quotes and backslashes" {
    const alloc = std.testing.allocator;
    const plain = try fishQuote(alloc, "/home/u/.claude.work");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("'/home/u/.claude.work'", plain);
    const tricky = try fishQuote(alloc, "a'b\\c");
    defer alloc.free(tricky);
    try std.testing.expectEqualStrings("'a\\'b\\\\c'", tricky);
}

test "renderEnv in fish syntax sets, replaces and unsets like the posix one" {
    const alloc = std.testing.allocator;
    const set = try renderEnv(alloc, .fish, "/h/.claude.work", null, null);
    defer alloc.free(set);
    try std.testing.expectEqualStrings("set -gx CLAUDE_CONFIG_DIR '/h/.claude.work'; set -gx __CSW_BOUND '/h/.claude.work'\n", set);

    const replace = try renderEnv(alloc, .fish, "/h/.claude.b", "/h/.claude.a", "/h/.claude.a");
    defer alloc.free(replace);
    try std.testing.expect(std.mem.startsWith(u8, replace, "set -gx CLAUDE_CONFIG_DIR '/h/.claude.b'"));

    const manual = try renderEnv(alloc, .fish, "/h/.claude.work", null, "/manual");
    defer alloc.free(manual);
    try std.testing.expectEqualStrings("", manual);

    const hook_set = try renderEnv(alloc, .fish, null, "/h/.claude.a", "/h/.claude.a");
    defer alloc.free(hook_set);
    try std.testing.expectEqualStrings("set -e CLAUDE_CONFIG_DIR; set -e __CSW_BOUND\n", hook_set);

    const user_override = try renderEnv(alloc, .fish, null, "/h/.claude.a", "/manual");
    defer alloc.free(user_override);
    try std.testing.expectEqualStrings("set -e __CSW_BOUND\n", user_override);

    const idle = try renderEnv(alloc, .fish, null, null, null);
    defer alloc.free(idle);
    try std.testing.expectEqualStrings("", idle);
}

test "renderWarned in fish syntax" {
    const alloc = std.testing.allocator;
    const none = try renderWarned(alloc, .fish, .none, null);
    defer alloc.free(none);
    try std.testing.expectEqualStrings("", none);
    const clear = try renderWarned(alloc, .fish, .clear, null);
    defer alloc.free(clear);
    try std.testing.expectEqualStrings("set -e __CSW_WARNED\n", clear);
    const warn = try renderWarned(alloc, .fish, .warn, "/p'q|x");
    defer alloc.free(warn);
    try std.testing.expectEqualStrings("set -gx __CSW_WARNED '/p\\'q|x'\n", warn);
}

test "shellQuote escapes single quotes" {
    const alloc = std.testing.allocator;
    const plain = try shellQuote(alloc, "/home/u/.claude.work");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("'/home/u/.claude.work'", plain);
    const tricky = try shellQuote(alloc, "a'b c");
    defer alloc.free(tricky);
    try std.testing.expectEqualStrings("'a'\\''b c'", tricky);
}

test "renderEnv exports when the user set nothing" {
    const alloc = std.testing.allocator;
    const out = try renderEnv(alloc, .posix, "/h/.claude.work", null, null);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("export CLAUDE_CONFIG_DIR='/h/.claude.work'; export __CSW_BOUND='/h/.claude.work'\n", out);
}

test "renderEnv replaces a value set by the hook itself" {
    const alloc = std.testing.allocator;
    const out = try renderEnv(alloc, .posix, "/h/.claude.b", "/h/.claude.a", "/h/.claude.a");
    defer alloc.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "export CLAUDE_CONFIG_DIR='/h/.claude.b'"));
}

test "renderEnv does not overwrite a manual CLAUDE_CONFIG_DIR" {
    const alloc = std.testing.allocator;
    const without_bound = try renderEnv(alloc, .posix, "/h/.claude.work", null, "/manual");
    defer alloc.free(without_bound);
    try std.testing.expectEqualStrings("", without_bound);
    const stale_bound = try renderEnv(alloc, .posix, "/h/.claude.work", "/h/.claude.a", "/manual");
    defer alloc.free(stale_bound);
    try std.testing.expectEqualStrings("", stale_bound);
}

test "renderEnv removes only what the hook set" {
    const alloc = std.testing.allocator;
    const hook_set = try renderEnv(alloc, .posix, null, "/h/.claude.a", "/h/.claude.a");
    defer alloc.free(hook_set);
    try std.testing.expectEqualStrings("unset CLAUDE_CONFIG_DIR; unset __CSW_BOUND\n", hook_set);
    const user_override = try renderEnv(alloc, .posix, null, "/h/.claude.a", "/manual");
    defer alloc.free(user_override);
    try std.testing.expectEqualStrings("unset __CSW_BOUND\n", user_override);
    const bound_only = try renderEnv(alloc, .posix, null, "/h/.claude.a", null);
    defer alloc.free(bound_only);
    try std.testing.expectEqualStrings("unset __CSW_BOUND\n", bound_only);
}

test "renderEnv with nothing to do" {
    const alloc = std.testing.allocator;
    const idle = try renderEnv(alloc, .posix, null, null, null);
    defer alloc.free(idle);
    try std.testing.expectEqualStrings("", idle);
    const manual_only = try renderEnv(alloc, .posix, null, null, "/manual");
    defer alloc.free(manual_only);
    try std.testing.expectEqualStrings("", manual_only);
}

test "bindIn validates the name and profile and writes .csw" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    try std.testing.expectError(error.InvalidProfileName, bindIn(alloc, base, base, "a/b"));
    try std.testing.expectError(error.ProfileNotFound, bindIn(alloc, base, base, "work"));

    const pj = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(pj);
    try touch(alloc, pj);
    try bindIn(alloc, base, base, "work");

    const found = (try readBindingIn(alloc, base)).?;
    defer alloc.free(found);
    try std.testing.expectEqualStrings("work", found);
}

test "bindIn fails in a missing directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    const pj = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(pj);
    try touch(alloc, pj);
    const missing = try std.fs.path.join(alloc, &.{ base, "nope" });
    defer alloc.free(missing);
    try std.testing.expectError(error.WriteFailed, bindIn(alloc, base, missing, "work"));
}

test "unbindIn removes .csw and reports absence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    try std.testing.expect(!try unbindIn(alloc, base));
    const file = try bindingPathIn(alloc, base);
    defer alloc.free(file);
    try writeFile(alloc, file, "work\n");
    try std.testing.expect(try unbindIn(alloc, base));
    try std.testing.expect(!try unbindIn(alloc, base));
}

test "findBindingIn walks up to the nearest .csw" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    const deep = try std.fs.path.join(alloc, &.{ base, "a", "b", "c" });
    defer alloc.free(deep);
    try desktop.mkdirAllC(alloc, deep);
    const mid = try std.fs.path.join(alloc, &.{ base, "a", "b" });
    defer alloc.free(mid);

    const outer = try bindingPathIn(alloc, base);
    defer alloc.free(outer);
    try writeFile(alloc, outer, "outer\n");
    const from_deep = (try findBindingIn(alloc, deep)).?;
    defer alloc.free(from_deep);
    try std.testing.expectEqualStrings("outer", from_deep);

    const inner = try bindingPathIn(alloc, mid);
    defer alloc.free(inner);
    try writeFile(alloc, inner, "inner\n");
    const nearest = (try findBindingIn(alloc, deep)).?;
    defer alloc.free(nearest);
    try std.testing.expectEqualStrings("inner", nearest);
}

test "readBindingIn ignores a malicious or empty .csw" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    const file = try bindingPathIn(alloc, base);
    defer alloc.free(file);
    try writeFile(alloc, file, "x'; rm -rf ~; '\n");
    try std.testing.expect(try readBindingIn(alloc, base) == null);
    try writeFile(alloc, file, "");
    try std.testing.expect(try readBindingIn(alloc, base) == null);
}

test "resolveTargetIn requires an existing profile" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    const proj = try std.fs.path.join(alloc, &.{ base, "proj" });
    defer alloc.free(proj);
    try desktop.mkdirAllC(alloc, proj);
    const file = try bindingPathIn(alloc, proj);
    defer alloc.free(file);
    try writeFile(alloc, file, "work\n");

    try std.testing.expect(try resolveTargetIn(alloc, base, proj) == null);

    const pj = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(pj);
    try touch(alloc, pj);
    const target = (try resolveTargetIn(alloc, base, proj)).?;
    defer alloc.free(target);
    const expected = try paths.profileDirIn(alloc, base, "work");
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, target);
}

test "resolveTargetIn without .csw returns null" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);
    try std.testing.expect(try resolveTargetIn(alloc, base, base) == null);
}

test "resolveHookTargetIn falls back to the active profile" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    try std.testing.expect(try resolveHookTargetIn(alloc, base, base) == null);

    const pj = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(pj);
    try touch(alloc, pj);
    const link = try paths.claudeJsonIn(alloc, base);
    defer alloc.free(link);
    const pj_z = try alloc.dupeSentinel(u8, pj, 0);
    defer alloc.free(pj_z);
    const link_z = try alloc.dupeSentinel(u8, link, 0);
    defer alloc.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(pj_z, link_z));

    const target = (try resolveHookTargetIn(alloc, base, base)).?;
    defer alloc.free(target);
    const expected = try paths.profileDirIn(alloc, base, "work");
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, target);
}

test "resolveHookTargetIn prefers a .csw binding over the active profile" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBase(alloc, &tmp);
    defer alloc.free(base);

    for ([_][]const u8{ "work", "home" }) |name| {
        const pj = try paths.profileJsonIn(alloc, base, name);
        defer alloc.free(pj);
        try touch(alloc, pj);
    }
    const work_json = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(work_json);
    const link = try paths.claudeJsonIn(alloc, base);
    defer alloc.free(link);
    const work_z = try alloc.dupeSentinel(u8, work_json, 0);
    defer alloc.free(work_z);
    const link_z = try alloc.dupeSentinel(u8, link, 0);
    defer alloc.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(work_z, link_z));

    const proj = try std.fs.path.join(alloc, &.{ base, "proj" });
    defer alloc.free(proj);
    try desktop.mkdirAllC(alloc, proj);
    const file = try bindingPathIn(alloc, proj);
    defer alloc.free(file);
    try writeFile(alloc, file, "home\n");

    const target = (try resolveHookTargetIn(alloc, base, proj)).?;
    defer alloc.free(target);
    const expected = try paths.profileDirIn(alloc, base, "home");
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, target);
}

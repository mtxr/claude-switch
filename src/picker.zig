//! picker.zig — picker command lookup and the built-in line-based fallback

const std = @import("std");

pub const COMMANDS = [_][]const u8{ "sk", "fzf" };
const TTY_PATH = "/dev/tty";

pub const Probe = *const fn ([:0]const u8) bool;

pub fn isExecutable(path: [:0]const u8) bool {
    return std.c.access(path.ptr, std.c.X_OK) == 0;
}

/// First of sk, fzf found as an executable in `path_env`, preferring sk.
pub fn findCommand(path_env: ?[]const u8, probe: Probe) ?[]const u8 {
    const path = path_env orelse return null;
    for (COMMANDS) |cmd| {
        var dirs = std.mem.splitScalar(u8, path, ':');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, cmd }, 0) catch continue;
            if (probe(full)) return cmd;
        }
    }
    return null;
}

pub fn systemCommand() ?[]const u8 {
    const path = std.c.getenv("PATH") orelse return null;
    return findCommand(std.mem.sliceTo(path, 0), isExecutable);
}

pub const Decision = union(enum) {
    cancel,
    none,
    pick: usize,
    narrow: []usize,
};

/// Interprets one line typed at the built-in picker. `shown` holds the indexes
/// into `names` currently listed, so a number refers to the displayed position.
/// A `narrow` result is owned by the caller.
pub fn decide(gpa: std.mem.Allocator, input: []const u8, names: []const []const u8, shown: []const usize) !Decision {
    const text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len == 0) return .cancel;

    if (std.fmt.parseInt(usize, text, 10)) |number| {
        if (number >= 1 and number <= shown.len) return .{ .pick = shown[number - 1] };
        return .none;
    } else |_| {}

    for (shown) |index| {
        if (std.mem.eql(u8, names[index], text)) return .{ .pick = index };
    }

    var matches: std.ArrayList(usize) = .empty;
    errdefer matches.deinit(gpa);
    for (shown) |index| {
        if (std.ascii.findIgnoreCase(names[index], text) != null) try matches.append(gpa, index);
    }
    if (matches.items.len == 0) {
        matches.deinit(gpa);
        return .none;
    }
    if (matches.items.len == 1) {
        const only = matches.items[0];
        matches.deinit(gpa);
        return .{ .pick = only };
    }
    return .{ .narrow = try matches.toOwnedSlice(gpa) };
}

/// Runs the numbered-list picker on `term`, which provides `print` and
/// `readLine`. Returns the chosen index into `names`, or null when cancelled.
pub fn interact(gpa: std.mem.Allocator, term: anytype, names: []const []const u8, lines: []const []const u8, prompt: []const u8) !?usize {
    var shown = try gpa.alloc(usize, names.len);
    defer gpa.free(shown);
    for (shown, 0..) |*slot, i| slot.* = i;

    while (true) {
        for (shown, 1..) |index, number| term.print("  {d}) {s}\n", .{ number, lines[index] });
        term.print("{s}", .{prompt});
        var buf: [256]u8 = undefined;
        const line = term.readLine(&buf) orelse return null;
        switch (try decide(gpa, line, names, shown)) {
            .cancel => return null,
            .pick => |index| return index,
            .none => term.print("No match for '{s}'.\n", .{std.mem.trim(u8, line, " \t\r\n")}),
            .narrow => |matches| {
                gpa.free(shown);
                shown = matches;
            },
        }
    }
}

pub const Terminal = struct {
    fd: c_int,

    pub fn open() ?Terminal {
        return openPath(TTY_PATH);
    }

    pub fn openPath(path: [:0]const u8) ?Terminal {
        const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR });
        if (fd < 0) return null;
        return .{ .fd = fd };
    }

    pub fn close(self: Terminal) void {
        _ = std.c.close(self.fd);
    }

    pub fn print(self: Terminal, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = std.c.write(self.fd, text.ptr, text.len);
    }

    pub fn readLine(self: Terminal, buf: []u8) ?[]const u8 {
        var len: usize = 0;
        var seen_any = false;
        while (true) {
            var byte: [1]u8 = undefined;
            if (std.c.read(self.fd, &byte, 1) <= 0) break;
            seen_any = true;
            if (byte[0] == '\n') break;
            if (len < buf.len) {
                buf[len] = byte[0];
                len += 1;
            }
        }
        if (!seen_any) return null;
        return buf[0..len];
    }
};

const Scripted = struct {
    input: []const []const u8,
    next: usize = 0,
    output: std.ArrayList(u8) = .empty,

    fn print(self: *Scripted, comptime fmt: []const u8, args: anytype) void {
        self.output.print(std.testing.allocator, fmt, args) catch unreachable;
    }

    fn readLine(self: *Scripted, buf: []u8) ?[]const u8 {
        if (self.next >= self.input.len) return null;
        const line = self.input[self.next];
        self.next += 1;
        @memcpy(buf[0..line.len], line);
        return buf[0..line.len];
    }

    fn deinit(self: *Scripted) void {
        self.output.deinit(std.testing.allocator);
    }
};

const sample_names = [_][]const u8{ "work", "personal", "Workshop" };
const sample_lines = [_][]const u8{ "work    \tme@work.com", "personal", "Workshop" };

fn onlyOptFzf(path: [:0]const u8) bool {
    return std.mem.eql(u8, path, "/opt/bin/fzf");
}

fn skInBFzfInA(path: [:0]const u8) bool {
    return std.mem.eql(u8, path, "/b/sk") or std.mem.eql(u8, path, "/a/fzf");
}

fn nothingExecutable(path: [:0]const u8) bool {
    _ = path;
    return false;
}

test "findCommand scans PATH entries and prefers sk" {
    try std.testing.expectEqualStrings("fzf", findCommand("/usr/bin:/opt/bin", onlyOptFzf).?);
    try std.testing.expectEqualStrings("sk", findCommand("/a:/b", skInBFzfInA).?);
    try std.testing.expectEqual(@as(?[]const u8, null), findCommand("/a:/b", nothingExecutable));
    try std.testing.expectEqual(@as(?[]const u8, null), findCommand(null, onlyOptFzf));
    try std.testing.expectEqual(@as(?[]const u8, null), findCommand("::", onlyOptFzf));
}

test "findCommand skips entries too long for a path buffer" {
    const alloc = std.testing.allocator;
    const long = try alloc.alloc(u8, std.fs.max_path_bytes + 16);
    defer alloc.free(long);
    @memset(long, 'a');
    try std.testing.expectEqual(@as(?[]const u8, null), findCommand(long, onlyOptFzf));
}

test "isExecutable distinguishes executables from other files" {
    try std.testing.expect(isExecutable("/bin/sh"));
    try std.testing.expect(!isExecutable("/nonexistent/csw-picker-test"));
}

test "systemCommand never fails whatever PATH holds" {
    _ = systemCommand();
}

test "decide cancels on empty input" {
    const alloc = std.testing.allocator;
    const decision = try decide(alloc, "  \n", &sample_names, &.{ 0, 1, 2 });
    try std.testing.expectEqual(Decision.cancel, decision);
}

test "decide picks by displayed number and rejects out-of-range numbers" {
    const alloc = std.testing.allocator;
    const first = try decide(alloc, "1", &sample_names, &.{ 0, 1, 2 });
    try std.testing.expectEqual(@as(usize, 0), first.pick);
    const narrowed = try decide(alloc, "2", &sample_names, &.{ 2, 0 });
    try std.testing.expectEqual(@as(usize, 0), narrowed.pick);
    try std.testing.expectEqual(Decision.none, try decide(alloc, "0", &sample_names, &.{ 0, 1, 2 }));
    try std.testing.expectEqual(Decision.none, try decide(alloc, "4", &sample_names, &.{ 0, 1, 2 }));
}

test "decide picks an exact name even when it is a substring of another" {
    const alloc = std.testing.allocator;
    const decision = try decide(alloc, "work", &sample_names, &.{ 0, 1, 2 });
    try std.testing.expectEqual(@as(usize, 0), decision.pick);
}

test "decide picks a unique substring ignoring case" {
    const alloc = std.testing.allocator;
    const decision = try decide(alloc, "PERS", &sample_names, &.{ 0, 1, 2 });
    try std.testing.expectEqual(@as(usize, 1), decision.pick);
}

test "decide narrows an ambiguous filter" {
    const alloc = std.testing.allocator;
    const decision = try decide(alloc, "wor", &sample_names, &.{ 0, 1, 2 });
    defer alloc.free(decision.narrow);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, decision.narrow);
}

test "decide reports no match" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(Decision.none, try decide(alloc, "zzz", &sample_names, &.{ 0, 1, 2 }));
}

test "decide restricts matching to the shown entries" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(Decision.none, try decide(alloc, "personal", &sample_names, &.{ 0, 2 }));
}

test "interact returns the chosen index and lists numbered lines" {
    const alloc = std.testing.allocator;
    var term: Scripted = .{ .input = &.{"2"} };
    defer term.deinit();
    const chosen = try interact(alloc, &term, &sample_names, &sample_lines, "Pick > ");
    try std.testing.expectEqual(@as(?usize, 1), chosen);
    try std.testing.expect(std.mem.indexOf(u8, term.output.items, "  1) work    \tme@work.com\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, term.output.items, "  2) personal\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, term.output.items, "Pick > "));
}

test "interact cancels on empty input and on end of input" {
    const alloc = std.testing.allocator;
    var empty: Scripted = .{ .input = &.{""} };
    defer empty.deinit();
    try std.testing.expectEqual(@as(?usize, null), try interact(alloc, &empty, &sample_names, &sample_lines, "> "));
    var eof: Scripted = .{ .input = &.{} };
    defer eof.deinit();
    try std.testing.expectEqual(@as(?usize, null), try interact(alloc, &eof, &sample_names, &sample_lines, "> "));
}

test "interact re-lists after an ambiguous filter and numbers the narrowed list" {
    const alloc = std.testing.allocator;
    var term: Scripted = .{ .input = &.{ "wor", "2" } };
    defer term.deinit();
    const chosen = try interact(alloc, &term, &sample_names, &sample_lines, "> ");
    try std.testing.expectEqual(@as(?usize, 2), chosen);
    try std.testing.expect(std.mem.indexOf(u8, term.output.items, "  2) Workshop\n") != null);
}

test "interact re-prompts after no match" {
    const alloc = std.testing.allocator;
    var term: Scripted = .{ .input = &.{ "nope", "personal" } };
    defer term.deinit();
    const chosen = try interact(alloc, &term, &sample_names, &sample_lines, "> ");
    try std.testing.expectEqual(@as(?usize, 1), chosen);
    try std.testing.expect(std.mem.indexOf(u8, term.output.items, "No match for 'nope'.\n") != null);
}

const Pipe = struct {
    read: c_int,
    write: c_int,

    fn init() !Pipe {
        var fds: [2]c_int = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        return .{ .read = fds[0], .write = fds[1] };
    }

    fn close(self: Pipe) void {
        _ = std.c.close(self.read);
        _ = std.c.close(self.write);
    }
};

test "Terminal reads lines, truncates long ones and reports end of input" {
    const pipe = try Pipe.init();
    defer pipe.close();
    const term: Terminal = .{ .fd = pipe.read };
    const long_line: [300]u8 = @splat('x');
    const data = try std.fmt.allocPrint(std.testing.allocator, "first\n{s}\nlast", .{&long_line});
    defer std.testing.allocator.free(data);
    _ = std.c.write(pipe.write, data.ptr, data.len);
    _ = std.c.close(pipe.write);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("first", term.readLine(&buf).?);
    try std.testing.expectEqual(@as(usize, 256), term.readLine(&buf).?.len);
    try std.testing.expectEqualStrings("last", term.readLine(&buf).?);
    try std.testing.expectEqual(@as(?[]const u8, null), term.readLine(&buf));
}

test "Terminal prints formatted text to its descriptor" {
    const pipe = try Pipe.init();
    defer pipe.close();
    const term: Terminal = .{ .fd = pipe.write };
    term.print("{d}) {s}\n", .{ 1, "work" });
    var out: [16]u8 = undefined;
    const n = std.c.read(pipe.read, &out, out.len);
    try std.testing.expectEqualStrings("1) work\n", out[0..@intCast(n)]);
}

test "Terminal.print drops text that does not fit its buffer" {
    const pipe = try Pipe.init();
    defer pipe.close();
    const term: Terminal = .{ .fd = pipe.write };
    const long: [2000]u8 = @splat('y');
    term.print("{s}", .{&long});
    _ = std.c.close(pipe.write);
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), std.c.read(pipe.read, &out, out.len));
}

test "Terminal.openPath fails for a missing path and opens an existing one" {
    try std.testing.expectEqual(@as(?Terminal, null), Terminal.openPath("/nonexistent/csw-tty"));
    const term = Terminal.openPath("/dev/null").?;
    term.close();
}

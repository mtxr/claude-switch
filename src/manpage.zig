//! manpage.zig — roff man page generated from the command table

const std = @import("std");
const commands = @import("commands.zig");
const display = @import("display.zig");

const FlagDoc = struct { flag: []const u8, text: []const u8 };

const flag_docs = [_]FlagDoc{
    .{ .flag = "--desktop", .text = "Act on Claude Desktop only. Without a product flag, commands act on Claude Code only." },
    .{ .flag = "--all", .text = "Act on Claude Code and Claude Desktop together." },
    .{ .flag = "--edge", .text = "Install the latest edge build, the rolling pre-release of the main branch, instead of the latest stable release." },
    .{ .flag = "--verbose", .text = "Print the details of each update step." },
    .{ .flag = "--from-cwd", .text = "Print the shell script the hook evaluates for the current directory instead of exporting one profile." },
};

const FileDoc = struct { path: []const u8, text: []const u8 };

const file_docs = [_]FileDoc{
    .{ .path = "~/.claude.<name>.json", .text = "Claude Code account configuration of a saved profile." },
    .{ .path = "~/.claude.<name>/", .text = "Claude Code data directory of a saved profile, used as CLAUDE_CONFIG_DIR." },
    .{ .path = "~/.claude.json, ~/.claude/", .text = "Symlinks to the active profile, moved by csw use." },
    .{ .path = ".csw", .text = "Binding file naming the profile for a directory tree, written by csw bind." },
    .{ .path = "~/Library/Application Support/Claude/.csw-profile", .text = "Marker naming the profile that owns the Claude Desktop data directory (macOS)." },
};

pub fn docFor(flag: []const u8) ?[]const u8 {
    for (flag_docs) |doc| {
        if (std.mem.eql(u8, doc.flag, flag)) return doc.text;
    }
    return null;
}

pub fn cmdMan(gpa: std.mem.Allocator, version: []const u8) !void {
    const page = try render(gpa, version);
    defer gpa.free(page);
    display.print("{s}", .{page});
}

/// Escapes text for roff: backslashes and hyphens always, and a leading dot or
/// quote on a line, which roff would otherwise read as a macro call.
pub fn escape(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var at_line_start = true;
    for (text) |ch| {
        if (at_line_start and (ch == '.' or ch == '\'')) try out.appendSlice(gpa, "\\&");
        switch (ch) {
            '\\' => try out.appendSlice(gpa, "\\e"),
            '-' => try out.appendSlice(gpa, "\\-"),
            '"' => try out.appendSlice(gpa, "\\(dq"),
            else => try out.append(gpa, ch),
        }
        at_line_start = ch == '\n';
    }
}

fn putEscaped(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try escape(gpa, out, text);
}

fn putTagged(gpa: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8) !void {
    try out.appendSlice(gpa, ".TP\n.B \"");
    try putEscaped(gpa, out, label);
    try out.appendSlice(gpa, "\"\n");
}

fn uniqueFlags(gpa: std.mem.Allocator) !std.ArrayList([]const u8) {
    var flags: std.ArrayList([]const u8) = .empty;
    errdefer flags.deinit(gpa);
    for (commands.all) |command| {
        if (command.hidden) continue;
        for (command.flags) |flag| {
            var seen = false;
            for (flags.items) |known| {
                if (std.mem.eql(u8, known, flag)) seen = true;
            }
            if (!seen) try flags.append(gpa, flag);
        }
    }
    return flags;
}

pub fn render(gpa: std.mem.Allocator, version: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, ".TH CSW 1 \"\" \"csw ");
    try putEscaped(gpa, &out, version);
    try out.appendSlice(gpa, "\" \"User Commands\"\n");
    try out.appendSlice(gpa,
        \\.SH NAME
        \\csw \- switch between Claude Code and Claude Desktop accounts
        \\.SH SYNOPSIS
        \\.B csw
        \\.I command
        \\.RI [ options ]
        \\.SH DESCRIPTION
        \\.B csw
        \\saves each Claude account as a named profile and switches between them. Claude Code logins live in the macOS Keychain, in the same per\-directory entries Claude Code itself uses, so several terminals can run different profiles at once through
        \\.BR CLAUDE_CONFIG_DIR .
        \\Commands that take a profile name open an interactive picker when the name is omitted in a terminal.
        \\.SH COMMANDS
        \\
    );
    for (commands.all) |command| {
        if (command.hidden) continue;
        try putTagged(gpa, &out, command.usage);
        try putEscaped(gpa, &out, command.summary);
        try out.append(gpa, '\n');
    }

    var flags = try uniqueFlags(gpa);
    defer flags.deinit(gpa);
    try out.appendSlice(gpa, ".SH OPTIONS\n");
    for (flags.items) |flag| {
        const text = docFor(flag) orelse "";
        try putTagged(gpa, &out, flag);
        try putEscaped(gpa, &out, text);
        try out.append(gpa, '\n');
    }

    try out.appendSlice(gpa, ".SH FILES\n");
    for (file_docs) |doc| {
        try putTagged(gpa, &out, doc.path);
        try putEscaped(gpa, &out, doc.text);
        try out.append(gpa, '\n');
    }

    try out.appendSlice(gpa,
        \\.SH ENVIRONMENT
        \\.TP
        \\.B CLAUDE_CONFIG_DIR
        \\Directory Claude Code uses for its configuration and credentials. The shell hook exports it for the nearest
        \\.B \&.csw
        \\binding and never overwrites a value set by hand.
        \\.SH EXIT STATUS
        \\.B csw
        \\exits with 0 on success and non\-zero when a command fails.
        \\.SH EXAMPLES
        \\.nf
        \\csw save work
        \\csw use work
        \\csw run work \-\- \-p "hello"
        \\csw bind work
        \\eval "$(csw hook zsh)"
        \\.fi
        \\.SH SEE ALSO
        \\.BR claude (1)
        \\
    );
    return out.toOwnedSlice(gpa);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing: {s}\n", .{needle});
        return error.TestExpectedContains;
    }
}

test "escape protects backslashes, hyphens, quotes and leading dots" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try escape(alloc, &out, "a-b \\ \"q\"\n.csw\n'x");
    try std.testing.expectEqualStrings("a\\-b \\e \\(dqq\\(dq\n\\&.csw\n\\&'x", out.items);
}

test "page has the standard sections in order" {
    const alloc = std.testing.allocator;
    const page = try render(alloc, "1.2.3");
    defer alloc.free(page);
    try std.testing.expect(std.mem.startsWith(u8, page, ".TH CSW 1 \"\" \"csw 1.2.3\" \"User Commands\"\n"));
    var cursor: usize = 0;
    for ([_][]const u8{ ".SH NAME", ".SH SYNOPSIS", ".SH DESCRIPTION", ".SH COMMANDS", ".SH OPTIONS", ".SH FILES", ".SH ENVIRONMENT", ".SH EXIT STATUS", ".SH EXAMPLES", ".SH SEE ALSO" }) |heading| {
        const at = std.mem.indexOfPos(u8, page, cursor, heading) orelse return error.TestExpectedContains;
        cursor = at + heading.len;
    }
}

test "every visible command appears with its usage and summary, hidden ones never" {
    const alloc = std.testing.allocator;
    const page = try render(alloc, "1.2.3");
    defer alloc.free(page);
    for (commands.all) |command| {
        var usage: std.ArrayList(u8) = .empty;
        defer usage.deinit(alloc);
        try escape(alloc, &usage, command.usage);
        var summary: std.ArrayList(u8) = .empty;
        defer summary.deinit(alloc);
        try escape(alloc, &summary, command.summary);
        const tag = try std.fmt.allocPrint(alloc, ".B \"{s}\"\n{s}\n", .{ usage.items, summary.items });
        defer alloc.free(tag);
        if (command.hidden) {
            try std.testing.expect(std.mem.indexOf(u8, page, tag) == null);
        } else {
            try expectContains(page, tag);
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, page, "_profiles") == null);
}

test "every flag used by a visible command is documented once" {
    const alloc = std.testing.allocator;
    const page = try render(alloc, "1.2.3");
    defer alloc.free(page);
    var flags = try uniqueFlags(alloc);
    defer flags.deinit(alloc);
    try std.testing.expect(flags.items.len > 0);
    for (flags.items) |flag| {
        try std.testing.expect(docFor(flag) != null);
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(alloc);
        try escape(alloc, &escaped, flag);
        const tag = try std.fmt.allocPrint(alloc, ".B \"{s}\"\n", .{escaped.items});
        defer alloc.free(tag);
        const options_at = std.mem.indexOf(u8, page, ".SH OPTIONS").?;
        const documented = std.mem.indexOfPos(u8, page, options_at, tag).?;
        try std.testing.expect(std.mem.indexOfPos(u8, page, documented + tag.len, tag) == null);
    }
    try std.testing.expect(docFor("--nope") == null);
}

test "hyphens in commands and the dotfile are escaped for roff" {
    const alloc = std.testing.allocator;
    const page = try render(alloc, "1.2.3");
    defer alloc.free(page);
    try expectContains(page, ".B \"logout\\-all\"\n");
    try expectContains(page, ".B \"\\&.csw\"\n");
    try expectContains(page, "CLAUDE_CONFIG_DIR");
}

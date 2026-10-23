//! commands.zig — table of csw commands shared by help, name handling and completions

const std = @import("std");

pub const ArgKind = enum { none, profile, shell };

pub const Command = struct {
    name: []const u8,
    usage: []const u8,
    summary: []const u8,
    arg: ArgKind = .none,
    picks_name: bool = false,
    flags: []const []const u8 = &.{},
    hidden: bool = false,
    skips_update_check: bool = false,
};

const product_flags: []const []const u8 = &.{ "--desktop", "--all" };

pub const all = [_]Command{
    .{ .name = "save", .usage = "save [name]", .summary = "Save the current Claude Code session as a named profile", .arg = .profile, .picks_name = true, .flags = product_flags },
    .{ .name = "use", .usage = "use [name]", .summary = "Switch Claude Code to a saved profile", .arg = .profile, .picks_name = true, .flags = product_flags },
    .{ .name = "switch", .usage = "switch [name]", .summary = "Deprecated alias of use", .arg = .profile, .picks_name = true, .flags = product_flags, .hidden = true },
    .{ .name = "new", .usage = "new <name>", .summary = "Create a new empty profile slot", .flags = product_flags },
    .{ .name = "delete", .usage = "delete [name]", .summary = "Delete a profile", .arg = .profile, .flags = product_flags },
    .{ .name = "list", .usage = "list", .summary = "List all saved profiles", .flags = product_flags },
    .{ .name = "whoami", .usage = "whoami", .summary = "Show active session info" },
    .{ .name = "pick", .usage = "pick", .summary = "Interactive profile picker (sk / fzf)", .flags = product_flags },
    .{ .name = "update", .usage = "update [--verbose]", .summary = "Update csw to the latest release", .flags = &.{"--verbose"}, .skips_update_check = true },
    .{ .name = "logout-all", .usage = "logout-all", .summary = "Log out and remove all active symlinks", .flags = product_flags },
    .{ .name = "run", .usage = "run [name] [-- args]", .summary = "Run claude with a profile in this terminal only", .arg = .profile, .picks_name = true },
    .{ .name = "login", .usage = "login [name]", .summary = "Start claude for a profile and log in once", .arg = .profile, .picks_name = true },
    .{ .name = "env", .usage = "env [name]", .summary = "Print `export CLAUDE_CONFIG_DIR=...` for a profile", .arg = .profile, .picks_name = true, .flags = &.{"--from-cwd"}, .skips_update_check = true },
    .{ .name = "bind", .usage = "bind [name]", .summary = "Bind the current directory to a profile (.csw)", .arg = .profile, .picks_name = true },
    .{ .name = "unbind", .usage = "unbind", .summary = "Remove the .csw binding from the current directory" },
    .{ .name = "hook", .usage = "hook <shell>", .summary = "Print the shell hook with completions (zsh|bash): eval \"$(csw hook zsh)\"", .arg = .shell, .skips_update_check = true },
    .{ .name = "completion", .usage = "completion <shell>", .summary = "Print only the shell completions (zsh|bash)", .arg = .shell, .skips_update_check = true },
    .{ .name = "doctor", .usage = "doctor", .summary = "Check that everything csw needs is in order" },
    .{ .name = "_profiles", .usage = "_profiles", .summary = "Print saved profile names, one per line", .hidden = true, .skips_update_check = true },
};

pub fn find(name: []const u8) ?Command {
    for (all) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

pub fn picksName(name: []const u8) bool {
    const command = find(name) orelse return false;
    return command.picks_name;
}

pub fn skipsUpdateCheck(name: []const u8) bool {
    const command = find(name) orelse return false;
    return command.skips_update_check;
}

const MIN_USAGE_COLUMN = 17;

/// One help line per visible command, aligned like `  save [name]      Save ...`.
pub fn renderHelpLines(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (all) |command| {
        if (command.hidden) continue;
        try out.appendSlice(gpa, "  ");
        try out.appendSlice(gpa, command.usage);
        const column = @max(MIN_USAGE_COLUMN, command.usage.len + 2);
        try out.appendNTimes(gpa, ' ', column - command.usage.len);
        try out.appendSlice(gpa, command.summary);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "command names are unique" {
    for (all, 0..) |command, i| {
        for (all[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, command.name, other.name));
        }
    }
}

test "find, picksName and skipsUpdateCheck read the table" {
    try std.testing.expectEqualStrings("use", find("use").?.name);
    try std.testing.expect(find("nope") == null);
    try std.testing.expect(picksName("use"));
    try std.testing.expect(picksName("switch"));
    try std.testing.expect(!picksName("new"));
    try std.testing.expect(!picksName("delete"));
    try std.testing.expect(!picksName("nope"));
    try std.testing.expect(skipsUpdateCheck("env"));
    try std.testing.expect(skipsUpdateCheck("_profiles"));
    try std.testing.expect(!skipsUpdateCheck("use"));
    try std.testing.expect(!skipsUpdateCheck("nope"));
}

test "hidden commands never reach the help text" {
    const alloc = std.testing.allocator;
    const lines = try renderHelpLines(alloc);
    defer alloc.free(lines);
    try std.testing.expect(std.mem.indexOf(u8, lines, "_profiles") == null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "switch") == null);
    for (all) |command| {
        if (command.hidden) continue;
        try std.testing.expect(std.mem.indexOf(u8, lines, command.usage) != null);
    }
}

test "help lines keep the historical alignment" {
    const alloc = std.testing.allocator;
    const lines = try renderHelpLines(alloc);
    defer alloc.free(lines);
    try std.testing.expect(std.mem.indexOf(u8, lines, "  save [name]      Save the current Claude Code session as a named profile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "  whoami           Show active session info\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "  update [--verbose]  Update csw to the latest release\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "  run [name] [-- args]  Run claude with a profile in this terminal only\n") != null);
}

//! completion.zig — zsh, bash and fish completion scripts generated from the command table

const std = @import("std");
const commands = @import("commands.zig");
const display = @import("display.zig");

pub const Shell = enum { zsh, bash, fish };

pub fn parseShell(name: []const u8) ?Shell {
    return std.meta.stringToEnum(Shell, name);
}

pub fn shellNames() []const []const u8 {
    return std.meta.fieldNames(Shell);
}

pub fn cmdCompletion(gpa: std.mem.Allocator, shell_name: []const u8) !void {
    const shell = parseShell(shell_name) orelse {
        display.print("❌  Unsupported shell '{s}'. Use: csw completion zsh | bash | fish\n", .{shell_name});
        return error.UnsupportedShell;
    };
    const script = try render(gpa, shell);
    defer gpa.free(script);
    display.print("{s}", .{script});
}

pub fn render(gpa: std.mem.Allocator, shell: Shell) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (shell) {
        .zsh => try renderZsh(gpa, &out),
        .bash => try renderBash(gpa, &out),
        .fish => try renderFish(gpa, &out),
    }
    return out.toOwnedSlice(gpa);
}

fn put(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(text);
    try out.appendSlice(gpa, text);
}

fn putJoined(gpa: std.mem.Allocator, out: *std.ArrayList(u8), words: []const []const u8) !void {
    for (words, 0..) |word, i| {
        if (i > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, word);
    }
}

fn putSingleQuoted(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(gpa, '\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice(gpa, "'\\''");
        } else {
            try out.append(gpa, ch);
        }
    }
    try out.append(gpa, '\'');
}

fn putShellWords(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try putJoined(gpa, out, shellNames());
}

const ZSH_HEAD =
    \\#compdef csw
    \\_csw() {
    \\  local cur=${words[CURRENT]} cmd w
    \\  local -a candidates
    \\  local n=0
    \\  if (( CURRENT == 2 )); then
    \\    candidates=(
    \\
;

const ZSH_MIDDLE =
    \\    )
    \\    _describe -t commands 'csw command' candidates
    \\    return
    \\  fi
    \\  cmd=${words[2]}
    \\  for w in ${words[3,CURRENT-1]}; do
    \\    [[ $w == -- ]] && return
    \\    [[ $w == -* ]] || (( n++ ))
    \\  done
    \\  case $cmd in
    \\
;

const ZSH_TAIL =
    \\  esac
    \\}
    \\if [ "$funcstack[1]" = "_csw" ]; then
    \\  _csw "$@"
    \\elif (( $+functions[compdef] )); then
    \\  compdef _csw csw
    \\else
    \\  autoload -Uz add-zsh-hook
    \\  __csw_register() {
    \\    if (( $+functions[compdef] )); then
    \\      compdef _csw csw
    \\      add-zsh-hook -d precmd __csw_register
    \\      unfunction __csw_register
    \\    fi
    \\  }
    \\  add-zsh-hook precmd __csw_register
    \\fi
    \\
;

fn renderZsh(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa, ZSH_HEAD);
    for (commands.all) |command| {
        if (command.hidden) continue;
        const entry = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ command.name, command.summary });
        defer gpa.free(entry);
        try out.appendSlice(gpa, "      ");
        try putSingleQuoted(gpa, out, entry);
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, ZSH_MIDDLE);
    for (commands.all) |command| {
        if (command.flags.len == 0 and command.arg == .none) continue;
        try put(gpa, out, "    {s})\n", .{command.name});
        const has_flags = command.flags.len > 0;
        if (has_flags) {
            try out.appendSlice(gpa, "      if [[ $cur == -* ]]; then\n        compadd -- ");
            try putJoined(gpa, out, command.flags);
            try out.append(gpa, '\n');
        }
        switch (command.arg) {
            .none => {},
            .profile => {
                try out.appendSlice(gpa, if (has_flags) "      elif (( n == 0 )); then\n" else "      if (( n == 0 )); then\n");
                try out.appendSlice(gpa, "        candidates=(${(f)\"$(command csw _profiles 2>/dev/null)\"})\n        compadd -a candidates\n");
            },
            .shell => {
                try out.appendSlice(gpa, if (has_flags) "      elif (( n == 0 )); then\n" else "      if (( n == 0 )); then\n");
                try out.appendSlice(gpa, "        compadd ");
                try putShellWords(gpa, out);
                try out.append(gpa, '\n');
            },
        }
        try out.appendSlice(gpa, "      fi\n      ;;\n");
    }
    try out.appendSlice(gpa, ZSH_TAIL);
}

const BASH_HEAD =
    \\_csw() {
    \\  local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[1]} word
    \\  local n=0
    \\  COMPREPLY=()
    \\  if (( COMP_CWORD == 1 )); then
    \\    COMPREPLY=($(compgen -W "
;

const BASH_MIDDLE =
    \\" -- "$cur"))
    \\    return
    \\  fi
    \\  for word in "${COMP_WORDS[@]:2:COMP_CWORD-2}"; do
    \\    [[ $word == -- ]] && return
    \\    [[ $word == -* ]] || n=$((n + 1))
    \\  done
    \\  case $cmd in
    \\
;

const BASH_TAIL =
    \\  esac
    \\}
    \\complete -F _csw csw
    \\
;

fn renderBash(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa, BASH_HEAD);
    var first = true;
    for (commands.all) |command| {
        if (command.hidden) continue;
        if (!first) try out.append(gpa, ' ');
        try out.appendSlice(gpa, command.name);
        first = false;
    }
    try out.appendSlice(gpa, BASH_MIDDLE);
    for (commands.all) |command| {
        if (command.flags.len == 0 and command.arg == .none) continue;
        try put(gpa, out, "    {s})\n", .{command.name});
        const has_flags = command.flags.len > 0;
        if (has_flags) {
            try out.appendSlice(gpa, "      if [[ $cur == -* ]]; then\n        COMPREPLY=($(compgen -W \"");
            try putJoined(gpa, out, command.flags);
            try out.appendSlice(gpa, "\" -- \"$cur\"))\n");
        }
        switch (command.arg) {
            .none => {},
            .profile => {
                try out.appendSlice(gpa, if (has_flags) "      elif (( n == 0 )); then\n" else "      if (( n == 0 )); then\n");
                try out.appendSlice(gpa, "        COMPREPLY=($(compgen -W \"$(command csw _profiles 2>/dev/null)\" -- \"$cur\"))\n");
            },
            .shell => {
                try out.appendSlice(gpa, if (has_flags) "      elif (( n == 0 )); then\n" else "      if (( n == 0 )); then\n");
                try out.appendSlice(gpa, "        COMPREPLY=($(compgen -W \"");
                try putShellWords(gpa, out);
                try out.appendSlice(gpa, "\" -- \"$cur\"))\n");
            },
        }
        try out.appendSlice(gpa, "      fi\n      ;;\n");
    }
    try out.appendSlice(gpa, BASH_TAIL);
}

fn putFishQuoted(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(gpa, '\'');
    for (text) |ch| {
        if (ch == '\'' or ch == '\\') try out.append(gpa, '\\');
        try out.append(gpa, ch);
    }
    try out.append(gpa, '\'');
}

const FISH_HEAD =
    \\function __csw_command_is
    \\    set -l tokens (commandline -opc)
    \\    test (count $tokens) -ge 2; and contains -- $tokens[2] $argv
    \\end
    \\function __csw_at_first_arg
    \\    set -l tokens (commandline -opc)
    \\    test (count $tokens) -ge 2; or return 1
    \\    set -e tokens[1..2]
    \\    for token in $tokens
    \\        test "$token" = --; and return 1
    \\        string match -q -- '-*' $token; or return 1
    \\    end
    \\    return 0
    \\end
    \\complete -c csw -f
    \\
;

fn putFishCommandList(gpa: std.mem.Allocator, out: *std.ArrayList(u8), arg: commands.ArgKind) !void {
    var first = true;
    for (commands.all) |command| {
        if (command.arg != arg) continue;
        if (!first) try out.append(gpa, ' ');
        try out.appendSlice(gpa, command.name);
        first = false;
    }
}

fn renderFish(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa, FISH_HEAD);
    for (commands.all) |command| {
        if (command.hidden) continue;
        try put(gpa, out, "complete -c csw -n __fish_use_subcommand -a {s} -d ", .{command.name});
        try putFishQuoted(gpa, out, command.summary);
        try out.append(gpa, '\n');
    }
    for (commands.all) |command| {
        for (command.flags) |flag| {
            try put(gpa, out, "complete -c csw -n '__csw_command_is {s}' -l {s}\n", .{ command.name, flag[2..] });
        }
    }
    for ([_]commands.ArgKind{ .profile, .shell }) |kind| {
        try out.appendSlice(gpa, "complete -c csw -n '__csw_command_is ");
        try putFishCommandList(gpa, out, kind);
        try out.appendSlice(gpa, "; and __csw_at_first_arg' -a ");
        switch (kind) {
            .profile => try out.appendSlice(gpa, "'(command csw _profiles 2>/dev/null)'"),
            .shell => {
                try out.append(gpa, '\'');
                try putShellWords(gpa, out);
                try out.append(gpa, '\'');
            },
            .none => unreachable,
        }
        try out.append(gpa, '\n');
    }
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing: {s}\n", .{needle});
        return error.TestExpectedContains;
    }
}

test "parseShell and shellNames" {
    try std.testing.expectEqual(Shell.zsh, parseShell("zsh").?);
    try std.testing.expectEqual(Shell.bash, parseShell("bash").?);
    try std.testing.expectEqual(Shell.fish, parseShell("fish").?);
    try std.testing.expect(parseShell("nushell") == null);
    try std.testing.expectEqual(@as(usize, 3), shellNames().len);
}

test "putSingleQuoted escapes single quotes" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try putSingleQuoted(alloc, &out, "it's");
    try std.testing.expectEqualStrings("'it'\\''s'", out.items);
}

test "zsh script lists every visible command with its description" {
    const alloc = std.testing.allocator;
    const script = try render(alloc, .zsh);
    defer alloc.free(script);
    try std.testing.expect(std.mem.startsWith(u8, script, "#compdef csw\n"));
    try expectContains(script, "_describe -t commands 'csw command' candidates");
    for (commands.all) |command| {
        if (command.hidden) continue;
        const entry = try std.fmt.allocPrint(alloc, "'{s}:{s}'", .{ command.name, command.summary });
        defer alloc.free(entry);
        try expectContains(script, entry);
    }
    try std.testing.expect(std.mem.indexOf(u8, script, "'_profiles:") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "'switch:") == null);
}

test "zsh script offers flags, profiles and shells where they apply" {
    const alloc = std.testing.allocator;
    const script = try render(alloc, .zsh);
    defer alloc.free(script);
    try expectContains(script, "    use)\n      if [[ $cur == -* ]]; then\n        compadd -- --desktop --all\n      elif (( n == 0 )); then\n");
    try expectContains(script, "command csw _profiles 2>/dev/null");
    try expectContains(script, "    env)\n      if [[ $cur == -* ]]; then\n        compadd -- --from-cwd\n");
    try expectContains(script, "    update)\n      if [[ $cur == -* ]]; then\n        compadd -- --edge --verbose\n      fi\n");
    try expectContains(script, "    hook)\n      if (( n == 0 )); then\n        compadd zsh bash fish\n");
    try expectContains(script, "    completion)\n      if (( n == 0 )); then\n        compadd zsh bash fish\n");
    try expectContains(script, "    run)\n      if (( n == 0 )); then\n");
    try std.testing.expect(std.mem.indexOf(u8, script, "    whoami)") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "    new)\n      if [[ $cur == -* ]]; then\n        compadd -- --desktop --all\n      fi\n") != null);
}

test "zsh script registers itself for both eval and fpath use" {
    const alloc = std.testing.allocator;
    const script = try render(alloc, .zsh);
    defer alloc.free(script);
    try expectContains(script, "if [ \"$funcstack[1]\" = \"_csw\" ]; then");
    try expectContains(script, "compdef _csw csw");
    try expectContains(script, "add-zsh-hook precmd __csw_register");
}

test "bash script lists the visible commands and registers itself" {
    const alloc = std.testing.allocator;
    const script = try render(alloc, .bash);
    defer alloc.free(script);
    try expectContains(script, "complete -F _csw csw");
    try expectContains(script, "compgen -W \"save use rename new delete list whoami pick update logout-all run login env bind unbind hook completion man doctor\"");
}

test "bash script offers flags, profiles and shells where they apply" {
    const alloc = std.testing.allocator;
    const script = try render(alloc, .bash);
    defer alloc.free(script);
    try expectContains(script, "    use)\n      if [[ $cur == -* ]]; then\n        COMPREPLY=($(compgen -W \"--desktop --all\" -- \"$cur\"))\n      elif (( n == 0 )); then\n");
    try expectContains(script, "$(command csw _profiles 2>/dev/null)");
    try expectContains(script, "    env)\n      if [[ $cur == -* ]]; then\n        COMPREPLY=($(compgen -W \"--from-cwd\"");
    try expectContains(script, "    hook)\n      if (( n == 0 )); then\n        COMPREPLY=($(compgen -W \"zsh bash fish\"");
    try expectContains(script, "    update)\n      if [[ $cur == -* ]]; then\n        COMPREPLY=($(compgen -W \"--edge --verbose\"");
    try std.testing.expect(std.mem.indexOf(u8, script, "    whoami)") == null);
}

test "putFishQuoted escapes quotes and backslashes" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try putFishQuoted(alloc, &out, "it's a\\b");
    try std.testing.expectEqualStrings("'it\\'s a\\\\b'", out.items);
}

test "fish script lists every visible command with its description" {
    const alloc = std.testing.allocator;
    const script = try render(alloc, .fish);
    defer alloc.free(script);
    try expectContains(script, "complete -c csw -f\n");
    for (commands.all) |command| {
        const entry = try std.fmt.allocPrint(alloc, "complete -c csw -n __fish_use_subcommand -a {s} -d ", .{command.name});
        defer alloc.free(entry);
        if (command.hidden) {
            try std.testing.expect(std.mem.indexOf(u8, script, entry) == null);
        } else {
            try expectContains(script, entry);
        }
    }
    try expectContains(script, "-a use -d 'Switch Claude Code to a saved profile'\n");
    try expectContains(script, "Print `export CLAUDE_CONFIG_DIR=...` for a profile'\n");
}

test "fish script offers flags per command, profiles and shells" {
    const alloc = std.testing.allocator;
    const script = try render(alloc, .fish);
    defer alloc.free(script);
    try expectContains(script, "complete -c csw -n '__csw_command_is use' -l desktop\n");
    try expectContains(script, "complete -c csw -n '__csw_command_is use' -l all\n");
    try expectContains(script, "complete -c csw -n '__csw_command_is env' -l from-cwd\n");
    try expectContains(script, "complete -c csw -n '__csw_command_is update' -l edge\n");
    try expectContains(script, "complete -c csw -n '__csw_command_is update' -l verbose\n");
    try expectContains(script, "-a '(command csw _profiles 2>/dev/null)'\n");
    try expectContains(script, "complete -c csw -n '__csw_command_is hook completion; and __csw_at_first_arg' -a 'zsh bash fish'\n");
    try std.testing.expect(std.mem.indexOf(u8, script, "__csw_command_is whoami") == null);
}

test "fish script offers profiles exactly to the commands that take one" {
    const alloc = std.testing.allocator;
    const script = try render(alloc, .fish);
    defer alloc.free(script);
    const marker = "-a '(command csw _profiles 2>/dev/null)'";
    const marker_at = std.mem.indexOf(u8, script, marker).?;
    const line_start = std.mem.lastIndexOfScalar(u8, script[0..marker_at], '\n').? + 1;
    const prefix = "complete -c csw -n '__csw_command_is ";
    try std.testing.expect(std.mem.startsWith(u8, script[line_start..], prefix));
    const list_end = std.mem.indexOfPos(u8, script, line_start, ";").?;
    var listed = std.mem.splitScalar(u8, script[line_start + prefix.len .. list_end], ' ');
    var count: usize = 0;
    while (listed.next()) |name| {
        try std.testing.expectEqual(commands.ArgKind.profile, commands.find(name).?.arg);
        count += 1;
    }
    var expected: usize = 0;
    for (commands.all) |command| {
        if (command.arg == .profile) expected += 1;
    }
    try std.testing.expectEqual(expected, count);
}

test "every command that takes a profile calls csw _profiles in both scripts" {
    const alloc = std.testing.allocator;
    const zsh = try render(alloc, .zsh);
    defer alloc.free(zsh);
    const bash = try render(alloc, .bash);
    defer alloc.free(bash);
    for (commands.all) |command| {
        if (command.arg != .profile) continue;
        const marker = try std.fmt.allocPrint(alloc, "    {s})\n", .{command.name});
        defer alloc.free(marker);
        try expectContains(zsh, marker);
        try expectContains(bash, marker);
    }
}

//! Mirror user-scoped Claude Code plugins through Claude's own plugin CLI.
//! Account-synced plugins and per-plugin data remain in their own profiles.

const std = @import("std");
const desktop = @import("desktop.zig");
const display = @import("display.zig");
const paths = @import("paths.zig");

pub const SyncResult = struct {
    installed: usize = 0,
    updated: usize = 0,
    toggled: usize = 0,
};

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn boolField(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .bool) field.bool else null;
}

fn items(value: std.json.Value) ![]const std.json.Value {
    if (value != .array) return error.InvalidPluginList;
    return value.array.items;
}

fn findByName(list: []const std.json.Value, key: []const u8, name: []const u8) ?std.json.Value {
    for (list) |item| {
        if (stringField(item, key)) |actual| {
            if (std.mem.eql(u8, actual, name)) return item;
        }
    }
    return null;
}

fn findUserPlugin(list: []const std.json.Value, id: []const u8) ?std.json.Value {
    for (list) |item| {
        const item_id = stringField(item, "id") orelse continue;
        const scope = stringField(item, "scope") orelse continue;
        if (std.mem.eql(u8, item_id, id) and std.mem.eql(u8, scope, "user")) return item;
    }
    return null;
}

fn runClaude(gpa: std.mem.Allocator, io: std.Io, config_dir: []const u8, args: []const []const u8) ![]u8 {
    const env_arg = try std.fmt.allocPrint(gpa, "CLAUDE_CONFIG_DIR={s}", .{config_dir});
    defer gpa.free(env_arg);
    const plugin_dir = try std.fs.path.join(gpa, &.{ config_dir, "plugins" });
    defer gpa.free(plugin_dir);
    const cache_arg = try std.fmt.allocPrint(gpa, "CLAUDE_CODE_PLUGIN_CACHE_DIR={s}", .{plugin_dir});
    defer gpa.free(cache_arg);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "env", env_arg, cache_arg, "claude" });
    try argv.appendSlice(gpa, args);
    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        gpa.free(result.stdout);
        return error.ClaudePluginCommandFailed;
    }
    return result.stdout;
}

fn readList(gpa: std.mem.Allocator, io: std.Io, config_dir: []const u8, args: []const []const u8) !std.json.Parsed(std.json.Value) {
    const output = try runClaude(gpa, io, config_dir, args);
    defer gpa.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, output, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    _ = try items(parsed.value);
    return parsed;
}

fn marketplaceSource(value: std.json.Value) ?[]const u8 {
    const kind = stringField(value, "source") orelse return null;
    if (std.mem.eql(u8, kind, "github")) return stringField(value, "repo");
    if (std.mem.eql(u8, kind, "url")) return stringField(value, "url");
    if (std.mem.eql(u8, kind, "directory")) return stringField(value, "path");
    return null;
}

pub fn syncIn(gpa: std.mem.Allocator, io: std.Io, base: []const u8, source: []const u8, target: []const u8) !SyncResult {
    const source_dir = try paths.profileDirIn(gpa, base, source);
    defer gpa.free(source_dir);
    const target_dir = try paths.profileDirIn(gpa, base, target);
    defer gpa.free(target_dir);
    if (!desktop.pathExists(gpa, source_dir) or !desktop.pathExists(gpa, target_dir)) return error.ProfileNotFound;

    var source_plugins = try readList(gpa, io, source_dir, &.{ "plugin", "list", "--json" });
    defer source_plugins.deinit();
    var target_plugins = try readList(gpa, io, target_dir, &.{ "plugin", "list", "--json" });
    defer target_plugins.deinit();
    var source_markets = try readList(gpa, io, source_dir, &.{ "plugin", "marketplace", "list", "--json" });
    defer source_markets.deinit();
    var target_markets = try readList(gpa, io, target_dir, &.{ "plugin", "marketplace", "list", "--json" });
    defer target_markets.deinit();

    const from = try items(source_plugins.value);
    const to = try items(target_plugins.value);
    const from_markets = try items(source_markets.value);
    const to_markets = try items(target_markets.value);
    var result: SyncResult = .{};
    var added_markets = std.StringHashMap(void).init(gpa);
    defer added_markets.deinit();

    for (from) |plugin| {
        const scope = stringField(plugin, "scope") orelse return error.InvalidPluginList;
        if (!std.mem.eql(u8, scope, "user")) continue;
        const id = stringField(plugin, "id") orelse return error.InvalidPluginList;
        const desired_enabled = boolField(plugin, "enabled") orelse return error.InvalidPluginList;
        const existing = findUserPlugin(to, id);

        if (existing == null) {
            const at = std.mem.lastIndexOfScalar(u8, id, '@') orelse return error.InvalidPluginId;
            const marketplace = id[at + 1 ..];
            if (findByName(to_markets, "name", marketplace) == null and !added_markets.contains(marketplace)) {
                const market = findByName(from_markets, "name", marketplace) orelse return error.MissingSourceMarketplace;
                const origin = marketplaceSource(market) orelse return error.UnsupportedMarketplaceSource;
                display.print("Adding marketplace '{s}' to '{s}'\n", .{ marketplace, target });
                const output = try runClaude(gpa, io, target_dir, &.{ "plugin", "marketplace", "add", origin });
                gpa.free(output);
                try added_markets.put(marketplace, {});
            }
            display.print("Installing '{s}' in '{s}'\n", .{ id, target });
            const output = try runClaude(gpa, io, target_dir, &.{ "plugin", "install", id, "--scope", "user", "--json" });
            gpa.free(output);
            result.installed += 1;
            if (!desired_enabled) {
                const disabled = try runClaude(gpa, io, target_dir, &.{ "plugin", "disable", id, "--scope", "user", "--json" });
                gpa.free(disabled);
                result.toggled += 1;
            }
            continue;
        }

        const actual_enabled = boolField(existing.?, "enabled") orelse return error.InvalidPluginList;
        if (actual_enabled != desired_enabled) {
            display.print("Matching enabled state for '{s}' in '{s}'\n", .{ id, target });
            const action: []const u8 = if (desired_enabled) "enable" else "disable";
            const output = try runClaude(gpa, io, target_dir, &.{ "plugin", action, id, "--scope", "user", "--json" });
            gpa.free(output);
            result.toggled += 1;
        }

        const source_version = stringField(plugin, "version") orelse return error.InvalidPluginList;
        const target_version = stringField(existing.?, "version") orelse return error.InvalidPluginList;
        if (!std.mem.eql(u8, source_version, target_version)) {
            display.print("Updating '{s}' in '{s}'\n", .{ id, target });
            const output = try runClaude(gpa, io, target_dir, &.{ "plugin", "update", id, "--scope", "user", "--json" });
            gpa.free(output);
            result.updated += 1;
        }
    }
    return result;
}

test "plugin inventory helpers find exact IDs and GitHub marketplaces" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\[{"id":"blunt@blunt","scope":"user","enabled":true,"version":"0.41.0"},
        \\ {"id":"emotive@emotive","scope":"user","enabled":false,"version":"0.9.0"}]
    , .{});
    defer parsed.deinit();
    const plugins = try items(parsed.value);
    try std.testing.expect(findUserPlugin(plugins, "blunt@blunt") != null);
    try std.testing.expect(findUserPlugin(plugins, "blunt") == null);
    try std.testing.expectEqual(false, boolField(findUserPlugin(plugins, "emotive@emotive").?, "enabled").?);
    var market = try std.json.parseFromSlice(std.json.Value, alloc, "{\"source\":\"github\",\"repo\":\"raineorshine/blunt\"}", .{});
    defer market.deinit();
    try std.testing.expectEqualStrings("raineorshine/blunt", marketplaceSource(market.value).?);
}

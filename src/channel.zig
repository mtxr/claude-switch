//! channel.zig — release channels: stable and the rolling edge pre-release

const std = @import("std");
const build_options = @import("build_options");
const version = @import("version.zig");

pub const EDGE_TAG = "edge";
pub const EDGE_COMMIT_ASSET = "EDGE_COMMIT";
pub const EDGE_COMMIT_LEN = 40;
const SHORT_SHA_LEN = 7;

pub const embedded_commit: []const u8 = build_options.edge_commit;

pub const StableDecision = enum { already_current, install, stay_on_edge };

pub fn isEdge(commit: []const u8) bool {
    return commit.len > 0;
}

pub fn shortSha(commit: []const u8) []const u8 {
    return commit[0..@min(commit.len, SHORT_SHA_LEN)];
}

pub fn versionString(gpa: std.mem.Allocator, base_version: []const u8, commit: []const u8) ![]u8 {
    if (!isEdge(commit)) return gpa.dupe(u8, base_version);
    return std.fmt.allocPrint(gpa, "{s}-edge+{s}", .{ base_version, shortSha(commit) });
}

/// The commit SHA in an EDGE_COMMIT asset: exactly 40 hex digits, optionally
/// followed by whitespace. Returns null for anything else.
pub fn parseEdgeCommit(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len != EDGE_COMMIT_LEN) return null;
    for (trimmed) |ch| {
        if (!std.ascii.isHex(ch)) return null;
    }
    return trimmed;
}

pub fn sameCommit(a: []const u8, b: []const u8) bool {
    return a.len > 0 and std.ascii.eqlIgnoreCase(a, b);
}

pub fn edgeBaseUrl(gpa: std.mem.Allocator, repo: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "https://github.com/{s}/releases/download/" ++ EDGE_TAG, .{repo});
}

pub fn edgeNotesUrl(gpa: std.mem.Allocator, repo: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "https://github.com/{s}/releases/tag/" ++ EDGE_TAG, .{repo});
}

/// `edge <old7> → <new7>` from an edge build, `v<version> → edge <new7>` from a stable one.
pub fn transitionLabel(gpa: std.mem.Allocator, current_version: []const u8, old_commit: []const u8, new_commit: []const u8) ![]u8 {
    if (!isEdge(old_commit)) {
        return std.fmt.allocPrint(gpa, "v{s} → edge {s}", .{ current_version, shortSha(new_commit) });
    }
    return std.fmt.allocPrint(gpa, "edge {s} → {s}", .{ shortSha(old_commit), shortSha(new_commit) });
}

/// What plain `csw update` does once the latest stable release is known. A
/// stable build installs whenever the versions differ. An edge build installs
/// only a stable release newer than the version it was built on.
pub fn stableDecision(edge_build: bool, latest: []const u8, current: []const u8) StableDecision {
    if (!edge_build) return if (std.mem.eql(u8, latest, current)) .already_current else .install;
    return if (version.isNewerVersion(latest, current)) .install else .stay_on_edge;
}

pub fn edgeNotice(gpa: std.mem.Allocator, current_version: []const u8, commit: []const u8, latest: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "On the edge channel (csw {s}-edge+{s}); latest stable is v{s}. Run `csw update --edge` for the newest edge build; `csw update` installs the next stable release once it is newer than v{s}.",
        .{ current_version, shortSha(commit), latest, current_version },
    );
}

test "isEdge and shortSha read the commit" {
    try std.testing.expect(!isEdge(""));
    try std.testing.expect(isEdge("abcdef0123456789abcdef0123456789abcdef01"));
    try std.testing.expectEqualStrings("abcdef0", shortSha("abcdef0123456789abcdef0123456789abcdef01"));
    try std.testing.expectEqualStrings("abc", shortSha("abc"));
    try std.testing.expectEqualStrings("", shortSha(""));
}

test "versionString marks only edge builds" {
    const alloc = std.testing.allocator;
    const stable = try versionString(alloc, "1.0.0", "");
    defer alloc.free(stable);
    try std.testing.expectEqualStrings("1.0.0", stable);

    const edge = try versionString(alloc, "1.0.0", "abcdef0123456789abcdef0123456789abcdef01");
    defer alloc.free(edge);
    try std.testing.expectEqualStrings("1.0.0-edge+abcdef0", edge);
}

test "parseEdgeCommit accepts exactly one full SHA" {
    const sha = "abcdef0123456789abcdef0123456789abcdef01";
    try std.testing.expectEqualStrings(sha, parseEdgeCommit(sha ++ "\n").?);
    try std.testing.expectEqualStrings(sha, parseEdgeCommit("  " ++ sha ++ "\r\n").?);
    try std.testing.expect(parseEdgeCommit("") == null);
    try std.testing.expect(parseEdgeCommit("abcdef0") == null);
    try std.testing.expect(parseEdgeCommit(sha ++ "0") == null);
    try std.testing.expect(parseEdgeCommit("zbcdef0123456789abcdef0123456789abcdef01") == null);
    try std.testing.expect(parseEdgeCommit(sha ++ "\nextra") == null);
}

test "sameCommit ignores case and never matches an empty commit" {
    try std.testing.expect(sameCommit("ABCDEF0123456789abcdef0123456789abcdef01", "abcdef0123456789abcdef0123456789ABCDEF01"));
    try std.testing.expect(!sameCommit("abcdef0123456789abcdef0123456789abcdef01", "abcdef0123456789abcdef0123456789abcdef02"));
    try std.testing.expect(!sameCommit("", ""));
    try std.testing.expect(!sameCommit("", "abc"));
}

test "edge URLs point at the moving edge release" {
    const alloc = std.testing.allocator;
    const base = try edgeBaseUrl(alloc, "mtxr/claude-switch");
    defer alloc.free(base);
    try std.testing.expectEqualStrings("https://github.com/mtxr/claude-switch/releases/download/edge", base);

    const notes = try edgeNotesUrl(alloc, "mtxr/claude-switch");
    defer alloc.free(notes);
    try std.testing.expectEqualStrings("https://github.com/mtxr/claude-switch/releases/tag/edge", notes);
}

test "transitionLabel names the channel switch" {
    const alloc = std.testing.allocator;
    const new_commit = "1234567abcdef0123456789abcdef0123456789a";
    const from_stable = try transitionLabel(alloc, "1.0.0", "", new_commit);
    defer alloc.free(from_stable);
    try std.testing.expectEqualStrings("v1.0.0 → edge 1234567", from_stable);

    const from_edge = try transitionLabel(alloc, "1.0.0", "abcdef0123456789abcdef0123456789abcdef01", new_commit);
    defer alloc.free(from_edge);
    try std.testing.expectEqualStrings("edge abcdef0 → 1234567", from_edge);
}

test "stableDecision keeps stable behaviour and protects edge builds" {
    try std.testing.expectEqual(StableDecision.already_current, stableDecision(false, "1.0.0", "1.0.0"));
    try std.testing.expectEqual(StableDecision.install, stableDecision(false, "1.1.0", "1.0.0"));
    try std.testing.expectEqual(StableDecision.install, stableDecision(false, "0.9.0", "1.0.0"));
    try std.testing.expectEqual(StableDecision.stay_on_edge, stableDecision(true, "1.0.0", "1.0.0"));
    try std.testing.expectEqual(StableDecision.stay_on_edge, stableDecision(true, "0.9.0", "1.0.0"));
    try std.testing.expectEqual(StableDecision.install, stableDecision(true, "1.1.0", "1.0.0"));
}

test "edgeNotice explains how to stay on or leave the edge channel" {
    const alloc = std.testing.allocator;
    const notice = try edgeNotice(alloc, "1.0.0", "abcdef0123456789abcdef0123456789abcdef01", "1.0.0");
    defer alloc.free(notice);
    try std.testing.expect(std.mem.indexOf(u8, notice, "csw 1.0.0-edge+abcdef0") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "csw update --edge") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "latest stable is v1.0.0") != null);
}

test "embedded_commit is empty for a regular build" {
    try std.testing.expect(embedded_commit.len == 0 or embedded_commit.len == EDGE_COMMIT_LEN);
}

//! session.zig — extração e formatação de dados de sessão a partir de JSON

const std = @import("std");

pub const Account = struct {
    email: ?[]const u8,
    organization: ?[]const u8,

    pub fn deinit(self: Account, gpa: std.mem.Allocator) void {
        if (self.email) |e| gpa.free(e);
        if (self.organization) |o| gpa.free(o);
    }
};

fn objectString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

/// Lê oauthAccount.{emailAddress,organizationName} de um ~/.claude.json. Caller chama deinit.
pub fn parseAccount(gpa: std.mem.Allocator, content: []const u8) !Account {
    const none = Account{ .email = null, .organization = null };
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch return none;
    defer parsed.deinit();
    if (parsed.value != .object) return none;
    const acct = parsed.value.object.get("oauthAccount") orelse return none;

    const email = if (objectString(acct, "emailAddress")) |e| try gpa.dupe(u8, e) else null;
    errdefer if (email) |e| gpa.free(e);
    const organization = if (objectString(acct, "organizationName")) |o| try gpa.dupe(u8, o) else null;
    return .{ .email = email, .organization = organization };
}

pub fn emailFromClaudeJson(gpa: std.mem.Allocator, content: []const u8) !?[]const u8 {
    const account = try parseAccount(gpa, content);
    defer if (account.organization) |o| gpa.free(o);
    return account.email;
}

pub fn oauthFromCredentials(root: std.json.Value) std.json.Value {
    if (root != .object) return .null;
    return root.object.get("claudeAiOauth") orelse .null;
}

pub fn oauthString(oauth: std.json.Value, key: []const u8) []const u8 {
    return objectString(oauth, key) orelse "?";
}

pub fn oauthInt(oauth: std.json.Value, key: []const u8) i64 {
    if (oauth != .object) return 0;
    const v = oauth.object.get(key) orelse return 0;
    if (v != .integer) return 0;
    return v.integer;
}

pub fn accountLabel(gpa: std.mem.Allocator, email: []const u8, organization: []const u8) ![]const u8 {
    if (organization.len == 0) return gpa.dupe(u8, email);
    return std.fmt.allocPrint(gpa, "{s} ({s})", .{ email, organization });
}

pub fn tokenPreview(gpa: std.mem.Allocator, token: []const u8) ![]const u8 {
    const preview_len = @min(token.len, 15);
    return std.fmt.allocPrint(gpa, "{s}...", .{token[0..preview_len]});
}

pub fn shortEmail(email: []const u8) []const u8 {
    return email[0..@min(email.len, 30)];
}

test "parseAccount lê email e organização" {
    const alloc = std.testing.allocator;
    const account = try parseAccount(alloc, "{\"oauthAccount\":{\"emailAddress\":\"a@b.co\",\"organizationName\":\"Acme\"}}");
    defer account.deinit(alloc);
    try std.testing.expectEqualStrings("a@b.co", account.email.?);
    try std.testing.expectEqualStrings("Acme", account.organization.?);
}

test "parseAccount retorna vazio para formatos inesperados" {
    const alloc = std.testing.allocator;
    const inputs = [_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"oauthAccount\":1}",
        "{\"oauthAccount\":{\"emailAddress\":5}}",
    };
    for (inputs) |input| {
        const account = try parseAccount(alloc, input);
        defer account.deinit(alloc);
        try std.testing.expectEqual(@as(?[]const u8, null), account.email);
        try std.testing.expectEqual(@as(?[]const u8, null), account.organization);
    }
}

test "parseAccount aceita só organização" {
    const alloc = std.testing.allocator;
    const account = try parseAccount(alloc, "{\"oauthAccount\":{\"organizationName\":\"Acme\"}}");
    defer account.deinit(alloc);
    try std.testing.expectEqual(@as(?[]const u8, null), account.email);
    try std.testing.expectEqualStrings("Acme", account.organization.?);
}

test "emailFromClaudeJson extrai só o email" {
    const alloc = std.testing.allocator;
    const email = try emailFromClaudeJson(alloc, "{\"oauthAccount\":{\"emailAddress\":\"me@work.com\",\"organizationName\":\"X\"}}");
    defer if (email) |e| alloc.free(e);
    try std.testing.expectEqualStrings("me@work.com", email.?);
    try std.testing.expectEqual(@as(?[]const u8, null), try emailFromClaudeJson(alloc, "{}"));
}

test "oauthFromCredentials e acessores" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"claudeAiOauth\":{\"subscriptionType\":\"max\",\"expiresAt\":1700000000000,\"rateLimitTier\":3}}",
        .{},
    );
    defer parsed.deinit();
    const oauth = oauthFromCredentials(parsed.value);
    try std.testing.expectEqualStrings("max", oauthString(oauth, "subscriptionType"));
    try std.testing.expectEqualStrings("?", oauthString(oauth, "rateLimitTier"));
    try std.testing.expectEqualStrings("?", oauthString(oauth, "missing"));
    try std.testing.expectEqual(@as(i64, 1700000000000), oauthInt(oauth, "expiresAt"));
    try std.testing.expectEqual(@as(i64, 0), oauthInt(oauth, "subscriptionType"));
    try std.testing.expectEqual(@as(i64, 0), oauthInt(oauth, "missing"));
}

test "acessores tratam oauth ausente" {
    try std.testing.expectEqualStrings("?", oauthString(.null, "x"));
    try std.testing.expectEqual(@as(i64, 0), oauthInt(.null, "x"));
    try std.testing.expect(oauthFromCredentials(.null) == .null);
}

test "oauthFromCredentials sem claudeAiOauth" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer parsed.deinit();
    try std.testing.expect(oauthFromCredentials(parsed.value) == .null);
}

test "accountLabel com e sem organização" {
    const alloc = std.testing.allocator;
    const plain = try accountLabel(alloc, "a@b.co", "");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("a@b.co", plain);
    const with_org = try accountLabel(alloc, "a@b.co", "Acme");
    defer alloc.free(with_org);
    try std.testing.expectEqualStrings("a@b.co (Acme)", with_org);
}

test "tokenPreview trunca em 15 caracteres" {
    const alloc = std.testing.allocator;
    const long = try tokenPreview(alloc, "sk-ant-oat01-ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    defer alloc.free(long);
    try std.testing.expectEqualStrings("sk-ant-oat01-AB...", long);
    const short = try tokenPreview(alloc, "short");
    defer alloc.free(short);
    try std.testing.expectEqualStrings("short...", short);
}

test "shortEmail limita a 30 caracteres" {
    try std.testing.expectEqualStrings("a@b.co", shortEmail("a@b.co"));
    try std.testing.expectEqual(@as(usize, 30), shortEmail("abcdefghijklmnopqrstuvwxyz0123456789@x.com").len);
}

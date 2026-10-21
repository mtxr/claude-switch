//! crypto.zig — PBKDF2 key derivation + AES-128-CBC decryption

const std = @import("std");

/// Derives an AES-128 key with PBKDF2-HMAC-SHA1.
/// The "saltysalt" salt and 1003 rounds are hardcoded in Chromium.
pub fn deriveKey(raw: []const u8) [16]u8 {
    var key: [16]u8 = undefined;
    std.crypto.pwhash.pbkdf2(
        &key,
        raw,
        "saltysalt",
        1003,
        std.crypto.auth.hmac.HmacSha1,
    ) catch unreachable;
    return key;
}

/// Decrypts a Chrome v10 cookie (AES-128-CBC, PKCS7, IV = 16 spaces).
/// Caller frees the returned slice.
pub fn decryptV10(allocator: std.mem.Allocator, encrypted: []const u8, key: [16]u8) ![]u8 {
    if (encrypted.len < 3) return error.TooShort;

    const data = encrypted[3..];
    if (data.len == 0 or data.len % 16 != 0) return error.BadBlockSize;

    const iv = [_]u8{' '} ** 16;

    var buf = try allocator.alloc(u8, data.len);
    defer allocator.free(buf);

    const ctx = std.crypto.core.aes.Aes128.initDec(key);
    var prev: [16]u8 = iv;
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        const cipher_block = data[i..][0..16].*;
        var plain_block: [16]u8 = undefined;
        ctx.decrypt(&plain_block, &cipher_block);
        for (&plain_block, prev) |*b, p| b.* ^= p;
        @memcpy(buf[i..][0..16], &plain_block);
        prev = cipher_block;
    }

    const pad = buf[buf.len - 1];
    if (pad == 0 or pad > 16 or @as(usize, pad) > buf.len) return error.InvalidPadding;

    return allocator.dupe(u8, buf[0 .. buf.len - pad]);
}

test "deriveKey is deterministic" {
    const k1 = deriveKey("password");
    const k2 = deriveKey("password");
    try std.testing.expectEqualSlices(u8, &k1, &k2);
}

test "deriveKey returns 16 bytes" {
    const k = deriveKey("anything");
    try std.testing.expectEqual(@as(usize, 16), k.len);
}

test "deriveKey differs for different inputs" {
    const k1 = deriveKey("password");
    const k2 = deriveKey("other");
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "decryptV10 round-trip" {
    const alloc = std.testing.allocator;
    const key = deriveKey("test_password");
    const plaintext = "sk-ant-sid01-hello-world";

    const encrypted = try encryptV10(alloc, plaintext, key);
    defer alloc.free(encrypted);

    const result = try decryptV10(alloc, encrypted, key);
    defer alloc.free(result);

    try std.testing.expectEqualStrings(plaintext, result);
}

test "decryptV10 finds sk-ant amid noise" {
    const alloc = std.testing.allocator;
    const key = deriveKey("safe_storage_key");
    const cookie = "\x00\x01some-junk\x00sk-ant-sid01-real-token-here";

    const encrypted = try encryptV10(alloc, cookie, key);
    defer alloc.free(encrypted);

    const result = try decryptV10(alloc, encrypted, key);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "sk-ant-sid01-real-token-here") != null);
}

test "decryptV10 rejects short input" {
    try std.testing.expectError(error.TooShort, decryptV10(std.testing.allocator, "v1", [_]u8{0} ** 16));
}

test "decryptV10 rejects wrong block size" {
    try std.testing.expectError(error.BadBlockSize, decryptV10(std.testing.allocator, "v10xxxxxxx", [_]u8{0} ** 16));
}

/// Encrypts plaintext in Chrome's v10 format (PKCS7 + AES-128-CBC).
/// Used by the crypto and desktop tests. Caller frees the returned slice.
pub fn encryptV10(allocator: std.mem.Allocator, plaintext: []const u8, key: [16]u8) ![]u8 {
    const iv = [_]u8{' '} ** 16;

    const pad_len = 16 - (plaintext.len % 16);
    const padded_len = plaintext.len + pad_len;
    var padded = try allocator.alloc(u8, padded_len);
    defer allocator.free(padded);
    @memcpy(padded[0..plaintext.len], plaintext);
    @memset(padded[plaintext.len..], @intCast(pad_len));

    var ciphertext = try allocator.alloc(u8, padded_len);
    defer allocator.free(ciphertext);
    const ctx = std.crypto.core.aes.Aes128.initEnc(key);
    var prev: [16]u8 = iv;
    var j: usize = 0;
    while (j < padded_len) : (j += 16) {
        var block: [16]u8 = padded[j..][0..16].*;
        for (&block, prev) |*b, p| b.* ^= p;
        ctx.encrypt(ciphertext[j..][0..16], &block);
        prev = ciphertext[j..][0..16].*;
    }

    var result = try allocator.alloc(u8, 3 + padded_len);
    @memcpy(result[0..3], "v10");
    @memcpy(result[3..], ciphertext);
    return result;
}

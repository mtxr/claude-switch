//! crypto.zig — PBKDF2 key derivation + AES-128-CBC decryption
//!
//! Rust usava 5 crates externos (aes, cbc, hmac, sha1, pbkdf2).
//! Em Zig, tudo isso está em std.crypto — zero dependências externas.
//!
//! Diferença chave do Rust:
//!   - Rust:  Result<T, E> com ? para propagar
//!   - Zig:   !T (anyerror union) com try para propagar
//!             A diferença é que erros Zig NÃO carregam mensagem —
//!             você printa a mensagem antes de retornar o erro.

const std = @import("std");

/// Deriva uma chave AES-128 usando PBKDF2-HMAC-SHA1.
/// Constantes "saltysalt" e 1003 rounds são hardcoded no Chromium.
/// Nota: retorna [16]u8 diretamente (valor, não ponteiro) — Zig copia arrays pequenos na stack.
pub fn deriveKey(raw: []const u8) [16]u8 {
    var key: [16]u8 = undefined;
    // pbkdf2 só falha se o output for maior que o limite do PRF — impossível aqui.
    std.crypto.pwhash.pbkdf2(
        &key,
        raw,
        "saltysalt",
        1003,
        std.crypto.auth.hmac.HmacSha1,
    ) catch unreachable;
    return key;
}

/// Decripta um cookie Chrome v10 (AES-128-CBC, PKCS7, IV = 16 espaços).
/// Caller é responsável por `allocator.free` no slice retornado.
///
/// Em Zig, memória alocada dentro de uma função pertence a quem chamou —
/// não há GC nem Box<T>. O padrão é: se você aloca, você documenta quem libera.
pub fn decryptV10(allocator: std.mem.Allocator, encrypted: []const u8, key: [16]u8) ![]u8 {
    if (encrypted.len < 3) return error.TooShort;

    // Pula o prefixo "v10" que o Chrome coloca
    const data = encrypted[3..];
    if (data.len == 0 or data.len % 16 != 0) return error.BadBlockSize;

    // IV do Chrome: 16 bytes de espaço (hardcoded no Chromium)
    const iv = [_]u8{' '} ** 16; // [_] infere o tamanho pelo inicializador

    // Buffer temporário para a decriptação — liberado no final desta função
    var buf = try allocator.alloc(u8, data.len);
    defer allocator.free(buf); // defer executa ao sair do escopo, independente de erro

    // AES-128-CBC manual — std.crypto só fornece o block cipher (ECB).
    // CBC decrypt: para cada bloco, decripta com AES e faz XOR com o bloco de ciphertext anterior.
    const ctx = std.crypto.core.aes.Aes128.initDec(key);
    var prev: [16]u8 = iv;
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        const cipher_block = data[i..][0..16].*; // .* converte *[16]u8 para [16]u8 (cópia na stack)
        var plain_block: [16]u8 = undefined;
        ctx.decrypt(&plain_block, &cipher_block);
        // XOR com o bloco anterior (ou IV para o primeiro bloco)
        for (&plain_block, prev) |*b, p| b.* ^= p;
        @memcpy(buf[i..][0..16], &plain_block);
        prev = cipher_block; // desliza a janela
    }

    // Remove padding PKCS7
    const pad = buf[buf.len - 1];
    if (pad == 0 or pad > 16 or @as(usize, pad) > buf.len) return error.InvalidPadding;

    // Retorna uma nova alocação com exatamente os bytes sem padding.
    // `buf` é liberado pelo defer acima, então precisamos copiar.
    // allocator.dupe é equivalente a Vec::from(&slice) — aloca + copia.
    return allocator.dupe(u8, buf[0 .. buf.len - pad]);
}

// ── Tests ────────────────────────────────────────────────────────────────────
//
// Em Zig, tests ficam inline no mesmo arquivo — não há pasta tests/ separada.
// `zig build test` coleta todos os blocos `test` automaticamente.
// std.testing.allocator detecta vazamentos de memória em testes.

test "deriveKey é determinístico" {
    const k1 = deriveKey("password");
    const k2 = deriveKey("password");
    try std.testing.expectEqualSlices(u8, &k1, &k2);
}

test "deriveKey retorna 16 bytes" {
    const k = deriveKey("anything");
    try std.testing.expectEqual(@as(usize, 16), k.len);
}

test "deriveKey difere para inputs diferentes" {
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

test "decryptV10 encontra sk-ant no meio de ruído" {
    const alloc = std.testing.allocator;
    const key = deriveKey("safe_storage_key");
    const cookie = "\x00\x01some-junk\x00sk-ant-sid01-real-token-here";

    const encrypted = try encryptV10(alloc, cookie, key);
    defer alloc.free(encrypted);

    const result = try decryptV10(alloc, encrypted, key);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "sk-ant-sid01-real-token-here") != null);
}

test "decryptV10 rejeita input curto" {
    try std.testing.expectError(error.TooShort, decryptV10(std.testing.allocator, "v1", [_]u8{0} ** 16));
}

test "decryptV10 rejeita bloco de tamanho errado" {
    try std.testing.expectError(error.BadBlockSize, decryptV10(std.testing.allocator, "v10xxxxxxx", [_]u8{0} ** 16));
}

/// Encripta plaintext no formato v10 do Chrome (PKCS7 + AES-128-CBC).
/// Usado nos testes de crypto e desktop. Caller libera o slice retornado.
pub fn encryptV10(allocator: std.mem.Allocator, plaintext: []const u8, key: [16]u8) ![]u8 {
    const iv = [_]u8{' '} ** 16;

    // PKCS7 padding
    const pad_len = 16 - (plaintext.len % 16);
    const padded_len = plaintext.len + pad_len;
    var padded = try allocator.alloc(u8, padded_len);
    defer allocator.free(padded);
    @memcpy(padded[0..plaintext.len], plaintext);
    @memset(padded[plaintext.len..], @intCast(pad_len)); // @intCast faz cast seguro (panic em overflow)

    // AES-128-CBC encrypt
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

    // Prepend "v10"
    var result = try allocator.alloc(u8, 3 + padded_len);
    @memcpy(result[0..3], "v10");
    @memcpy(result[3..], ciphertext);
    return result;
}

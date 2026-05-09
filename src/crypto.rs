use anyhow::{anyhow, Result};
use pbkdf2::pbkdf2_hmac;
use sha1::Sha1;

pub fn derive_key(raw: &str) -> [u8; 16] {
    let mut key = [0u8; 16];
    pbkdf2_hmac::<Sha1>(raw.as_bytes(), b"saltysalt", 1003, &mut key);
    key
}

pub fn decrypt_v10(encrypted: &[u8], key: &[u8; 16]) -> Result<String> {
    use aes::Aes128;
    use cbc::cipher::{block_padding::NoPadding, BlockDecryptMut, KeyIvInit};

    type Aes128CbcDec = cbc::Decryptor<Aes128>;

    if encrypted.len() < 3 {
        return Err(anyhow!("encrypted value too short"));
    }
    // Skip "v10" prefix; IV is 16 space bytes (Chrome cookie format)
    let data = &encrypted[3..];
    if !data.len().is_multiple_of(16) {
        return Err(anyhow!("ciphertext length not multiple of block size"));
    }

    let iv = [b' '; 16];
    let mut buf = data.to_vec();

    let decryptor = Aes128CbcDec::new(key.into(), &iv.into());
    let decrypted = decryptor
        .decrypt_padded_mut::<NoPadding>(&mut buf)
        .map_err(|_| anyhow!("AES decryption failed"))?;

    // Manual PKCS7 unpadding
    let pad = *decrypted.last().ok_or_else(|| anyhow!("empty decrypted data"))? as usize;
    if pad == 0 || pad > 16 || pad > decrypted.len() {
        return Err(anyhow!("invalid PKCS7 padding byte: {}", pad));
    }
    let unpadded = &decrypted[..decrypted.len() - pad];

    // latin-1 decode: each byte maps to the same unicode codepoint
    Ok(unpadded.iter().map(|&b| b as char).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::Aes128;
    use cbc::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};

    type Aes128CbcEnc = cbc::Encryptor<Aes128>;

    fn make_v10(plaintext: &str, key: &[u8; 16]) -> Vec<u8> {
        let iv = [b' '; 16];
        let mut buf = vec![0u8; plaintext.len() + 16];
        let ct = Aes128CbcEnc::new(key.into(), &iv.into())
            .encrypt_padded_b2b_mut::<Pkcs7>(plaintext.as_bytes(), &mut buf)
            .unwrap();
        let mut out = b"v10".to_vec();
        out.extend_from_slice(ct);
        out
    }

    #[test]
    fn derive_key_is_deterministic() {
        assert_eq!(derive_key("password"), derive_key("password"));
        assert_ne!(derive_key("password"), derive_key("other"));
    }

    #[test]
    fn derive_key_length() {
        assert_eq!(derive_key("anything").len(), 16);
    }

    #[test]
    fn decrypt_v10_round_trip() {
        let key = derive_key("test_password");
        let plaintext = "sk-ant-sid01-hello-world";
        let encrypted = make_v10(plaintext, &key);
        assert_eq!(decrypt_v10(&encrypted, &key).unwrap(), plaintext);
    }

    #[test]
    fn decrypt_v10_finds_sk_ant_token() {
        // Simulates real cookie content: garbage prefix + actual token
        let key = derive_key("safe_storage_key");
        let cookie_value = "\x00\x01some-junk\x00sk-ant-sid01-real-token-here";
        let encrypted = make_v10(cookie_value, &key);
        let decrypted = decrypt_v10(&encrypted, &key).unwrap();
        // The caller (desktop.rs) finds "sk-ant" inside the decrypted string
        assert!(decrypted.contains("sk-ant-sid01-real-token-here"));
    }

    #[test]
    fn decrypt_v10_rejects_short_input() {
        let key = derive_key("x");
        assert!(decrypt_v10(b"v1", &key).is_err());
    }

    #[test]
    fn decrypt_v10_rejects_bad_block_size() {
        let key = derive_key("x");
        // "v10" prefix + 7 bytes → not a multiple of 16
        assert!(decrypt_v10(b"v10xxxxxxx", &key).is_err());
    }

    #[test]
    fn decrypt_v10_wrong_key_returns_garbage_not_panic() {
        let key = derive_key("correct");
        let wrong_key = derive_key("wrong");
        let encrypted = make_v10("sk-ant-token", &key);
        // Should not panic — may succeed with garbage or fail with padding error
        let _ = decrypt_v10(&encrypted, &wrong_key);
    }
}

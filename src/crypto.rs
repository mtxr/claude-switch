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
    if data.len() % 16 != 0 {
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

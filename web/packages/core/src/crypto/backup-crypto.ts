/**
 * Backup encryption, algorithm only: AES-256-GCM with PBKDF2 and SHA-256.
 *
 * crypto.subtle and crypto.getRandomValues are injected through CryptoPort (the renderer injects
 * Web Crypto, the main process injects Node webcrypto), so this module is not coupled to a
 * specific crypto implementation and one format works everywhere.
 *
 * Format contract, which has to match everywhere: output = [salt(16)] [iv(12)] [ciphertext(...)].
 * The PBKDF2 iteration count (600_000) is guaranteed by the CryptoPort.deriveAesKey
 * implementation. Base64 encoding stays in the renderer, since btoa/atob depend on the host.
 */

import type { CryptoPort } from '../ports';

const SALT_BYTES = 16;
const IV_BYTES = 12;

function toBytes(data: BufferSource): Uint8Array {
  if (data instanceof Uint8Array) return data;
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  return new Uint8Array(data);
}

/* ── AES-256-GCM encryption ────────────────────────────────── */

export async function encrypt(
  data: BufferSource,
  password: string,
  crypto: CryptoPort,
): Promise<Uint8Array> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES));
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const key = await crypto.deriveAesKey(password, salt);

  const ciphertext = await crypto.encryptAesGcm(key, iv, toBytes(data));

  // [salt(16)] [iv(12)] [ciphertext(...)]
  const result = new Uint8Array(salt.length + iv.length + ciphertext.byteLength);
  result.set(salt, 0);
  result.set(iv, salt.length);
  result.set(new Uint8Array(ciphertext), salt.length + iv.length);
  return result;
}

/* ── AES-256-GCM decryption ────────────────────────────────── */

export async function decrypt(
  data: Uint8Array,
  password: string,
  crypto: CryptoPort,
): Promise<Uint8Array> {
  const salt = data.slice(0, SALT_BYTES);
  const iv = data.slice(SALT_BYTES, SALT_BYTES + IV_BYTES);
  const ciphertext = data.slice(SALT_BYTES + IV_BYTES);

  const key = await crypto.deriveAesKey(password, salt);
  const plaintext = await crypto.decryptAesGcm(key, iv, ciphertext);

  return new Uint8Array(plaintext);
}

/* ── SHA-256 ──────────────────────────────────────────── */

export async function sha256hex(data: Uint8Array, crypto: CryptoPort): Promise<string> {
  const hash = await crypto.sha256(data);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

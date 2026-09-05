/**
 * Backup encryption. The AES-256-GCM + PBKDF2 + SHA-256 algorithms live in
 * @oriveo/core/crypto/backup-crypto so every client imports the same implementation and the
 * format is interchangeable across platforms.
 *
 * This file is the web adapter: it injects a CryptoPort backed by Web Crypto (crypto.subtle).
 * base64 encoding stays here because btoa/atob depend on the host environment.
 */
import {
  decrypt as coreDecrypt,
  encrypt as coreEncrypt,
  sha256hex as coreSha256hex,
} from '@oriveo/core/crypto/backup-crypto';
import type { CryptoPort } from '@oriveo/core';

const PBKDF2_ITERATIONS = 600_000;

// TS 5.x tightened typed-array generics: the core CryptoPort uses Uint8Array (ArrayBufferLike)
// while crypto.subtle wants a BufferSource backed by ArrayBuffer. They agree at runtime, so the
// cast happens at the boundary.
const buf = (b: Uint8Array): BufferSource => b as unknown as BufferSource;

const webCryptoPort: CryptoPort = {
  getRandomValues: (arr) => crypto.getRandomValues(arr),
  deriveAesKey: async (password, salt) => {
    const keyMaterial = await crypto.subtle.importKey(
      'raw',
      buf(new TextEncoder().encode(password)),
      'PBKDF2',
      false,
      ['deriveKey'],
    );
    return crypto.subtle.deriveKey(
      { name: 'PBKDF2', salt: buf(salt), iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
      keyMaterial,
      { name: 'AES-GCM', length: 256 },
      false,
      ['encrypt', 'decrypt'],
    );
  },
  encryptAesGcm: (key, iv, data) =>
    crypto.subtle.encrypt({ name: 'AES-GCM', iv: buf(iv) }, key as CryptoKey, buf(data)),
  decryptAesGcm: (key, iv, data) =>
    crypto.subtle.decrypt({ name: 'AES-GCM', iv: buf(iv) }, key as CryptoKey, buf(data)),
  sha256: (data) => crypto.subtle.digest('SHA-256', buf(data)),
};

export function encrypt(data: BufferSource, password: string): Promise<Uint8Array> {
  return coreEncrypt(data, password, webCryptoPort);
}

export function decrypt(data: Uint8Array, password: string): Promise<Uint8Array> {
  return coreDecrypt(data, password, webCryptoPort);
}

export function sha256hex(data: Uint8Array): Promise<string> {
  return coreSha256hex(data, webCryptoPort);
}

/* -- Base64 encoding; btoa/atob depend on the host, so they stay in the renderer. ---- */

export function uint8ToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

export function base64ToUint8(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

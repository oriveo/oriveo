import type { LocalEngineKind } from './local-engine';

export interface LocalPairingPayloadV1 {
  version: 1;
  engine: LocalEngineKind;
  urls: string[];
  authMode: 'none' | 'token';
  fingerprint?: string;
  name?: string;
}

function isForbiddenCredentialName(raw: string): boolean {
  const key = raw.toLowerCase().replace(/[^a-z0-9]/g, '');
  return key !== 'auth' && (
    key === 'key' || key.endsWith('key') || key.includes('token') || key.includes('secret')
    || key.includes('password') || key.includes('credential') || key.includes('authorization')
  );
}

function requireCredentialFreeEndpoint(raw: string): void {
  const endpoint = new URL(raw);
  if (endpoint.username || endpoint.password) throw new Error('pairing_payload_contains_secret');
  for (const key of endpoint.searchParams.keys()) {
    if (isForbiddenCredentialName(key)) throw new Error('pairing_payload_contains_secret');
  }
}

export function encodeLocalPairingV1(payload: LocalPairingPayloadV1): string {
  payload.urls.forEach(requireCredentialFreeEndpoint);
  const json = JSON.stringify({ v: 1, name: payload.name, urls: payload.urls, engine: payload.engine, auth: payload.authMode, fingerprint: payload.fingerprint });
  const bytes = new TextEncoder().encode(json);
  let binary = '';
  bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function decodeLocalPairingV1(raw: string): LocalPairingPayloadV1 {
  if (raw.startsWith('oriveo://')) return decodeLegacyPairingURI(raw);
  const encoded = raw.trim().replace(/-/g, '+').replace(/_/g, '/');
  const padded = encoded + '='.repeat((4 - encoded.length % 4) % 4);
  const json = raw.trim().startsWith('{') ? raw.trim() : new TextDecoder().decode(Uint8Array.from(atob(padded), (char) => char.charCodeAt(0)));
  const parsed = JSON.parse(json) as Record<string, unknown>;
  if (containsForbiddenKey(parsed)) throw new Error('pairing_payload_contains_secret');
  const engine = parsed.engine;
  const authMode = parsed.auth;
  const urls = parsed.urls;
  if (parsed.v !== 1 || !['llamacpp', 'ollama', 'lmstudio', 'vllm', 'openwebui'].includes(String(engine))
    || !['none', 'token'].includes(String(authMode)) || !Array.isArray(urls) || urls.length === 0
    || urls.some((item) => typeof item !== 'string')) throw new Error('invalid_pairing_payload');
  urls.forEach((item) => requireCredentialFreeEndpoint(String(item)));
  return { version: 1, engine: engine as LocalEngineKind, urls: urls as string[], authMode: authMode as 'none' | 'token', name: typeof parsed.name === 'string' ? parsed.name : undefined, fingerprint: typeof parsed.fingerprint === 'string' ? parsed.fingerprint : undefined };
}

function decodeLegacyPairingURI(raw: string): LocalPairingPayloadV1 {
  const url = new URL(raw);
  if (url.protocol !== 'oriveo:' || url.hostname !== 'local-provider' || url.searchParams.get('v') !== '1') throw new Error('unsupported_pairing_payload');
  for (const key of url.searchParams.keys()) if (isForbiddenCredentialName(key)) throw new Error('pairing_payload_contains_secret');
  const engine = url.searchParams.get('engine');
  const mode = url.searchParams.get('mode');
  const endpoint = url.searchParams.get('endpoint');
  if (!['llamacpp', 'ollama', 'lmstudio', 'vllm'].includes(engine ?? '') || !['local_http', 'private_vpn'].includes(mode ?? '') || !endpoint || url.searchParams.get('auth') !== 'none') throw new Error('invalid_pairing_payload');
  requireCredentialFreeEndpoint(endpoint);
  return { version: 1, engine: engine as LocalEngineKind, urls: [endpoint], authMode: 'none', name: url.searchParams.get('name') || undefined };
}

function containsForbiddenKey(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(containsForbiddenKey);
  if (!value || typeof value !== 'object') return false;
  return Object.entries(value).some(([key, child]) => isForbiddenCredentialName(key) || containsForbiddenKey(child));
}

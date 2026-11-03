/**
 * Style preset sample cache: stores sample image bytes keyed by sample.sha256.
 * Hit → stored bytes with no network. Miss → resolve the URL against the
 * backend base, download through fetchStudioImage (maxBytes = fixture
 * policy.maxBytes), verify the lowercase-hex SHA-256 against the key, and only
 * then store. A sha256 that is not 64 lowercase hex chars yields null without
 * touching storage or network. One download per key in flight; an unreadable
 * entry (not a Uint8Array, or zero bytes) is deleted and refetched. prune(keep) drops every entry whose key is not in keep.
 * Default storage is blob-cache (oriveo-meta DB) under the `studio-sample:`
 * prefix; no new IndexedDB database or version bump.
 * Fixture: studio_presets.v1.json clientCases.sampleCache.
 */
import { resolveMetadataBackendURL } from '../metadata/metadata-client';
import { deleteBlob, pruneBlobs, readBlob, writeBlob } from '../../infra/storage/blob-cache';
import { fetchStudioImage } from './image-fetch';
import type { StudioPresetSample } from './presets';

export const PRESET_SAMPLE_MAX_BYTES = 2097152;

const BLOB_PREFIX = 'studio-sample:';

export type PresetSampleVerifyResult = 'ok' | 'sha_mismatch';

/** Key-value storage for sample bytes; keys are bare sha256 hex strings. */
export interface PresetSampleStorage {
  /** Returns the stored value (anything that is not a Uint8Array counts as unreadable) or null. */
  read(key: string): Promise<unknown>;
  write(key: string, bytes: Uint8Array): Promise<unknown>;
  remove(key: string): Promise<unknown>;
  /** Deletes every entry whose key is not in keep. */
  prune(keep: readonly string[]): Promise<unknown>;
}

export interface PresetSampleCacheOptions {
  /** Downloader; defaults to fetchStudioImage with PRESET_SAMPLE_MAX_BYTES. */
  fetchBytes?: (url: string) => Promise<Uint8Array | null>;
  /** Defaults to blob-cache under the `studio-sample:` prefix. */
  storage?: PresetSampleStorage;
  /** Defaults to resolveMetadataBackendURL() at call time. */
  backendURL?: string;
}

export interface PresetSampleCache {
  data(sample: StudioPresetSample): Promise<Uint8Array | null>;
  prune(keep: readonly string[]): Promise<void>;
}

const SHA256_HEX = /^[0-9a-f]{64}$/;

/**
 * True when the character right after the scheme's `//` exists and is not one of
 * `/ ? # \` (i.e. there is a host). Deliberately not new URL: the WHATWG parser
 * normalises `https:///a` and `https://\\evil` into URLs with a host.
 */
function hasHostAfter(url: string, scheme: string): boolean {
  const first = url.charAt(scheme.length);
  return first !== '' && !'/?#\\'.includes(first);
}

/**
 * Resolves a sample URL: a root-relative path joins the backend base (trailing
 * slashes trimmed, base path kept, base must be http(s) with a host); an
 * absolute lowercase `https://` URL with a host is kept verbatim; anything else (http, protocol-relative, bare relative,
 * data:, leading whitespace, empty base) yields null.
 */
export function resolvePresetSampleUrl(baseUrl: string, url: string): string | null {
  if (url.startsWith('https://')) return hasHostAfter(url, 'https://') ? url : null;
  if (!url.startsWith('/') || url.startsWith('//')) return null;
  const base = baseUrl.replace(/\/+$/, '');
  const scheme = base.startsWith('https://') ? 'https://' : base.startsWith('http://') ? 'http://' : null;
  if (!scheme || !hasHostAfter(base, scheme)) return null;
  return `${base}${url}`;
}

function toHex(digest: ArrayBuffer): string {
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Compares the lowercase-hex SHA-256 of bytes with sha256 (exact match). */
export async function verifyPresetSample(bytes: Uint8Array, sha256: string): Promise<PresetSampleVerifyResult> {
  const digest = await crypto.subtle.digest('SHA-256', bytes as unknown as BufferSource);
  return toHex(digest) === sha256 ? 'ok' : 'sha_mismatch';
}

/** A readable entry is a non-empty Uint8Array; zero bytes count as unreadable. */
function isBytes(value: unknown): value is Uint8Array {
  return (
    ArrayBuffer.isView(value) &&
    Object.prototype.toString.call(value) === '[object Uint8Array]' &&
    (value as Uint8Array).byteLength > 0
  );
}

const blobStorage: PresetSampleStorage = {
  read: async (key) => (await readBlob<unknown>(BLOB_PREFIX + key))?.value ?? null,
  write: (key, bytes) => writeBlob(BLOB_PREFIX + key, bytes),
  remove: (key) => deleteBlob(BLOB_PREFIX + key),
  prune: (keep) =>
    pruneBlobs(
      BLOB_PREFIX,
      keep.map((key) => BLOB_PREFIX + key),
    ),
};

async function defaultFetchBytes(url: string): Promise<Uint8Array | null> {
  const outcome = await fetchStudioImage(url, { maxBytes: PRESET_SAMPLE_MAX_BYTES });
  return outcome.ok ? outcome.bytes : null;
}

export function createPresetSampleCache(options: PresetSampleCacheOptions = {}): PresetSampleCache {
  const storage = options.storage ?? blobStorage;
  const fetchBytes = options.fetchBytes ?? defaultFetchBytes;
  const inFlight = new Map<string, Promise<Uint8Array | null>>();

  async function load(sample: StudioPresetSample): Promise<Uint8Array | null> {
    const key = sample.sha256;
    let stored: unknown = null;
    try {
      stored = await storage.read(key);
    } catch {
      stored = null;
    }
    if (isBytes(stored)) return stored;
    if (stored !== null && stored !== undefined) await storage.remove(key);

    const url = resolvePresetSampleUrl(options.backendURL ?? resolveMetadataBackendURL(), sample.url);
    if (!url) return null;
    let bytes: Uint8Array | null;
    try {
      bytes = await fetchBytes(url);
    } catch {
      bytes = null;
    }
    if (!bytes) return null;
    if ((await verifyPresetSample(bytes, key)) !== 'ok') return null;
    await storage.write(key, bytes);
    return bytes;
  }

  return {
    data(sample) {
      const key = sample.sha256;
      // Malformed key: no storage read, no request.
      if (!SHA256_HEX.test(key)) return Promise.resolve(null);
      const pending = inFlight.get(key);
      if (pending) return pending;
      const task = load(sample).finally(() => inFlight.delete(key));
      inFlight.set(key, task);
      return task;
    },
    async prune(keep) {
      await storage.prune(keep);
    },
  };
}

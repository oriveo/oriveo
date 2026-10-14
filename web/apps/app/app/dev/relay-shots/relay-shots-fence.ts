/**
 * Isolation fence for shots mode (only dynamically imported from the StoreProvider dev branch; absent from production bundles).
 *
 * On shots routes StoreProvider skips bootstrap / persistence subscriptions / sign-in observation; the paths that write storage directly from page actions
 * (putProvider in provider-ops, group memory in ModelBrowser, etc.) are contained here at the browser API layer:
 * - IndexedDB is replaced by a fresh in-memory fake-indexeddb instance (cannot read or write the real database);
 * - localStorage / sessionStorage are replaced by one in-memory table per instance;
 * - fetch: a fake relay answers locally, read-only metadata passes through, other /api and cross-origin requests get a local 503; sendBeacon is swallowed.
 */
import {
  IDBCursor,
  IDBCursorWithValue,
  IDBDatabase,
  IDBFactory,
  IDBIndex,
  IDBKeyRange,
  IDBObjectStore,
  IDBOpenDBRequest,
  IDBRequest,
  IDBTransaction,
  IDBVersionChangeEvent,
} from 'fake-indexeddb';
import { resolveMetadataBackendURL } from '../../../lib/core/metadata/metadata-client';
import { demoUpstream, demoUpstreamCatalog } from './relay-shots-data';

const RELAY_FORWARD_PATH = '/api/relay/forward';

let uninstall: (() => void) | null = null;

export function relayShotsFenceInstalled(): boolean {
  return uninstall !== null;
}

/** Install the fence; repeated calls have no side effect. Returns the uninstall function (for tests). */
export function installRelayShotsFence(): () => void {
  if (uninstall) return uninstall;
  const restorers = [fenceIndexedDB(), fenceWebStorage(), fenceNetwork()];
  uninstall = () => {
    for (const restore of restorers.reverse()) restore();
    uninstall = null;
  };
  console.info('[relay-shots] isolation fence installed: in-memory IndexedDB / Web Storage, local network stubs');
  return uninstall;
}

function defineGlobal(name: string, value: unknown): () => void {
  const target = globalThis as Record<string, unknown>;
  const previous = Object.getOwnPropertyDescriptor(target, name);
  Object.defineProperty(target, name, { value, configurable: true, writable: true, enumerable: false });
  return () => {
    if (previous) Object.defineProperty(target, name, previous);
    else delete target[name];
  };
}

function fenceIndexedDB(): () => void {
  const globals: Record<string, unknown> = {
    indexedDB: new IDBFactory(),
    IDBCursor,
    IDBCursorWithValue,
    IDBDatabase,
    IDBFactory,
    IDBIndex,
    IDBKeyRange,
    IDBObjectStore,
    IDBOpenDBRequest,
    IDBRequest,
    IDBTransaction,
    IDBVersionChangeEvent,
  };
  const restorers = Object.entries(globals).map(([name, value]) => defineGlobal(name, value));
  return () => restorers.forEach((restore) => restore());
}

function fenceWebStorage(): () => void {
  if (typeof Storage === 'undefined') return () => {};
  const proto = Storage.prototype;
  const tables = new WeakMap<Storage, Map<string, string>>();
  const table = (storage: Storage) => {
    let entries = tables.get(storage);
    if (!entries) {
      entries = new Map();
      tables.set(storage, entries);
    }
    return entries;
  };
  const originals = {
    getItem: proto.getItem,
    setItem: proto.setItem,
    removeItem: proto.removeItem,
    clear: proto.clear,
    key: proto.key,
    length: Object.getOwnPropertyDescriptor(proto, 'length'),
  };
  proto.getItem = function getItem(this: Storage, key: string) {
    return table(this).get(String(key)) ?? null;
  };
  proto.setItem = function setItem(this: Storage, key: string, value: string) {
    table(this).set(String(key), String(value));
  };
  proto.removeItem = function removeItem(this: Storage, key: string) {
    table(this).delete(String(key));
  };
  proto.clear = function clear(this: Storage) {
    table(this).clear();
  };
  proto.key = function key(this: Storage, index: number) {
    return [...table(this).keys()][index] ?? null;
  };
  Object.defineProperty(proto, 'length', {
    configurable: true,
    get(this: Storage) {
      return table(this).size;
    },
  });
  return () => {
    proto.getItem = originals.getItem;
    proto.setItem = originals.setItem;
    proto.removeItem = originals.removeItem;
    proto.clear = originals.clear;
    proto.key = originals.key;
    if (originals.length) Object.defineProperty(proto, 'length', originals.length);
  };
}

function fenceNetwork(): () => void {
  const realFetch = globalThis.fetch.bind(globalThis);
  const fencedFetch: typeof fetch = async (input, init) => {
    const request = describeRequest(input, init);
    const local = relayShotsLocalResponse(request);
    if (local) return local;
    return realFetch(input, init);
  };
  const restorers = [defineGlobal('fetch', fencedFetch)];
  if (typeof navigator !== 'undefined' && typeof navigator.sendBeacon === 'function') {
    const realBeacon = navigator.sendBeacon;
    navigator.sendBeacon = () => true;
    restorers.push(() => {
      navigator.sendBeacon = realBeacon;
    });
  }
  return () => restorers.forEach((restore) => restore());
}

export interface RelayShotsRequest {
  url: URL;
  method: string;
  headers: Headers;
}

function describeRequest(input: RequestInfo | URL, init?: RequestInit): RelayShotsRequest {
  const base = typeof window === 'undefined' ? 'http://localhost/' : window.location.href;
  const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  const fromRequest = typeof input === 'object' && !(input instanceof URL) ? input : null;
  return {
    url: new URL(raw, base),
    method: (init?.method ?? fromRequest?.method ?? 'GET').toUpperCase(),
    headers: new Headers(init?.headers ?? fromRequest?.headers),
  };
}

/**
 * The fence's answer table: null = let the real network through (only same-origin page assets and read-only metadata fetches); everything else is answered locally.
 */
export function relayShotsLocalResponse(request: RelayShotsRequest): Response | null {
  const { url, method, headers } = request;
  const pageOrigin = typeof window === 'undefined' ? 'http://localhost' : window.location.origin;
  if (url.origin === pageOrigin && url.pathname === RELAY_FORWARD_PATH) {
    const upstream = headers.get('X-Relay-Upstream-URL');
    if (!upstream) return blocked(url);
    let apiKey: string | undefined;
    try {
      const config = JSON.parse(headers.get('X-Relay-Proxy-Config') ?? '{}') as { apiKey?: unknown };
      apiKey = typeof config.apiKey === 'string' ? config.apiKey : undefined;
    } catch {
      apiKey = undefined;
    }
    return fakeUpstream(new URL(upstream), (headers.get('X-Relay-Upstream-Method') ?? method).toUpperCase(), apiKey) ?? blocked(url);
  }
  if (url.origin === pageOrigin && !url.pathname.startsWith('/api/')) return null;
  if (method === 'GET' && url.pathname.startsWith('/api/metadata') && url.origin === metadataOrigin()) return null;
  const direct = fakeUpstream(url, method, bearerOf(headers));
  return direct ?? blocked(url);
}

function metadataOrigin(): string | null {
  try {
    return new URL(resolveMetadataBackendURL()).origin;
  } catch {
    return null;
  }
}

function bearerOf(headers: Headers): string | undefined {
  const authorization = headers.get('Authorization');
  if (authorization?.toLowerCase().startsWith('bearer ')) return authorization.slice(7).trim();
  return headers.get('x-api-key') ?? undefined;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

function blocked(url: URL): Response {
  console.info(`[relay-shots] blocked network request: ${url.origin}${url.pathname}`);
  return json(503, { error: { message: 'Network is disabled in relay shots mode.' } });
}

function modelList(ids: readonly string[]): Response {
  return json(200, { object: 'list', data: ids.map((id) => ({ id, object: 'model', owned_by: 'relay-demo' })) });
}

function generationSuccess(pathname: string): Response {
  if (pathname.endsWith('/responses')) {
    return json(200, {
      id: 'resp_demo', object: 'response', status: 'completed',
      output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'OK' }] }],
    });
  }
  if (pathname.endsWith('/messages')) {
    return json(200, { id: 'msg_demo', type: 'message', role: 'assistant', content: [{ type: 'text', text: 'OK' }] });
  }
  return json(200, {
    id: 'chatcmpl_demo', object: 'chat.completion',
    choices: [{ index: 0, message: { role: 'assistant', content: 'OK' }, finish_reason: 'stop' }],
  });
}

/**
 * Fake upstream: Demo Relay and Studio Ollama; addresses, key answer codes, invalid-key bodies and catalogs come from the currently active shared manifest;
 * returns null for other addresses or when no manifest is active (the caller answers a local 503).
 */
function fakeUpstream(url: URL, method: string, apiKey: string | undefined): Response | null {
  const upstream = demoUpstream();
  if (!upstream) return null;
  if (url.origin === new URL(upstream.relayEndpoint).origin) {
    const unauthorized = () => new Response(upstream.unauthorizedError.body, {
      status: upstream.unauthorizedError.httpStatus,
      headers: { 'Content-Type': 'application/json' },
    });
    // Manual-setup failure page (same as iOS): verification on that page always fails, any key gets the invalid-key answer.
    if (upstream.relayUnauthorizedPage) return unauthorized();
    const key = upstream.keyBySecret(apiKey);
    const status = key ? key.httpStatus : 401;
    if (status === 401) return unauthorized();
    if (status === 429) return json(429, { error: { message: 'Rate limit reached for this key.', type: 'rate_limit_error' } });
    if (method === 'GET' && url.pathname === '/v1/models') return modelList(demoUpstreamCatalog(key!.ref));
    if (method === 'POST' && /^\/v1\/(chat\/completions|responses|messages)$/.test(url.pathname)) return generationSuccess(url.pathname);
    return json(404, { error: { message: 'Not found' } });
  }
  if (url.origin === new URL(upstream.localEndpoint).origin) {
    if (method === 'GET' && url.pathname === '/v1/models') return modelList(upstream.localModels);
    if (method === 'GET' && url.pathname === '/api/tags') {
      return json(200, { models: upstream.localModels.map((name) => ({ name, model: name })) });
    }
    if (method === 'GET' && url.pathname === '/api/ps') {
      return json(200, { models: upstream.loadedLocalModels.map((name) => ({ name, model: name })) });
    }
    if (method === 'POST' && url.pathname === '/v1/chat/completions') return generationSuccess(url.pathname);
    return json(404, { error: 'not found' });
  }
  return null;
}

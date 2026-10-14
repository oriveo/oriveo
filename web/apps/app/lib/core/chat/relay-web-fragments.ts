/**
 * Local storage of connection-level web search fragments for relay: stores `{protocol: JSON object}` per connection id, on this device only
 * (not in cloud sync or backups), deleted along with the connection. Effective fragment = if the store has any segment use only the store, otherwise map legacy fields at read time.
 * Fixture: `test-fixtures/relay/web-fragment.v1.json`.
 */
import type { Provider } from '@oriveo/shared';
import {
  RELAY_WEB_FRAGMENT_TEMPLATES,
  isRelayWebTransport,
  validateRelayWebFragment,
  type RelayWebFragment,
  type RelayWebFragments,
  type RelayWebFragmentValidation,
  type RelayWebTransport,
} from '@oriveo/shared/relay/web-fragments';
import { effectiveRelayWebFragments } from '@oriveo/shared/relay/legacy-web-search';
import { safeLocalStorage } from '../../infra/storage/web-storage';
import { getWebSearchProfile } from '../metadata/metadata-client';

export const RELAY_WEB_FRAGMENTS_STORAGE_KEY = 'oriveo.relay-web-fragments.v1';

type StoredConnections = Record<string, RelayWebFragments>;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

// Bad data / unavailable storage is always read as empty: an absent fragment only makes requests carry no web search fields.
function readAll(): StoredConnections {
  try {
    const raw = safeLocalStorage.getItem(RELAY_WEB_FRAGMENTS_STORAGE_KEY);
    if (!raw) return {};
    const connections = (JSON.parse(raw) as { connections?: unknown })?.connections;
    if (!isPlainObject(connections)) return {};
    const result: StoredConnections = {};
    for (const [connectionId, entry] of Object.entries(connections)) {
      if (!isPlainObject(entry)) continue;
      const fragments: RelayWebFragments = {};
      for (const [transport, fragment] of Object.entries(entry)) {
        if (isRelayWebTransport(transport) && isPlainObject(fragment) && Object.keys(fragment).length > 0) {
          fragments[transport] = fragment;
        }
      }
      if (Object.keys(fragments).length > 0) result[connectionId] = fragments;
    }
    return result;
  } catch {
    return {};
  }
}

function writeAll(connections: StoredConnections): void {
  try {
    if (Object.keys(connections).length === 0) {
      safeLocalStorage.removeItem(RELAY_WEB_FRAGMENTS_STORAGE_KEY);
      return;
    }
    safeLocalStorage.setItem(RELAY_WEB_FRAGMENTS_STORAGE_KEY, JSON.stringify({ version: 1, connections }));
  } catch {
    // On a failed write the settings page returns as usual; the next save writes again.
  }
}

export function readStoredRelayWebFragments(connectionId: string): RelayWebFragments {
  return readAll()[connectionId] ?? {};
}

/** Replace a whole connection (save on the web search settings page): segments not given are deleted; with no segment at all the connection is removed. */
export function replaceRelayWebFragments(connectionId: string, fragments: RelayWebFragments): void {
  const all = readAll();
  const kept: RelayWebFragments = {};
  for (const [transport, fragment] of Object.entries(fragments)) {
    if (isRelayWebTransport(transport) && fragment && Object.keys(fragment).length > 0) kept[transport] = fragment;
  }
  if (Object.keys(kept).length > 0) all[connectionId] = kept;
  else delete all[connectionId];
  writeAll(all);
}

/** Store one segment: validate first, write only if it passes. */
export function saveRelayWebFragment(
  connectionId: string,
  transport: RelayWebTransport,
  raw: string,
): RelayWebFragmentValidation {
  const validation = validateRelayWebFragment(raw);
  if (!validation.ok) return validation;
  replaceRelayWebFragments(connectionId, { ...readStoredRelayWebFragments(connectionId), [transport]: validation.fragment });
  return validation;
}

export function clearRelayWebFragment(connectionId: string, transport: RelayWebTransport): void {
  const { [transport]: _removed, ...rest } = readStoredRelayWebFragments(connectionId);
  replaceRelayWebFragments(connectionId, rest);
}

/** Called when a connection is deleted. */
export function deleteRelayWebFragmentsConnection(connectionId: string): void {
  const all = readAll();
  if (!(connectionId in all)) return;
  delete all[connectionId];
  writeAll(all);
}

/** The effective fragments of this connection (legacy fields mapped at read time); local engine connections have no web search row and are always empty. */
export function effectiveRelayWebFragmentsForProvider(
  provider: Pick<Provider, 'id' | 'relayRequested'>,
): RelayWebFragments {
  if (provider.relayRequested?.engineProfile) return {};
  return effectiveRelayWebFragments(readStoredRelayWebFragments(provider.id), provider.relayRequested, getWebSearchProfile);
}

/** The segment of this turn's effective protocol (for outbound merging); undefined if none. */
export function relayWebFragmentForTransport(
  provider: Pick<Provider, 'id' | 'relayRequested'>,
  transport: string | undefined,
): RelayWebFragment | undefined {
  if (!isRelayWebTransport(transport)) return undefined;
  return effectiveRelayWebFragmentsForProvider(provider)[transport];
}

/**
 * Effective fragment of a protocol: the stored fragment, or that protocol's built-in template when none is stored; source says which one it is.
 * The "current record" is a record whose hash equals its hash; with the chat switch on, the request merges this one too. A protocol outside the four web protocols -> undefined.
 */
export function relayEffectiveWebFragment(
  provider: Pick<Provider, 'id' | 'relayRequested'>,
  transport: string | undefined,
): { fragment: RelayWebFragment; source: 'saved' | 'template' } | undefined {
  if (!isRelayWebTransport(transport)) return undefined;
  const saved = relayWebFragmentForTransport(provider, transport);
  return saved
    ? { fragment: saved, source: 'saved' }
    : { fragment: structuredClone(RELAY_WEB_FRAGMENT_TEMPLATES[transport]) as RelayWebFragment, source: 'template' };
}

/**
 * sessionStorage fallback for streaming partials, across any number of conversations.
 *
 * Covers the user closing the tab, force-reloading, or the browser crashing mid-stream.
 * An IDB transaction is not guaranteed to commit inside the synchronous pagehide context, whereas
 * sessionStorage is a synchronous API and does. On startup hydration, if the message.text in IDB is
 * shorter than the backup, the backup wins.
 *
 * The stored value is a `Record<convId, StreamPartialBackup>` rather than a single entry, so any
 * number of concurrent streams can be backed up together on pagehide.
 *
 * sessionStorage constraints:
 *   - isolated per tab, which is fine because each tab has its own streams
 *   - still visible after a reload in the same tab
 *   - the 5MB cap leaves plenty of room for partial text (10 streams stay under 500KB)
 *   - being synchronous, the write completes during pagehide
 */

const KEY = 'oriveo.streamPartialBackup';

export interface StreamPartialBackup {
  conversationId: string;
  msgId: string;
  partial: string;
  ts: number;
  managedRequestId?: string;
  lastSseSequence?: number;
}

export type StreamPartialBackupMap = Record<string, StreamPartialBackup>;

function isBrowser(): boolean {
  return typeof window !== 'undefined' && typeof window.sessionStorage !== 'undefined';
}

function isValidEntry(v: unknown): v is StreamPartialBackup {
  if (!v || typeof v !== 'object') return false;
  const e = v as Partial<StreamPartialBackup>;
  return (
    typeof e.conversationId === 'string' &&
    typeof e.msgId === 'string' &&
    typeof e.partial === 'string' &&
    typeof e.ts === 'number' &&
    (e.managedRequestId === undefined || typeof e.managedRequestId === 'string') &&
    (e.lastSseSequence === undefined || typeof e.lastSseSequence === 'number')
  );
}

export function writeStreamPartialBackup(map: StreamPartialBackupMap): void {
  if (!isBrowser()) return;
  try {
    window.sessionStorage.setItem(KEY, JSON.stringify(map));
  } catch {
    // quota or storage disabled: fail silently, IDB is the primary path
  }
}

export function readStreamPartialBackup(): StreamPartialBackupMap {
  if (!isBrowser()) return {};
  try {
    const raw = window.sessionStorage.getItem(KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== 'object') return {};

    // Older format: upgrade a single entry to a map
    if (isValidEntry(parsed)) {
      return { [parsed.conversationId]: parsed };
    }

    const result: StreamPartialBackupMap = {};
    for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
      if (isValidEntry(v)) result[k] = v;
    }
    return result;
  } catch {
    return {};
  }
}

/** Writes or updates one backup without touching the other conversations. */
export function upsertStreamPartialBackup(entry: StreamPartialBackup): void {
  if (!isBrowser()) return;
  const map = readStreamPartialBackup();
  map[entry.conversationId] = entry;
  writeStreamPartialBackup(map);
}

/** Clears the whole map when convId is omitted, or just that conversation when it is given. */
export function clearStreamPartialBackup(convId?: string): void {
  if (!isBrowser()) return;
  try {
    if (convId === undefined) {
      window.sessionStorage.removeItem(KEY);
      return;
    }
    const map = readStreamPartialBackup();
    if (!(convId in map)) return;
    delete map[convId];
    if (Object.keys(map).length === 0) {
      window.sessionStorage.removeItem(KEY);
    } else {
      writeStreamPartialBackup(map);
    }
  } catch {
    // ignore
  }
}

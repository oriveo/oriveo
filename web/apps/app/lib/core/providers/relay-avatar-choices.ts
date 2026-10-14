import { readPartitionedStore, writePartitionedStore } from '../../infra/storage/partitioned-local-store';
import {
  relayAvatarPickerCellChoice,
  type RelayAvatarPickerCell,
} from '../../../components/relay-avatar';

/**
 * On-device relay avatar choice: key = connection id, value = icon id or "letter".
 *
 * Stored on this device only, in per-UID partitioned localStorage (a connection belongs to an account; partitioning keeps A's choices from being left behind for B),
 * never in the sync adapter, backups or an IDB column. Changes notify subscribers right away, so every place that draws a relay avatar refreshes together.
 */
const KEY = 'relay-avatar-choices.v1';

type Choices = Readonly<Record<string, string>>;

const listeners = new Set<() => void>();
let cachedRaw: string | null | undefined;
let cachedChoices: Choices = {};

function parse(raw: string | null): Choices {
  if (!raw) return {};
  try {
    const value: unknown = JSON.parse(raw);
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
    const out: Record<string, string> = {};
    for (const [id, choice] of Object.entries(value as Record<string, unknown>)) {
      if (typeof choice === 'string' && choice) out[id] = choice;
    }
    return out;
  } catch {
    return {};
  }
}

/** Reads the whole table of the current partition; returns the same object while the raw text is unchanged, so useSyncExternalStore gets a stable snapshot. */
function readChoices(): Choices {
  const raw = readPartitionedStore(KEY);
  if (raw !== cachedRaw) {
    cachedRaw = raw;
    cachedChoices = parse(raw);
  }
  return cachedChoices;
}

function writeChoices(next: Choices): void {
  writePartitionedStore(KEY, JSON.stringify(next));
  for (const listener of [...listeners]) listener();
}

export function getRelayAvatarChoice(providerId: string | null | undefined): string | undefined {
  if (!providerId) return undefined;
  return readChoices()[providerId];
}

/** Stores one choice; `null` = remove (brand cell picked). */
export function setRelayAvatarChoice(providerId: string, choice: string | null): void {
  if (!providerId) return;
  const current = readChoices();
  if (choice === null) {
    if (!(providerId in current)) return;
    const next = { ...current };
    delete next[providerId];
    writeChoices(next);
    return;
  }
  if (current[providerId] === choice) return;
  writeChoices({ ...current, [providerId]: choice });
}

/** Sheet cell tapped: the brand cell removes the choice, an icon cell stores the icon id, the initial cell stores "letter". */
export function applyRelayAvatarPickerCell(providerId: string, cell: RelayAvatarPickerCell): void {
  setRelayAvatarChoice(providerId, relayAvatarPickerCellChoice(cell));
}

/** Called when a connection is deleted. */
export function clearRelayAvatarChoice(providerId: string): void {
  setRelayAvatarChoice(providerId, null);
}

export function subscribeRelayAvatarChoices(listener: () => void): () => void {
  listeners.add(listener);
  // Another tab changed the same partition: the storage event fires only in other tabs, so forward it to subscribers here.
  const onStorage = (event: StorageEvent) => {
    if (event.key === null || event.key.endsWith(`.${KEY}`)) listener();
  };
  if (typeof window !== 'undefined') window.addEventListener('storage', onStorage);
  return () => {
    listeners.delete(listener);
    if (typeof window !== 'undefined') window.removeEventListener('storage', onStorage);
  };
}

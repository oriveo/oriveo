/**
 * Local ledger of "prompt only once per key per device": keys are stored as a string array in localStorage, and the oldest is dropped past the limit.
 *
 * The storage is neither backed up nor synced; losing it only means the same key is prompted once more. When storage is unavailable (private mode / quota full),
 * writes degrade silently and the prompt shows again next time.
 */
import { safeLocalStorage } from '../../infra/storage/web-storage';

export interface SeenOnceLedger {
  has(key: string): boolean;
  record(key: string): void;
}

export function createSeenOnceLedger(storageKey: string, max: number): SeenOnceLedger {
  const read = (): string[] => {
    try {
      const raw = safeLocalStorage.getItem(storageKey);
      if (!raw) return [];
      const parsed: unknown = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === 'string') : [];
    } catch {
      return [];
    }
  };
  return {
    has: (key) => read().includes(key),
    record: (key) => {
      const current = read();
      if (current.includes(key)) return;
      const next = [...current, key];
      safeLocalStorage.setItem(storageKey, JSON.stringify(next.slice(Math.max(0, next.length - max))));
    },
  };
}

/**
 * One-time hint shown when a new chat's preferred model was retired and the selection fell back to the
 * catalog default: shown once per device per "connection x retired model", recorded as soon as it is shown.
 *
 * Reads only the selection snapshot's defaultModelHint (`last_used_retired`); it plays no part in model
 * resolution or send decisions. The ledger is neither backed up nor synced, so losing it merely shows the
 * same hint once more. Storage shape follows input-capability-hint.
 */
import { createSeenOnceLedger } from '../capability/seen-once-ledger';

/** Capped at the number of "connection x retired model" pairs a user realistically meets; the oldest are dropped past the cap. */
const modelRetiredHintLedger = createSeenOnceLedger('oriveo.model-retired-hint-seen.v1', 300);

function hintSeenEntryKey(providerId: string, modelId: string): string {
  return `${providerId}|${modelId}`;
}

/**
 * Call when a new chat resolves a hint: if the hint is last_used_retired and this retired model has not been
 * recorded under this connection, return true and record it immediately; otherwise false. The caller shows
 * `pages.chat.lastUsedModelRetiredHint` only on true.
 */
export function consumeModelRetiredHint(
  providerId: string | null | undefined,
  retiredModelId: string | null | undefined,
  hint: 'last_used_retired' | null | undefined,
): boolean {
  if (!providerId || !retiredModelId) return false;
  if (hint !== 'last_used_retired') return false;
  const key = hintSeenEntryKey(providerId, retiredModelId);
  if (modelRetiredHintLedger.has(key)) return false;
  modelRetiredHintLedger.record(key);
  return true;
}

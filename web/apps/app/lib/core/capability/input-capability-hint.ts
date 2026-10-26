/**
 * First-attachment light hint when an input capability is unknown: shown once per model per device, recorded as soon as it is shown.
 *
 * It only reads the projection hint (`first_attach_once`) and takes part in no send decision; the storage is neither backed up nor synced,
 * and losing it only means the same model is prompted once more. The storage shape follows PROFILE_SEEN_KEY of generation-panel-presentation.
 */
import type { InputCapabilityProjection } from '@oriveo/core/providers/capability-evidence-facade';
import { createSeenOnceLedger } from './seen-once-ledger';

export type InputCapabilityMedia = 'image' | 'file' | 'video';

/** The limit is sized by the connection x model combinations one user actually uses; the oldest is dropped past it so the ledger cannot grow without bound. */
const inputCapabilityHintLedger = createSeenOnceLedger('oriveo.input-capability-hint-seen.v1', 300);

function hintSeenEntryKey(providerId: string, modelId: string): string {
  return `${providerId}|${modelId}`;
}

export function hasSeenInputCapabilityHint(providerId: string, modelId: string): boolean {
  return inputCapabilityHintLedger.has(hintSeenEntryKey(providerId, modelId));
}

/**
 * Call right after an attachment is accepted: when the projection hint is first_attach_once and the model has not been recorded, return true and record it at once;
 * otherwise always false. Only when the caller gets true does it show `capability.input.hintFirstAttach.<media>`.
 */
export function consumeFirstAttachHint(
  providerId: string | null | undefined,
  modelId: string | null | undefined,
  projection: Pick<InputCapabilityProjection, 'hint'> | null | undefined,
): boolean {
  if (!providerId || !modelId) return false;
  if (projection?.hint !== 'first_attach_once') return false;
  if (hasSeenInputCapabilityHint(providerId, modelId)) return false;
  inputCapabilityHintLedger.record(hintSeenEntryKey(providerId, modelId));
  return true;
}

/** Hint copy key (relative to the `capability.input` namespace). */
export function firstAttachHintMessageKey(media: InputCapabilityMedia): string {
  return `hintFirstAttach.${media}`;
}

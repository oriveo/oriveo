/**
 * One-tap action after an official upstream rejection (fixture rejection-recovery.v1.json).
 * The action comes only from the rejection result the failed message recorded itself: signature hit, official connection, no text produced, media really sent (these are
 * decided by `recordOfficialInputRejection` before it returns a record). The negative cache / projection `rejected_recently` alone gives no action;
 * without a signature hit only the raw upstream error is shown and no media action is offered. Generalized over image / file / video by capabilityKey.
 */
import type { ChatMessage } from '@oriveo/shared';
import type { OfficialRejectionResult } from './input-rejection-flow';

export type RejectionRecoveryAction =
  | 'resend_without_images'
  | 'resend_without_files'
  | 'resend_without_videos'
  | 'resend_without_parameter';

export type RejectedMedia = 'image' | 'file' | 'video';

type InputRejectionRecord = NonNullable<ChatMessage['inputRejection']>;

const ACTION_BY_KEY: Readonly<Record<InputRejectionRecord['capabilityKey'], RejectionRecoveryAction>> = {
  vision_input: 'resend_without_images',
  file_input: 'resend_without_files',
  video_input: 'resend_without_videos',
};

const MEDIA_BY_ACTION: Readonly<Partial<Record<RejectionRecoveryAction, RejectedMedia>>> = {
  resend_without_images: 'image',
  resend_without_files: 'file',
  resend_without_videos: 'video',
};

/** Rejection record on a failed message -> one-tap action; null when the answer did not fail or there is no record. */
export function rejectionRecoveryAction(
  message: Pick<ChatMessage, 'role' | 'state' | 'inputRejection' | 'generationParameterRejection'>,
): RejectionRecoveryAction | null {
  if (message.role !== 'assistant' || message.state !== 'failed') return null;
  const key = message.inputRejection?.capabilityKey;
  if (key && ACTION_BY_KEY[key]) return ACTION_BY_KEY[key];
  // A rejected parameter goes through the existing generationParameterRejection card: resend without that parameter.
  if (message.generationParameterRejection?.parameterId) return 'resend_without_parameter';
  return null;
}

/**
 * Items the signature names that are not panel generation parameters (web / tools / thinking): the failure card title uses the existing capability name copy
 * (the full key counted from the root) instead of the raw parameter name.
 */
const SIGNATURE_PARAMETER_TITLE_KEYS: Readonly<Record<string, string>> = {
  enable_search: 'common.capabilityControlWebSearch',
  tools: 'capability.toolCall',
  thinking: 'common.capabilityControlThinking',
};

export function signatureParameterTitleKey(parameter: string): string | undefined {
  return SIGNATURE_PARAMETER_TITLE_KEYS[parameter];
}

/** Media of the action (failure card `resendWithout.<media>` copy); undefined for a parameter action or no action. */
export function rejectedMediaOf(action: RejectionRecoveryAction | null): RejectedMedia | undefined {
  return action ? MEDIA_BY_ACTION[action] : undefined;
}

/**
 * Return value of `recordOfficialInputRejection` -> fields stored on the failed message: a rejected media records `inputRejection`,
 * a rejected parameter records `generationParameterRejection` in the existing shape (the parameter the signature names).
 */
export function rejectionMessagePatch(
  result: OfficialRejectionResult | null | undefined,
): Pick<ChatMessage, 'inputRejection' | 'generationParameterRejection'> {
  if (!result) return {};
  if (result.kind === 'param_rejected') {
    // Carry the signature origin: the failure card uses it to tell signature hits from the generic panel parameter ruling (only the former uses the two-button layout).
    return result.parameter
      ? { generationParameterRejection: { parameterId: result.parameter, signatureId: result.signatureId } }
      : {};
  }
  if (!(result.capabilityKey in ACTION_BY_KEY)) return {};
  return {
    inputRejection: {
      capabilityKey: result.capabilityKey as InputRejectionRecord['capabilityKey'],
      signatureId: result.signatureId,
    },
  };
}

/** Media rejection record the send layer attaches to the error object (passed the same way as generationParameterRejection). */
export function officialInputRejectionOf(error: unknown): InputRejectionRecord | undefined {
  const value = error && typeof error === 'object'
    ? (error as { officialInputRejection?: unknown }).officialInputRejection
    : undefined;
  if (!value || typeof value !== 'object') return undefined;
  const { capabilityKey, signatureId } = value as { capabilityKey?: unknown; signatureId?: unknown };
  if (typeof capabilityKey !== 'string' || !(capabilityKey in ACTION_BY_KEY) || typeof signatureId !== 'string') return undefined;
  return { capabilityKey: capabilityKey as InputRejectionRecord['capabilityKey'], signatureId };
}

/**
 * Attach the hit result to the error object for the failure persistence to read: media goes to `officialInputRejection`; a parameter goes to
 * `generationParameterRejection` (a parameter already named by the send-layer resolver wins and is not overwritten; when the same parameter is named only the signature origin is added).
 */
export function attachOfficialInputRejection(error: unknown, result: OfficialRejectionResult | null | undefined): void {
  if (!error || typeof error !== 'object') return;
  const patch = rejectionMessagePatch(result);
  if (patch.inputRejection) Object.assign(error, { officialInputRejection: patch.inputRejection });
  const signed = patch.generationParameterRejection;
  if (!signed) return;
  const existing = (error as { generationParameterRejection?: { parameterId?: unknown } }).generationParameterRejection;
  if (!existing) {
    Object.assign(error, { generationParameterRejection: signed });
  } else if (existing.parameterId === signed.parameterId && signed.signatureId) {
    // The generic ruling and the signature name the same parameter: the origin follows the signature, only signatureId is added (the failure card uses it to show two buttons).
    Object.assign(error, { generationParameterRejection: { ...existing, signatureId: signed.signatureId } });
  }
}

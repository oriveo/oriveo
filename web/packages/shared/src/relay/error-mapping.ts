/**
 * Mapping for in-stream Relay Responses errors.
 *
 * The Responses API sends `event: error` and `event: response.failed` as in-stream errors over
 * HTTP 200: the stream starts normally and then the upstream raises a moderation or tool failure
 * mid-run. Ignoring them silently leaves the user with an empty message, so the upstream message
 * is always preserved; the code is only mapped to recovery-action semantics and never rewrites
 * the user-facing text.
 */
export type RelayStreamErrorKind = 'moderation' | 'imageGenUser' | 'upstream';

export interface MappedRelayStreamError {
  errorKind: RelayStreamErrorKind;
  /**
   * Raw upstream error text. The neutral fallback is used only when the upstream sends no message.
   */
  message: string;
  /**
   * Used only to choose a recovery action; it must never replace the upstream message with
   * localized copy.
   * - `moderation`: blocked by the upstream safety system (copyrighted characters, real people,
   *   sensitive content)
   * - `imageGenUser`: the image generation tool failed because of the prompt or the model id
   * - message passthrough: undefined
   */
  i18nKey?: 'moderation' | 'imageGenUser';
}

const FALLBACK_MESSAGE =
  'The provider returned an error for this request. Please retry or switch models.';
/**
 * Map the `code` and `message` of an in-stream Responses error to an error object the UI can use.
 *
 * @param code error code returned by the upstream, possibly empty
 * @param message error description returned by the upstream, possibly empty, used as fallback copy
 */
export function mapRelayStreamError(
  code: string | null | undefined,
  message: string | null | undefined,
): MappedRelayStreamError {
  const lower = (code ?? '').trim().toLowerCase();
  const upstreamMessage = (message ?? '').trim();

  if (lower === 'moderation_blocked' || /safety system/i.test(upstreamMessage)) {
    return {
      errorKind: 'moderation',
      message: upstreamMessage || FALLBACK_MESSAGE,
      i18nKey: 'moderation',
    };
  }

  if (lower.includes('image_generation')) {
    return {
      errorKind: 'imageGenUser',
      message: upstreamMessage || FALLBACK_MESSAGE,
      i18nKey: 'imageGenUser',
    };
  }

  return {
    errorKind: 'upstream',
    message: upstreamMessage || FALLBACK_MESSAGE,
  };
}

// ModerationProvider Moderation API: the content gate an image generation prompt passes through
// before it is sent upstream. Only decision==='allow' is let through; flag, deny and any call
// failure fail closed and block, with a 5s timeout. Required for compliance on an image and
// video generation product.

const DEFAULT_BASE_URL = 'https://api.moderation_provider.io';
const MODERATION_PATH = '/v1/moderation/prompt';
const TIMEOUT_MS = 5000;

// errorKind sent when moderation blocks a prompt; the client localises it (see mapErrorKindKey -> errors.moderationBlocked).
export const MODERATION_ERROR_KIND = 'moderation';

// Fallback English copy used as the message of the error event; the title is localised from errorKind.
export const MODERATION_BLOCK_MESSAGE =
  'This prompt was blocked by content moderation. Please revise it and try again.';

type ModerationDecision = 'allow' | 'flag' | 'deny';

/** Whether responseAdapter is an image generation adapter (*_images_api), which decides if moderation is needed. */
export function isImageResponseAdapter(adapter: string | undefined): boolean {
  return typeof adapter === 'string' && adapter.endsWith('_images_api');
}

/**
 * Whether an image generation prompt may proceed: true means generate, false means blocked
 * (fail closed). Only an explicit decision==='allow' passes; flag, deny, a non-2xx response, a
 * network error and a timeout all block.
 */
export async function isImagePromptAllowed(
  prompt: string,
  externalId?: string,
): Promise<boolean> {
  const apiKey = process.env.MODERATION_MODERATION_API_KEY;
  if (!apiKey) {
    // A missing key in production is a misconfiguration and fails closed; outside production it is skipped so local and CI work is not blocked.
    return process.env.NODE_ENV !== 'production';
  }

  const baseURL = process.env.MODERATION_MODERATION_BASE_URL || DEFAULT_BASE_URL;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${baseURL}${MODERATION_PATH}`, {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify(
        externalId ? { prompt, external_id: externalId } : { prompt },
      ),
      signal: controller.signal,
    });
    if (!res.ok) return false; // 4xx/5xx → fail-closed
    const data = (await res.json().catch(() => null)) as {
      decision?: ModerationDecision;
    } | null;
    return data?.decision === 'allow'; // only allow passes
  } catch {
    return false; // network error, timeout or abort: fail closed
  } finally {
    clearTimeout(timer);
  }
}

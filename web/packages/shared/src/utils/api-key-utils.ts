/**
 * Build the masked preview text for an API key.
 *
 * - empty string -> empty string: the preview never carries "not set" or "no key needed" meaning,
 *   which belongs to the credential state machine. Drawing mask dots for a key that does not exist
 *   makes "no key" look like "a key you cannot see".
 * - <=12 characters are fully masked: showing 4 characters at each end of a short key reveals two thirds of it.
 * - otherwise the first 4 plus a mask plus the last 4.
 * Example: `sk-abc123xyz7890` -> `sk-a...7890`
 */
export function formatApiKeyPreview(key: string): string {
  const trimmed = key.trim();
  if (!trimmed) return '';
  if (trimmed.length <= 12) return '••••••••';
  return trimmed.slice(0, 4) + '...' + trimmed.slice(-4);
}

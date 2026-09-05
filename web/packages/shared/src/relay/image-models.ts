/**
 * Detection of dedicated image models.
 *
 * The OpenAI `gpt-image-*` and `chatgpt-image-*` models reject the `response_format` field on the
 * `/v1/images/generations` endpoint; b64_json is the default anyway. Sending it explicitly is
 * rejected with HTTP 400 and `Unknown parameter` by OpenAI directly, and by any relay that
 * forwards the request body unchanged.
 *
 * Prefix match only, case insensitive.
 */
export function isDedicatedImageModel(modelId: string | null | undefined): boolean {
  if (!modelId) return false;
  const lower = modelId.toLowerCase();
  return lower.startsWith('gpt-image-') || lower.startsWith('chatgpt-image-');
}

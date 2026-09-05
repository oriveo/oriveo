import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { isImagePromptAllowed } from './moderation';

const fetchMock = vi.fn();

function moderationResponse(decision: string): Response {
  return new Response(
    JSON.stringify({
      id: 'mod_1',
      object: 'moderation_result',
      decision,
      usage: { units: 1 },
    }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
}

describe('isImagePromptAllowed', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.stubGlobal('fetch', fetchMock);
    fetchMock.mockReset();
    vi.stubEnv('MODERATION_MODERATION_API_KEY', 'moderation_provider_test_key');
    vi.stubEnv('MODERATION_MODERATION_BASE_URL', '');
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('allows a prompt when ModerationProvider returns decision=allow', async () => {
    fetchMock.mockResolvedValue(moderationResponse('allow'));
    await expect(isImagePromptAllowed('a watercolor lighthouse')).resolves.toBe(true);
  });

  it('blocks a prompt when ModerationProvider returns decision=deny', async () => {
    fetchMock.mockResolvedValue(moderationResponse('deny'));
    await expect(isImagePromptAllowed('disallowed prompt')).resolves.toBe(false);
  });

  it('blocks a prompt when ModerationProvider returns decision=flag (treated as deny)', async () => {
    fetchMock.mockResolvedValue(moderationResponse('flag'));
    await expect(isImagePromptAllowed('borderline prompt')).resolves.toBe(false);
  });

  it('fails closed when the moderation API returns a non-2xx status', async () => {
    fetchMock.mockResolvedValue(new Response('forbidden', { status: 403 }));
    await expect(isImagePromptAllowed('a cat')).resolves.toBe(false);
  });

  it('fails closed when the moderation call throws (network error / timeout)', async () => {
    fetchMock.mockRejectedValue(new Error('network down'));
    await expect(isImagePromptAllowed('a cat')).resolves.toBe(false);
  });

  it('fails closed when the response body has no decision field', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ id: 'x' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );
    await expect(isImagePromptAllowed('a cat')).resolves.toBe(false);
  });

  it('posts the prompt and external_id to the ModerationProvider endpoint with the api key header', async () => {
    fetchMock.mockResolvedValue(moderationResponse('allow'));

    await isImagePromptAllowed('a lighthouse at sunset', 'openAI:gpt-image-1');

    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.moderation_provider.io/v1/moderation/prompt',
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({ 'x-api-key': 'moderation_provider_test_key' }),
      }),
    );
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body))).toEqual({
      prompt: 'a lighthouse at sunset',
      external_id: 'openAI:gpt-image-1',
    });
  });

  it('skips moderation (allows) when no api key is configured outside production', async () => {
    vi.stubEnv('MODERATION_MODERATION_API_KEY', '');
    vi.stubEnv('NODE_ENV', 'test');

    await expect(isImagePromptAllowed('a cat')).resolves.toBe(true);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('fails closed when no api key is configured in production', async () => {
    vi.stubEnv('MODERATION_MODERATION_API_KEY', '');
    vi.stubEnv('NODE_ENV', 'production');

    await expect(isImagePromptAllowed('a cat')).resolves.toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

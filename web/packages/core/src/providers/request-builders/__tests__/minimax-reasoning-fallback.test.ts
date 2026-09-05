import { describe, expect, it } from 'vitest';
import { buildMiniMaxRequest } from '../minimax';

describe('MiniMax OpenAI reasoning fallback', () => {
  it.each([true, false])('always sends reasoning_split for stream=%s chat', (stream) => {
    const request = buildMiniMaxRequest({
      providerKind: 'miniMax', apiKey: 'key', modelID: 'MiniMax-M2.7', stream,
      messages: [{ role: 'user', content: 'hello' }],
    }, { reasoning_split: false }, null);
    expect(request.body.reasoning_split).toBe(true);
    expect(request.responseAdapter).toBe('minimax_chat_stream');
  });

  it('never leaks reasoning_split into the image endpoint', () => {
    const request = buildMiniMaxRequest({
      providerKind: 'miniMax', apiKey: 'key', modelID: 'image-01',
      messages: [{ role: 'user', content: 'draw' }],
    }, null, { route: 'minimax_image_generation', requestDefaults: { n: 1 } });
    expect(request.body).not.toHaveProperty('reasoning_split');
  });
});

// Web-search tool added per the web-search preference when an official provider switches to a non-native protocol (moved from the shared Relay builder to official-protocol;
// official-path behavior is unchanged). The same relay builders no longer add it automatically, see RD4-PATH-03 in relay-capability-test.test.ts.
import { describe, expect, it } from 'vitest';
import { buildOfficialAlternateProtocolRequest } from '../official-protocol';
import type { RequestParams } from '../types';

function params(supportsWebSearch: boolean): RequestParams {
  return {
    providerKind: 'openai',
    apiKey: 'sk-official',
    modelID: 'm',
    messages: [{ role: 'user', content: 'hi' }],
    options: { supportsWebSearch },
  } as unknown as RequestParams;
}

describe('web-search tool for official providers on a non-native protocol', () => {
  it('Responses: with web search on, web_search is added after image_generation; off, not added', () => {
    const on = buildOfficialAlternateProtocolRequest(params(true), 'openai_responses', 'https://api.example.com', null).body as Record<string, unknown>;
    expect(on.tools).toEqual([{ type: 'image_generation' }, { type: 'web_search' }]);
    const off = buildOfficialAlternateProtocolRequest(params(false), 'openai_responses', 'https://api.example.com', null).body as Record<string, unknown>;
    expect(off.tools).toEqual([{ type: 'image_generation' }]);
  });

  it('Gemini: with web search on, tools = googleSearch; off, no tools', () => {
    const on = buildOfficialAlternateProtocolRequest(params(true), 'gemini_generate_content', 'https://api.example.com', null).body as Record<string, unknown>;
    expect(on.tools).toEqual([{ googleSearch: {} }]);
    const off = buildOfficialAlternateProtocolRequest(params(false), 'gemini_generate_content', 'https://api.example.com', null).body as Record<string, unknown>;
    expect(off).not.toHaveProperty('tools');
  });
});

import { describe, it, expect } from 'vitest';
import { validateChatStreamRequest, VALIDATION_LIMITS } from '../validate';

const validBody = {
  providerKind: 'openAI',
  apiKey: 'sk-test',
  modelID: 'gpt-4',
  messages: [{ role: 'user', content: 'hello' }],
};

const libraryTools = [
  {
    type: 'function',
    function: {
      name: 'library_search',
      description: 'Search Library',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: { query: { type: 'string' }, sources: { type: 'array' }, limit: { type: 'integer' } },
        required: ['query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'library_list',
      description: 'List Library',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: { source: { type: 'string' }, containerId: { type: ['string', 'null'] }, cursor: { type: ['string', 'null'] } },
        required: ['source'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'library_read',
      description: 'Read Library',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: { docId: { type: 'string' }, source: { type: 'string' }, section: { type: ['string', 'null'] }, cursor: { type: ['string', 'null'] } },
        required: ['docId', 'source'],
      },
    },
  },
];

describe('validateChatStreamRequest', () => {
  it('accepts a valid payload', () => {
    const r = validateChatStreamRequest(validBody);
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.value.providerKind).toBe('openAI');
      expect(r.value.apiKey).toBe('sk-test');
    }
  });

  it('rejects a non-object body', () => {
    expect(validateChatStreamRequest(null).ok).toBe(false);
    expect(validateChatStreamRequest('string').ok).toBe(false);
    expect(validateChatStreamRequest([]).ok).toBe(false);
  });

  it('rejects a missing apiKey', () => {
    const r = validateChatStreamRequest({ ...validBody, apiKey: undefined });
    expect(r.ok).toBe(false);
  });

  it('rejects an over-long apiKey', () => {
    const r = validateChatStreamRequest({
      ...validBody,
      apiKey: 'x'.repeat(VALIDATION_LIMITS.MAX_API_KEY_LEN + 1),
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.status).toBe(400);
  });

  it('rejects an unknown providerKind', () => {
    const r = validateChatStreamRequest({ ...validBody, providerKind: 'fakeProvider' });
    expect(r.ok).toBe(false);
  });

  it('allows only http/https in the baseURL scheme allowlist', () => {
    expect(validateChatStreamRequest({ ...validBody, baseURL: 'https://api.x.com' }).ok).toBe(true);
    expect(validateChatStreamRequest({ ...validBody, baseURL: 'http://localhost:8080' }).ok).toBe(true);
    expect(validateChatStreamRequest({ ...validBody, baseURL: 'file:///etc/passwd' }).ok).toBe(false);
    expect(validateChatStreamRequest({ ...validBody, baseURL: 'ftp://x.com' }).ok).toBe(false);
    expect(validateChatStreamRequest({ ...validBody, baseURL: 'data:text/plain,xxx' }).ok).toBe(false);
  });

  it('allows a baseURL with no scheme, since safeBase downstream prepends https:// to match how storage and sync omit it', () => {
    // The storage layer's updateProviderBaseURL does not add a scheme, so DeepSeek and others are commonly stored as 'api.deepseek.com/v1'.
    expect(validateChatStreamRequest({ ...validBody, baseURL: 'api.deepseek.com/v1' }).ok).toBe(true);
    expect(validateChatStreamRequest({ ...validBody, baseURL: 'localhost:8080' }).ok).toBe(true);
  });

  it('rejects too many messages', () => {
    const r = validateChatStreamRequest({
      ...validBody,
      messages: new Array(VALIDATION_LIMITS.MAX_MESSAGES_COUNT + 1).fill({ role: 'user', content: 'x' }),
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.status).toBe(400);
  });

  it('rejects a single over-long content', () => {
    const r = validateChatStreamRequest({
      ...validBody,
      messages: [{ role: 'user', content: 'x'.repeat(VALIDATION_LIMITS.MAX_CONTENT_BYTES + 1) }],
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.status).toBe(413);
  });

  it('rejects a single over-long base64 image inside messages', () => {
    const r = validateChatStreamRequest({
      ...validBody,
      messages: [{
        role: 'user',
        content: [
          { type: 'text', text: 'see image' },
          { type: 'image_url', image_url: { url: 'data:image/png;base64,' + 'A'.repeat(VALIDATION_LIMITS.MAX_CONTENT_BYTES + 1) } },
        ],
      }],
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.status).toBe(413);
  });

  it('rejects an empty messages array', () => {
    const r = validateChatStreamRequest({ ...validBody, messages: [] });
    expect(r.ok).toBe(false);
  });

  it('rejects a non-array messages', () => {
    const r = validateChatStreamRequest({ ...validBody, messages: 'string' });
    expect(r.ok).toBe(false);
  });

  it('rejects a non-object options', () => {
    const r = validateChatStreamRequest({ ...validBody, options: 'invalid' });
    expect(r.ok).toBe(false);
  });

  it('allows options to be absent', () => {
    const r = validateChatStreamRequest(validBody);
    expect(r.ok).toBe(true);
  });

  it('custom fragment accepts raw JSON only; callers cannot forge owner declarations', () => {
    expect(validateChatStreamRequest({ ...validBody, options: { customFragment: { raw: '{"temperature":0.2}' } } })).toMatchObject({ ok: true });
    expect(validateChatStreamRequest({ ...validBody, options: { customFragments: { web: { raw: '{"enable_search":true}' }, reasoning: { raw: '' }, generation: { raw: '{"max_output_tokens":256}' } } } })).toMatchObject({ ok: true });
    expect(validateChatStreamRequest({ ...validBody, options: { customFragments: { routing: { raw: '{}' } } } })).toMatchObject({ ok: false, error: 'customFragments invalid' });
    expect(validateChatStreamRequest({ ...validBody, options: { customFragments: { web: { raw: '{}', owner: 'web' } } } })).toMatchObject({ ok: false, error: 'customFragments invalid' });
    expect(validateChatStreamRequest({ ...validBody, options: { capabilityRecipeOmissions: [{ recipeRef: 'fixture.web.v1', locatedPointers: ['/web_search_options'] }] } })).toMatchObject({ ok: true });
    expect(validateChatStreamRequest({ ...validBody, options: { capabilityRecipeOmissions: [{ recipeRef: 'fixture.web.v1', locatedPointers: ['web_search_options'] }] } })).toMatchObject({ ok: false, error: 'capabilityRecipeOmissions invalid' });
    expect(validateChatStreamRequest({ ...validBody, options: { customFragment: { raw: '{"temperature":0.2}', owner: 'reasoning', declaredOwners: { '/temperature': 'reasoning' } } } })).toMatchObject({ ok: false, error: 'customFragment invalid' });
  });

  it('only accepts a contract-valid local continuation envelope', () => {
    const valid = validateChatStreamRequest({
      ...validBody,
      continuation: { kind: 'tool_loop', variant: 'fiber', step: 1, state: { completedMessages: [{ role: 'assistant', tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'web_search', arguments: '{}' } }] }, { role: 'tool', tool_call_id: 'call_1', content: 'opaque' }] } },
    });
    expect(valid).toMatchObject({ ok: true, value: { continuation: { kind: 'tool_loop', variant: 'fiber' } } });
    expect(validateChatStreamRequest({ ...validBody, continuation: { kind: 'unknown', step: 1, state: {} } })).toMatchObject({ ok: false, error: 'continuation invalid' });
  });

  it('preserves an explicit non-streaming mode and rejects non-boolean values', () => {
    expect(validateChatStreamRequest({ ...validBody, stream: false })).toMatchObject({ ok: true, value: { stream: false } });
    expect(validateChatStreamRequest({ ...validBody, stream: 'false' })).toMatchObject({ ok: false, error: 'stream must be a boolean' });
  });

  it('allows the complete Library tool contract and tool history messages', () => {
    const r = validateChatStreamRequest({
      ...validBody,
      tools: libraryTools,
      toolChoice: 'auto',
      messages: [
        { role: 'user', content: 'research' },
        { role: 'assistant', content: '', tool_calls: [{
          id: 'call-1', type: 'function', function: { name: 'library_search', arguments: '{"query":"roadmap"}' },
        }] },
        { role: 'tool', tool_call_id: 'call-1', content: '{"ok":true,"result":{"hits":[]}}' },
      ],
    });

    expect(r.ok).toBe(true);
  });

  it('rejects missing, duplicated or non-allowlisted Library tools', () => {
    expect(validateChatStreamRequest({ ...validBody, tools: libraryTools.slice(0, 2) }).ok).toBe(false);
    expect(validateChatStreamRequest({
      ...validBody,
      tools: [libraryTools[0], libraryTools[0], libraryTools[2]],
    }).ok).toBe(false);
    expect(validateChatStreamRequest({
      ...validBody,
      tools: libraryTools.map((tool, index) => index === 2
        ? { ...tool, function: { ...tool.function, name: 'fetch_url' } }
        : tool),
    }).ok).toBe(false);
  });

  it('rejects a tampered Library parameter schema', () => {
    expect(validateChatStreamRequest({
      ...validBody,
      tools: libraryTools.map((tool, index) => index === 0
        ? { ...tool, function: { ...tool.function, parameters: { ...tool.function.parameters, required: [] } } }
        : tool),
    }).ok).toBe(false);
    expect(validateChatStreamRequest({
      ...validBody,
      tools: libraryTools.map((tool, index) => index === 1
        ? { ...tool, function: { ...tool.function, parameters: {
          ...tool.function.parameters,
          properties: { ...tool.function.parameters.properties, arbitraryUrl: { type: 'string' } },
        } } }
        : tool),
    }).ok).toBe(false);
  });

  it('rejects an arbitrary tool call name and a toolChoice with no tool definition', () => {
    expect(validateChatStreamRequest({ ...validBody, toolChoice: 'auto' }).ok).toBe(false);
    expect(validateChatStreamRequest({
      ...validBody,
      messages: [{ role: 'assistant', content: '', tool_calls: [{
        id: 'call-1', type: 'function', function: { name: 'fetch_url', arguments: '{}' },
      }] }],
    }).ok).toBe(false);
  });
});

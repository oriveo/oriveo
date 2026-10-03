import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, it, expect } from 'vitest';
import { validateChatStreamRequest, VALIDATION_LIMITS } from '../validate';

/**
 * Shared source of truth for every client: `shared/test-fixtures/mcp/naming.json` (frozen).
 * Every expected output in it must pass the name pattern. The last segment has no
 * limit of its own precisely so that it cannot disagree with the fixture vectors;
 * this assertion keeps anyone from adding such a limit back.
 */
const NAMING_FIXTURE = JSON.parse(
  readFileSync(
    resolve(__dirname, '../../../../../../../../shared/test-fixtures/mcp/naming.json'),
    'utf8',
  ),
) as {
  version: number;
  cases: Array<{ caseId: string; expect: { outboundName: string; length: number } }>;
};

/** Boundary vectors for slug generation: a slug contains only [a-z0-9], is 1..16 long and never contains `-`. */
const IDENTIFIERS_FIXTURE = JSON.parse(
  readFileSync(
    resolve(__dirname, '../../../../../../../../shared/test-fixtures/mcp/identifiers.json'),
    'utf8',
  ),
) as {
  slugMake: { cases: Array<{ caseId: string; expect: string }> };
  slugUnique: { cases: Array<{ caseId: string; expect: string }> };
};

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

  // MCP tools

  // Every expected output in the fixture must pass this pattern. The last segment
  // deliberately has no limit of its own (truncation produces names by "total length ≤ 64"),
  // so this assertion keeps anyone from adding an inner limit that disagrees with the fixture.
  it('every expected output in the shared naming.json fixture passes the MCP name pattern', () => {
    expect(NAMING_FIXTURE.cases.length).toBeGreaterThan(0);
    for (const fixtureCase of NAMING_FIXTURE.cases) {
      const name = fixtureCase.expect.outboundName;
      expect(VALIDATION_LIMITS.MCP_TOOL_NAME_PATTERN.test(name), `${fixtureCase.caseId}: ${name}`).toBe(true);
      expect(name.length, `${fixtureCase.caseId}: ${name}`).toBeLessThanOrEqual(
        VALIDATION_LIMITS.MAX_MCP_TOOL_NAME_LEN,
      );
      expect(name.length, `${fixtureCase.caseId}: ${name}`).toBe(fixtureCase.expect.length);
    }
  });

  it('every slug in the shared identifiers.json fixture passes validation as mcp_<slug>_x', () => {
    const slugs = [
      ...IDENTIFIERS_FIXTURE.slugMake.cases,
      ...IDENTIFIERS_FIXTURE.slugUnique.cases,
    ];
    expect(IDENTIFIERS_FIXTURE.slugMake.cases.length).toBeGreaterThanOrEqual(12);
    expect(IDENTIFIERS_FIXTURE.slugUnique.cases.length).toBeGreaterThanOrEqual(6);
    for (const { caseId, expect: slug } of slugs) {
      const name = `mcp_${slug}_x`;
      expect(VALIDATION_LIMITS.MCP_TOOL_NAME_PATTERN.test(name), `${caseId}: ${name}`).toBe(true);
      // Not just the pattern: the full validation path (total length and tool shape) accepts it too
      expect(validateChatStreamRequest({ ...validBody, tools: [mcpTool(name)] }).ok, `${caseId}: ${name}`).toBe(true);
    }
    // The fixture covers a full-length slug of 16 characters
    expect(slugs.some(({ expect: slug }) => slug.length === 16)).toBe(true);
  });

  it('rejects a slug containing - (a slug never contains a hyphen)', () => {
    for (const name of [
      'mcp_my-server_x',
      'mcp_notion-2_x',
      'mcp_-notion_x',
      'mcp_notion-_x',
      'mcp_a-b_get_weather',
    ]) {
      expect(VALIDATION_LIMITS.MCP_TOOL_NAME_PATTERN.test(name), name).toBe(false);
      expect(validateChatStreamRequest({ ...validBody, tools: [mcpTool(name)] }).ok, name).toBe(false);
      // tool_calls in earlier messages follow the same rule
      expect(validateChatStreamRequest({
        ...validBody,
        tools: [mcpTool('mcp_notion_x')],
        messages: [{ role: 'assistant', content: '', tool_calls: [{
          id: 'call-1', type: 'function', function: { name, arguments: '{}' },
        }] }],
      }).ok, name).toBe(false);
    }
    // A 17-character slug segment is rejected as well (the limit is 16)
    expect(validateChatStreamRequest({ ...validBody, tools: [mcpTool(`mcp_${'a'.repeat(17)}_x`)] }).ok).toBe(false);
    expect(validateChatStreamRequest({ ...validBody, tools: [mcpTool(`mcp_${'a'.repeat(16)}_x`)] }).ok).toBe(true);
    // A - in the last segment is valid (a sanitized tool name allows [A-Za-z0-9_-])
    expect(validateChatStreamRequest({ ...validBody, tools: [mcpTool('mcp_notion_get-weather')] }).ok).toBe(true);
  });

  it('accepts tools: [] with the same meaning as no tools, but empty tools cannot carry toolChoice', () => {
    const empty = validateChatStreamRequest({ ...validBody, tools: [] });
    expect(empty.ok).toBe(true);
    if (empty.ok) expect(empty.value.tools).toEqual([]);

    for (const toolChoice of ['auto', 'none', 'required']) {
      const result = validateChatStreamRequest({ ...validBody, tools: [], toolChoice });
      expect(result.ok, toolChoice).toBe(false);
      if (!result.ok) expect(result.error).toBe('toolChoice requires tools');
    }
    // With tools present, toolChoice works as usual
    expect(validateChatStreamRequest({ ...validBody, tools: [mcpTool('mcp_notion_x')], toolChoice: 'required' }).ok).toBe(true);
  });

  it('accepts valid MCP tools alongside the library tools, and MCP tools on their own', () => {
    const withLibrary = validateChatStreamRequest({
      ...validBody,
      tools: [...libraryTools, mcpTool('mcp_linear_get_weather'), mcpTool('mcp_notion_search_pages_and_databases_with_a_very_long_in_67419a')],
      toolChoice: 'auto',
      messages: [
        { role: 'user', content: 'research' },
        { role: 'assistant', content: '', tool_calls: [
          { id: 'call-1', type: 'function', function: { name: 'library_search', arguments: '{"query":"roadmap"}' } },
          { id: 'call-2', type: 'function', function: { name: 'mcp_linear_get_weather', arguments: '{"city":"ソウル"}' } },
        ] },
        { role: 'tool', tool_call_id: 'call-1', content: '{"ok":true,"result":{"hits":[]}}' },
        { role: 'tool', tool_call_id: 'call-2', content: '{"ok":true}' },
      ],
    });
    expect(withLibrary.ok).toBe(true);

    const mcpOnly = validateChatStreamRequest({
      ...validBody,
      tools: [mcpTool('mcp_linear______'), mcpTool('mcp_jira_create_issue_814c00')],
    });
    expect(mcpOnly.ok).toBe(true);
  });

  it('rejects invalid MCP tool names', () => {
    for (const name of [
      'fetch_url',                    // no mcp_ prefix
      'mcp_Linear_get_weather',       // uppercase in the slug segment
      'mcp_linear-get_weather',       // invalid character in the slug segment
      'mcp_linear_',                  // empty last segment
      'mcp_linear_get weather',       // space in the last segment
      'mcp_linear_get.weather',       // dot in the last segment
      'mcpverylongslug_over64',       // no separator structure
      'mcp_' + 'a'.repeat(16) + '_' + 'b'.repeat(64), // total length > 64
      'mcp__tool',                    // empty slug segment
    ]) {
      expect(validateChatStreamRequest({ ...validBody, tools: [mcpTool(name)] }).ok, name).toBe(false);
    }
  });

  it('hard limit on the number of MCP tools: exactly 40 pass, 41 are rejected; the 3 library tools are counted separately', () => {
    expect(VALIDATION_LIMITS.HARD_MAX_MCP_TOOLS_COUNT).toBe(40);
    expect(VALIDATION_LIMITS.MAX_TOOLS_COUNT).toBe(43);
    const tooMany = Array.from({ length: VALIDATION_LIMITS.HARD_MAX_MCP_TOOLS_COUNT + 1 }, (_, index) =>
      mcpTool(`mcp_s${index}_tool`),
    );
    const atLimit = tooMany.slice(0, -1);
    expect(atLimit).toHaveLength(40);
    expect(validateChatStreamRequest({ ...validBody, tools: atLimit }).ok).toBe(true);
    expect(validateChatStreamRequest({ ...validBody, tools: tooMany }).ok).toBe(false);

    // 3 + 40 = 43 passes; 3 + 41 is rejected
    expect(validateChatStreamRequest({ ...validBody, tools: [...libraryTools, ...atLimit] }).ok).toBe(true);
    expect(validateChatStreamRequest({ ...validBody, tools: [...libraryTools, ...tooMany] }).ok).toBe(false);
  });

  it('hard limit on a single MCP tool definition: description + parameters of exactly 16384 bytes pass, one more byte is rejected', () => {
    const LIMIT = VALIDATION_LIMITS.HARD_MAX_MCP_TOOL_DEFINITION_BYTES;
    expect(LIMIT).toBe(16 * 1024);
    const parameters = { type: 'object', properties: { input: { type: 'string' } }, required: ['input'] };
    const parametersBytes = Buffer.byteLength(JSON.stringify(parameters), 'utf8');

    const exact = mcpTool('mcp_linear_big', { description: 'd'.repeat(LIMIT - parametersBytes), parameters });
    expect(
      Buffer.byteLength(exact.function.description, 'utf8') + parametersBytes,
    ).toBe(LIMIT);
    expect(validateChatStreamRequest({ ...validBody, tools: [exact] }).ok).toBe(true);

    const oneOver = mcpTool('mcp_linear_big', { description: 'd'.repeat(LIMIT - parametersBytes + 1), parameters });
    expect(validateChatStreamRequest({ ...validBody, tools: [oneOver] }).ok).toBe(false);

    // Counted in UTF-8 bytes, not characters: each kana here is 3 bytes
    const cjkChars = Math.floor((LIMIT - parametersBytes) / 3);
    const cjkPadding = (LIMIT - parametersBytes) - cjkChars * 3;
    const cjkExact = mcpTool('mcp_linear_big', { description: 'あ'.repeat(cjkChars) + 'd'.repeat(cjkPadding), parameters });
    expect(validateChatStreamRequest({ ...validBody, tools: [cjkExact] }).ok).toBe(true);
    const cjkOver = mcpTool('mcp_linear_big', { description: 'あ'.repeat(cjkChars) + 'd'.repeat(cjkPadding + 1), parameters });
    expect(validateChatStreamRequest({ ...validBody, tools: [cjkOver] }).ok).toBe(false);

    // Parameters exceeding the limit on their own are rejected too (with a short description)
    const bigSchema = {
      type: 'object',
      properties: { input: { type: 'string', description: 'x'.repeat(LIMIT) } },
    };
    expect(validateChatStreamRequest({ ...validBody, tools: [mcpTool('mcp_linear_big', { description: 'd', parameters: bigSchema })] }).ok).toBe(false);
  });

  it('rejects an MCP tool whose parameters are not an object', () => {
    for (const parameters of ['a string', 42, [], null] as unknown[]) {
      expect(validateChatStreamRequest({
        ...validBody,
        tools: [{ type: 'function', function: { name: 'mcp_linear_x', description: 'd', parameters } }],
      }).ok).toBe(false);
    }
  });

  it('rejects tools impersonating a library tool name', () => {
    // A lone tool called library_search is neither "exactly those 3" nor a valid MCP name
    expect(validateChatStreamRequest({ ...validBody, tools: [mcpTool('library_search')] }).ok).toBe(false);
    // The 3 real library tools plus a fake with the same name (both a duplicate and an impersonation)
    expect(validateChatStreamRequest({ ...validBody, tools: [...libraryTools, mcpTool('library_read')] }).ok).toBe(false);
    // A real library tool whose parameters carry an extra field
    expect(validateChatStreamRequest({
      ...validBody,
      tools: libraryTools.map((tool, index) => index === 0
        ? { ...tool, function: { ...tool.function, parameters: { ...tool.function.parameters, properties: { ...tool.function.parameters.properties, arbitraryUrl: { type: 'string' } } } } }
        : tool),
    }).ok).toBe(false);
    // A tool_call in earlier messages impersonating a library tool name is rejected as well
    expect(validateChatStreamRequest({
      ...validBody,
      tools: libraryTools,
      messages: [{ role: 'assistant', content: '', tool_calls: [{
        id: 'call-1', type: 'function', function: { name: 'library_fetch', arguments: '{}' },
      }] }],
    }).ok).toBe(false);
  });
});

function mcpTool(
  name: string,
  overrides: { description?: string; parameters?: Record<string, unknown> } = {},
) {
  return {
    type: 'function',
    function: {
      name,
      description: overrides.description ?? 'A remote MCP tool',
      parameters: overrides.parameters ?? {
        type: 'object',
        properties: { input: { type: 'string' } },
        required: ['input'],
      },
    },
  };
}

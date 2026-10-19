import { describe, expect, it } from 'vitest';
import { PROPOSE_MEMORY_TOOL } from '../../../context/memory-propose';
import { SEARCH_MEMORY_TOOL } from '../../../context/memory-search';
import { buildAnthropicRequest } from '../anthropic';
import { buildProviderRequest } from '../dispatch';
import { applyToolCallWireAdapter } from '../tool-call-wire-adapter';
import type { ProviderRequest, RequestParams } from '../types';
import type { ProxyMessage, ProxyToolDefinition, RuntimeMetadataResponse } from '../runtime';

const tool: ProxyToolDefinition = {
  type: 'function',
  function: {
    name: 'library_search',
    description: 'Search the library',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: { query: { type: 'string' }, cursor: { type: ['string', 'null'] } },
      required: ['query'],
    },
  },
};
const call = {
  id: 'call_search',
  type: 'function' as const,
  function: { name: 'library_search', arguments: '{"query":"plan"}' },
};
const result = '{"ok":true,"hits":[]}';

describe('tool-call wire adapter', () => {
  it('maps Responses tools and continues via previous_response_id without replaying opaque output', () => {
    const messages: ProxyMessage[] = [
      { role: 'system', content: 'Research carefully.' },
      { role: 'user', content: 'What is the plan?' },
      {
        role: 'assistant', content: '', tool_calls: [call],
        providerContinuation: {
          kind: 'previous_id', step: 1, state: { previousResponseId: 'resp_opaque' },
        },
      },
      { role: 'tool', content: result, tool_call_id: call.id },
    ];
    // Recipe resend mode: previous_response_id and instructions are sent together.
    const body = adapt('https://api.openai.com/v1/responses', messages, {
      tools: [{ type: 'web_search' }],
    }, 'resend');

    expect(body).toMatchObject({
      previous_response_id: 'resp_opaque',
      instructions: 'Research carefully.',
      tool_choice: 'auto',
      input: [{ type: 'function_call_output', call_id: call.id, output: result }],
      tools: [
        { type: 'web_search' },
        { type: 'function', name: 'library_search', description: 'Search the library' },
      ],
    });
  });

  it('maps Anthropic definitions, signed blocks and tool_result', () => {
    const signedBlocks = [
      { type: 'thinking', thinking: 'search first', signature: 'opaque-signature' },
      { type: 'tool_use', id: call.id, name: call.function.name, input: { query: 'plan' } },
    ];
    const messages: ProxyMessage[] = [
      { role: 'system', content: 'Research carefully.' },
      { role: 'user', content: 'What is the plan?' },
      {
        role: 'assistant', content: '', tool_calls: [call],
        providerContinuation: {
          kind: 'replay_blocks', step: 1, state: { blocks: signedBlocks },
        },
      },
      { role: 'tool', content: result, tool_call_id: call.id },
    ];
    const body = adapt('https://api.anthropic.com/v1/messages', messages, {
      tools: [{ type: 'web_search_20260318', name: 'web_search' }],
    });

    expect(body).toMatchObject({
      system: 'Research carefully.',
      tool_choice: { type: 'auto' },
      tools: [
        { type: 'web_search_20260318', name: 'web_search' },
        { name: 'library_search', description: 'Search the library', input_schema: tool.function.parameters },
      ],
      messages: [
        { role: 'user', content: [{ type: 'text', text: 'What is the plan?' }] },
        { role: 'assistant', content: signedBlocks },
        { role: 'user', content: [{ type: 'tool_result', tool_use_id: call.id, content: result }] },
      ],
    });
  });

  it('maps Gemini declarations, preserves thoughtSignature and returns functionResponse', () => {
    const modelContent = {
      role: 'model',
      parts: [{ functionCall: { name: 'library_search', args: { query: 'plan' } }, thoughtSignature: 'opaque-signature' }],
    };
    const messages: ProxyMessage[] = [
      { role: 'system', content: 'Research carefully.' },
      { role: 'user', content: 'What is the plan?' },
      {
        role: 'assistant', content: '', tool_calls: [call],
        providerContinuation: {
          kind: 'replay_blocks', step: 1, state: { blocks: [modelContent] },
        },
      },
      { role: 'tool', content: result, tool_call_id: call.id },
    ];
    const body = adapt(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini:streamGenerateContent?alt=sse',
      messages,
      { tools: [{ google_search: {} }] },
    );

    expect(body).toMatchObject({
      systemInstruction: { parts: [{ text: 'Research carefully.' }] },
      toolConfig: { functionCallingConfig: { mode: 'AUTO' } },
      tools: [
        { google_search: {} },
        { functionDeclarations: [{
          name: 'library_search',
          parameters: {
            type: 'object',
            properties: { cursor: { type: 'string', nullable: true } },
          },
        }] },
      ],
      contents: [
        { role: 'user', parts: [{ text: 'What is the plan?' }] },
        modelContent,
        { role: 'user', parts: [{ functionResponse: {
          name: 'library_search', response: { ok: true, hits: [] },
        } }] },
      ],
    });
  });

  it('keeps OpenAI-compatible parallel calls and their tool result ids unchanged', () => {
    const messages: ProxyMessage[] = [
      { role: 'user', content: 'Research.' },
      { role: 'assistant', content: '', tool_calls: [call] },
      { role: 'tool', content: result, tool_call_id: call.id },
    ];
    expect(adapt('https://api.groq.com/openai/v1/chat/completions', messages)).toMatchObject({
      tool_choice: 'auto',
      tools: [tool],
      messages: [
        { role: 'user', content: 'Research.' },
        { role: 'assistant', content: '', tool_calls: [call] },
        { role: 'tool', content: result, tool_call_id: call.id },
      ],
    });
  });

  it.each([
    {
      name: 'Kimi reasoning_content',
      assistant: { role: 'assistant', content: '', reasoning_content: 'search first', tool_calls: [call] },
    },
    {
      name: 'OpenRouter reasoning_details',
      assistant: {
        role: 'assistant', content: '',
        reasoning_details: [{ type: 'reasoning.text', text: 'search first', index: 0 }],
        tool_calls: [call],
      },
    },
    {
      name: 'MiniMax nullable reasoning_details',
      assistant: {
        role: 'assistant', content: null,
        reasoning_details: [{ type: 'reasoning.text', text: 'search first', index: 0 }],
        tool_calls: [call],
      },
    },
    {
      name: 'Mistral reasoning blocks',
      assistant: {
        role: 'assistant',
        content: [{ type: 'thinking', thinking: [{ type: 'text', text: 'search first' }], closed: true }],
        tool_calls: [call],
      },
    },
  ])('replays the exact $name assistant envelope before the tool result', ({ assistant }) => {
    const messages: ProxyMessage[] = [
      { role: 'user', content: 'Research.' },
      {
        role: 'assistant', content: '', tool_calls: [call],
        providerContinuation: {
          kind: 'replay_reasoning', step: 1, state: { assistantMessages: [assistant] },
        },
      },
      { role: 'tool', content: result, tool_call_id: call.id },
    ];

    expect(adapt('https://api.moonshot.ai/v1/chat/completions', messages).messages).toEqual([
      { role: 'user', content: 'Research.' },
      assistant,
      { role: 'tool', content: result, tool_call_id: call.id },
    ]);
  });

  const imageMessages = (): ProxyMessage[] => [
    { role: 'system', content: 'Research carefully.' },
    { role: 'user', content: [
      { type: 'text', text: 'What is in this picture?' },
      { type: 'image_url', image_url: { url: 'data:image/png;base64,iVBORw0KGgo=' } },
    ] },
    { role: 'assistant', content: '', tool_calls: [call] },
    { role: 'tool', content: result, tool_call_id: call.id },
  ];

  it('tool_leg_keeps_user_images_anthropic', () => {
    const body = adapt('https://api.anthropic.com/v1/messages', imageMessages());
    expect((body.messages as unknown[])[0]).toEqual({ role: 'user', content: [
      { type: 'text', text: 'What is in this picture?' },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'iVBORw0KGgo=' } },
    ] });
  });

  it('tool_leg_keeps_user_images_responses', () => {
    const body = adapt('https://api.openai.com/v1/responses', imageMessages());
    expect((body.input as unknown[])[0]).toEqual({ role: 'user', content: [
      { type: 'input_text', text: 'What is in this picture?' },
      { type: 'input_image', image_url: 'data:image/png;base64,iVBORw0KGgo=' },
    ] });
  });

  it('tool_leg_keeps_user_images_gemini', () => {
    const body = adapt('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent', imageMessages());
    expect((body.contents as unknown[])[0]).toEqual({ role: 'user', parts: [
      { text: 'What is in this picture?' },
      { inlineData: { mimeType: 'image/png', data: 'iVBORw0KGgo=' } },
    ] });
  });

  it('fails closed when opaque reasoning belongs to a different tool proposal', () => {
    const mismatched = {
      role: 'assistant', content: '', reasoning_content: 'stale',
      tool_calls: [{ ...call, id: 'call_stale' }],
    };
    const messages: ProxyMessage[] = [
      { role: 'assistant', content: '', tool_calls: [call], providerContinuation: {
        kind: 'replay_reasoning', step: 1, state: { assistantMessages: [mismatched] },
      } },
    ];

    expect(adapt('https://api.moonshot.ai/v1/chat/completions', messages).messages).toEqual([
      { role: 'assistant', content: '', tool_calls: [call] },
    ]);
  });
});

describe('tool leg text parts', () => {
  // transportInput appends [D] to an array-content user as its own text part prefixed with "\n\n".
  const dynamic = '<oriveo-recall>Prefers tea</oriveo-recall>';
  const legMessages = (): ProxyMessage[] => [
    { role: 'system', content: 'Research carefully.' },
    { role: 'user', content: [
      { type: 'text', text: 'What is the plan?' },
      { type: 'text', text: `\n\n${dynamic}` },
    ] },
    { role: 'assistant', content: [
      { type: 'text', text: 'Searching.' },
      { type: 'text', text: '\n\nOne moment.' },
    ] } as ProxyMessage,
  ];

  it('tool_leg_text_parts_have_no_extra_newline', () => {
    const anthropic = adapt('https://api.anthropic.com/v1/messages', legMessages()) as { messages: Array<{ content: unknown }> };
    expect(anthropic.messages[0].content).toEqual([
      { type: 'text', text: 'What is the plan?' },
      { type: 'text', text: dynamic },
    ]);
    const responses = adapt('https://api.openai.com/v1/responses', legMessages()) as { input: Array<{ content?: unknown }> };
    expect(responses.input[0].content).toEqual([
      { type: 'input_text', text: 'What is the plan?' },
      { type: 'input_text', text: dynamic },
    ]);
    // textContent: a part already carrying the separator is not joined with a third line break.
    expect(responses.input[1].content).toEqual([{ type: 'output_text', text: 'Searching.\n\nOne moment.' }]);
    const gemini = adapt(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent', legMessages(),
    ) as { contents: Array<{ parts: unknown }> };
    expect(gemini.contents[0].parts).toEqual([{ text: 'What is the plan?' }, { text: dynamic }]);
  });
});

describe('memory_tools_after_server_tools', () => {
  // Existing tools (library / MCP) come first, server-side web tools next, host memory tools last, with propose before search.
  const propose = PROPOSE_MEMORY_TOOL as unknown as ProxyToolDefinition;
  const search = SEARCH_MEMORY_TOOL as unknown as ProxyToolDefinition;
  const webTool = { type: 'web_search_20250305', name: 'web_search', max_uses: 5 };
  const toolNames = (body: Record<string, unknown>): string[] =>
    (body.tools as Array<{ name: string }>).map((entry) => entry.name);

  it('memory_tools_after_server_tools (Anthropic builder)', () => {
    const request = buildAnthropicRequest({
      providerKind: 'anthropic',
      apiKey: 'fixture-api-key',
      modelID: 'claude-fixture',
      messages: [{ role: 'user', content: 'hello' }],
      tools: [tool, propose, search],
      options: { supportsWebSearch: true },
    }, null, { mergeParams: { tools: [webTool] } });
    expect(toolNames(request.body)).toEqual(['library_search', 'web_search', 'propose_memory', 'search_memory']);
  });

  it('memory_tools_after_server_tools (v2 recipe)', async () => {
    const metadata: RuntimeMetadataResponse = {
      version: 2,
      updatedAt: '2026-10-19T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      capabilityRuntime: {
        schemaVersion: 2,
        revision: 'fixture-revision',
        generatedAt: '2026-10-19T00:00:00Z',
        recipes: {
          'anthropic.messages.web.v1': {
            id: 'anthropic.messages.web.v1',
            providerKind: 'anthropic',
            transport: { protocol: 'anthropic_messages' },
            capability: 'web',
            executionKind: 'server_tool',
            requestOps: [{ op: 'append', pointer: '/tools/-', value: webTool }],
          },
        },
        controlDefinitions: {},
        sourceIndex: {},
      },
      providers: {
        anthropic: {
          resolveMap: { 'fixture-model': 'fixture-model' },
          models: {
            'fixture-model': {
              transport: 'anthropic_messages',
              capabilityControls: { web: { state: 'auto_available', recipeRef: 'anthropic.messages.web.v1' } },
            },
          },
        },
      },
    };
    const request = await buildProviderRequest({
      providerKind: 'anthropic',
      apiKey: 'fixture-api-key',
      modelID: 'fixture-model',
      messages: [{ role: 'user', content: 'hello' }],
      tools: [tool, propose, search],
      toolChoice: 'auto',
      options: { supportsWebSearch: true },
    }, async () => metadata);
    expect(request.capabilityExecution?.recipeRefs).toEqual(['anthropic.messages.web.v1']);
    expect(toolNames(request.body)).toEqual(['library_search', 'web_search', 'propose_memory', 'search_memory']);
  });

  // Gemini function declarations form one group: only a group made entirely of memory tools moves after the server tools; a group mixed with library / MCP tools stays put.
  const geminiMetadata = (): RuntimeMetadataResponse => ({
    version: 2,
    updatedAt: '2026-10-19T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    capabilityRuntime: {
      schemaVersion: 2,
      revision: 'fixture-revision',
      generatedAt: '2026-10-19T00:00:00Z',
      recipes: {
        'gemini.generate.web.v1': {
          id: 'gemini.generate.web.v1',
          providerKind: 'gemini',
          transport: { protocol: 'gemini_generate_content' },
          capability: 'web',
          executionKind: 'server_tool',
          requestOps: [{ op: 'append', pointer: '/tools/-', value: { google_search: {} } }],
        },
      },
      controlDefinitions: {},
      sourceIndex: {},
    },
    providers: {
      gemini: {
        resolveMap: { 'gemini-fixture': 'gemini-fixture' },
        models: {
          'gemini-fixture': {
            transport: 'gemini_generate_content',
            capabilityControls: { web: { state: 'auto_available', recipeRef: 'gemini.generate.web.v1' } },
          },
        },
      },
    },
  });
  const geminiRequest = (tools: ProxyToolDefinition[]) => buildProviderRequest({
    providerKind: 'gemini',
    apiKey: 'fixture-api-key',
    modelID: 'gemini-fixture',
    messages: [{ role: 'user', content: 'hello' }],
    tools,
    toolChoice: 'auto',
    options: { supportsWebSearch: true },
  }, async () => geminiMetadata());

  it('gemini_memory_tool_group_after_server_tools', async () => {
    const request = await geminiRequest([propose, search]);
    expect(request.capabilityExecution?.recipeRefs).toEqual(['gemini.generate.web.v1']);
    const tools = request.body.tools as Array<Record<string, unknown>>;
    expect(tools[0]).toEqual({ google_search: {} });
    expect((tools[1].functionDeclarations as Array<{ name: string }>).map((entry) => entry.name))
      .toEqual(['propose_memory', 'search_memory']);
    expect(tools).toHaveLength(2);
  });

  it('gemini_mixed_function_group_keeps_place', async () => {
    const request = await geminiRequest([tool, propose, search]);
    const tools = request.body.tools as Array<Record<string, unknown>>;
    expect((tools[0].functionDeclarations as Array<{ name: string }>).map((entry) => entry.name))
      .toEqual(['library_search', 'propose_memory', 'search_memory']);
    expect(tools[1]).toEqual({ google_search: {} });
  });
});

function adapt(
  url: string,
  messages: ProxyMessage[],
  body: Record<string, unknown> = {},
  instructionsMode?: 'resend' | 'omit',
): Record<string, unknown> {
  const request: ProviderRequest = {
    url, headers: {}, body,
    ...(instructionsMode ? { continuationCapture: {
      kind: 'previous_id', protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1', instructionsMode,
    } } : {}),
  };
  const params: Pick<RequestParams, 'messages' | 'tools' | 'toolChoice'> = {
    messages,
    tools: [tool],
    toolChoice: 'auto',
  };
  return applyToolCallWireAdapter(request, params).body;
}

import { describe, expect, it } from 'vitest';
import { applyToolCallWireAdapter } from '../tool-call-wire-adapter';
import type { ProviderRequest, RequestParams } from '../types';
import type { ProxyMessage, ProxyToolDefinition } from '../runtime';

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
    const body = adapt('https://api.openai.com/v1/responses', messages, {
      tools: [{ type: 'web_search' }],
    });

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

function adapt(
  url: string,
  messages: ProxyMessage[],
  body: Record<string, unknown> = {},
): Record<string, unknown> {
  const request: ProviderRequest = { url, headers: {}, body };
  const params: Pick<RequestParams, 'messages' | 'tools' | 'toolChoice'> = {
    messages,
    tools: [tool],
    toolChoice: 'auto',
  };
  return applyToolCallWireAdapter(request, params).body;
}

import { describe, expect, it } from 'vitest';
import { buildAnthropicRequest } from '../request-builders/anthropic';
import { buildRelayAnthropicMessagesBody } from '../relay-orchestrator';
import { anthropicMessagesStrategy } from '../transport/strategies/anthropic-messages';
import type { ContentPart } from '../types';
import { applyToolCallWireAdapter } from '../request-builders/tool-call-wire-adapter';
import { ContextContractFixture } from '../../context/__tests__/fixture';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS } from '../protocol-implementations';
import { buildProviderRequest } from '../request-builders/dispatch';
import type { RuntimeMetadataResponse } from '../request-builders/runtime';
import { projectWire } from '../../context/wire-adapter';

/** Catalog verdict of the official model: only anthropic.explicit gets a breakpoint. */
const EXPLICIT = 'anthropic.explicit';

// Anthropic allows at most 4 cache_control breakpoints per request: even with 5 images there must be at most 1.

const FIVE_IMAGES: ContentPart[] = [
  { type: 'text', text: 'Compare these.' },
  ...Array.from({ length: 5 }, (_, i): ContentPart => ({
    type: 'image_url',
    image_url: { url: `data:image/png;base64,SU1H${i}` },
  })),
];

const MESSAGES = [
  { role: 'system' as const, content: 'Be precise.' },
  { role: 'user' as const, content: 'Earlier question' },
  { role: 'assistant' as const, content: 'Earlier answer' },
  { role: 'user' as const, content: FIVE_IMAGES },
];

function cacheControlCount(body: unknown): number {
  return (JSON.stringify(body).match(/"cache_control"/g) ?? []).length;
}

type Block = Record<string, unknown>;
function lastUserBlocks(body: Record<string, unknown>): Block[] {
  const messages = body.messages as Array<{ role: string; content: Block[] }>;
  return messages.filter((m) => m.role === 'user').at(-1)!.content;
}

describe('Anthropic cache breakpoints stay within the limit', () => {
  it('official: one block-level breakpoint on the last block of the last user message, none top-level', () => {
    const request = buildAnthropicRequest(
      { providerKind: 'anthropic', apiKey: 'key', modelID: 'claude', messages: MESSAGES },
      null,
      null,
      undefined,
      EXPLICIT,
    );
    expect(cacheControlCount(request.body)).toBe(1);
    expect(request.body.cache_control).toBeUndefined();
    expect(lastUserBlocks(request.body).at(-1)).toMatchObject({ type: 'image', cache_control: { type: 'ephemeral' } });
  });

  it('relay orchestrator: one block-level breakpoint on the last block of the last user message', () => {
    const body = buildRelayAnthropicMessagesBody('claude', MESSAGES, undefined);
    expect(cacheControlCount(body)).toBe(1);
    const blocks = lastUserBlocks(body);
    expect(blocks.filter((b) => b.type === 'image')).toHaveLength(5);
    expect(blocks.at(-1)).toMatchObject({ type: 'image', cache_control: { type: 'ephemeral' } });
  });

  it('relay transport strategy: one block-level breakpoint on the last block of the last user message', () => {
    const body = anthropicMessagesStrategy.buildRequestBody({ modelID: 'claude', messages: MESSAGES });
    expect(cacheControlCount(body)).toBe(1);
    expect(lastUserBlocks(body).at(-1)).toMatchObject({ type: 'image', cache_control: { type: 'ephemeral' } });
  });

  it('relay: a plain-text last user message is wrapped so it can carry the single breakpoint', () => {
    const body = anthropicMessagesStrategy.buildRequestBody({
      modelID: 'claude',
      messages: [{ role: 'user', content: 'Hello' }],
    });
    expect(body.messages).toEqual([
      { role: 'user', content: [{ type: 'text', text: 'Hello', cache_control: { type: 'ephemeral' } }] },
    ]);
  });
});

// [D] is split into the last standalone text block, and the single breakpoint goes on the block before it (wire-system.v1 system_history_and_dynamic_block).
interface WireCase {
  id: string;
  plan: { system: string | null; messages: Array<{ role: 'user' | 'assistant'; blocks: Array<{ kind: string; text: string }> }> };
  expected: { anthropic: { system: string; messages: Array<{ role: string; content: Block[] }> } };
}

const wireCase = ContextContractFixture.load<{ cases: WireCase[] }>('wire-system.v1.json')
  .cases.find((c) => c.id === 'system_history_and_dynamic_block')!;
const dynamicText = wireCase.plan.messages.flatMap((m) => m.blocks).find((b) => b.kind === 'dynamic')!.text;
const expectedAnthropic = wireCase.expected.anthropic;
const expectedLastUser = expectedAnthropic.messages.filter((m) => m.role === 'user').at(-1)!.content;

/** Outbound shape of transportInput: [D] is appended with "\n\n" to the end of the last user string (a standalone part when the content is an array). */
function planMessages(arrayContent = false) {
  const out: Array<{ role: 'system' | 'user' | 'assistant'; content: string | ContentPart[] }> = [];
  if (wireCase.plan.system) out.push({ role: 'system', content: wireCase.plan.system });
  for (const m of wireCase.plan.messages) {
    const text = m.blocks.filter((b) => b.kind !== 'dynamic').map((b) => b.text).join('\n\n');
    const hasDynamic = m.blocks.some((b) => b.kind === 'dynamic');
    if (hasDynamic && arrayContent) {
      out.push({ role: m.role, content: [{ type: 'text', text }, { type: 'text', text: `\n\n${dynamicText}` }] });
    } else {
      out.push({ role: m.role, content: hasDynamic ? `${text}\n\n${dynamicText}` : text });
    }
  }
  return out;
}

describe('Anthropic [D] block and single breakpoint', () => {
  it('anthropic_official_dynamic_block_last_breakpoint_before_it', () => {
    const request = buildAnthropicRequest(
      { providerKind: 'anthropic', apiKey: 'key', modelID: 'claude', messages: planMessages(), options: { dynamicText } },
      null,
      null,
      undefined,
      EXPLICIT,
    );
    expect(request.body.system).toBe(expectedAnthropic.system);
    expect(lastUserBlocks(request.body)).toEqual(expectedLastUser);
    expect(cacheControlCount(request.body)).toBe(1);
  });

  it('anthropic_relay_dynamic_block_last_breakpoint_before_it', () => {
    for (const arrayContent of [false, true]) {
      const bodies = [
        buildRelayAnthropicMessagesBody('claude', planMessages(arrayContent), { dynamicText }),
        anthropicMessagesStrategy.buildRequestBody({ modelID: 'claude', messages: planMessages(arrayContent), options: { dynamicText } }),
      ];
      for (const body of bodies) {
        expect(body.system).toBe(expectedAnthropic.system);
        expect(lastUserBlocks(body)).toEqual(expectedLastUser);
        expect(cacheControlCount(body)).toBe(1);
      }
    }
  });

  it('anthropic_without_dynamic_breakpoint_on_last_block', () => {
    const plain = planMessages();
    const official = buildAnthropicRequest(
      { providerKind: 'anthropic', apiKey: 'key', modelID: 'claude', messages: plain },
      null,
      null,
      undefined,
      EXPLICIT,
    ).body;
    const relay = buildRelayAnthropicMessagesBody('claude', plain, undefined);
    // Without dynamicText [D] is not recognised: the whole text is sent as is, and the breakpoint goes on the last block.
    const mismatched = buildRelayAnthropicMessagesBody('claude', plain, { dynamicText: 'not the suffix' });
    for (const body of [official, relay, mismatched]) {
      expect(lastUserBlocks(body)).toEqual([
        { type: 'text', text: `Write chapter 2.\n\n${dynamicText}`, cache_control: { type: 'ephemeral' } },
      ]);
      expect(cacheControlCount(body)).toBe(1);
      expect(body.cache_control).toBeUndefined();
    }
  });

  it('anthropic_tool_loop_breakpoint_on_last_tool_result_turn', () => {
    const messages = [
      ...planMessages(),
      {
        role: 'assistant' as const,
        content: '',
        tool_calls: [{ id: 'call_1', type: 'function' as const, function: { name: 'weather', arguments: '{"city":"Oslo"}' } }],
      },
      { role: 'tool' as const, content: '4°C, rain', tool_call_id: 'call_1' },
    ];
    const tools = [{ type: 'function' as const, function: { name: 'weather', description: 'w', parameters: { type: 'object' } } }];
    const params = { providerKind: 'anthropic' as const, apiKey: 'key', modelID: 'claude', messages, tools, options: { dynamicText } };
    const adapted = applyToolCallWireAdapter(buildAnthropicRequest(params, null, null, undefined, EXPLICIT), params);
    const body = adapted.body as Record<string, unknown>;
    expect(cacheControlCount(body)).toBe(1);
    expect(body.cache_control).toBeUndefined();
    expect(lastUserBlocks(body)).toEqual([
      { type: 'tool_result', tool_use_id: 'call_1', content: '4°C, rain', cache_control: { type: 'ephemeral' } },
    ]);
    // [D] is the same standalone last block on every leg, so the prefix is identical across legs.
    const userTurns = (body.messages as Array<{ role: string; content: Block[] }>).filter((m) => m.role === 'user');
    expect(userTurns.at(-2)!.content.at(-1)).toEqual({ type: 'text', text: dynamicText });
  });
});

// [D] carrier rules: an empty body is [D] itself, file text comes before [D], and only the current user message is stripped.
describe('Anthropic [D] carrier rules', () => {
  const IMAGE: ContentPart = { type: 'image_url', image_url: { url: 'data:image/png;base64,SU1H' } };
  const imageBlock = { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'SU1H' } };

  function bodiesFor(messages: Array<{ role: 'system' | 'user' | 'assistant'; content: string | ContentPart[] }>) {
    return [
      buildAnthropicRequest(
        { providerKind: 'anthropic', apiKey: 'key', modelID: 'claude', messages, options: { dynamicText } },
        null,
        null,
        undefined,
        EXPLICIT,
      ).body,
      buildRelayAnthropicMessagesBody('claude', messages, { dynamicText }),
      anthropicMessagesStrategy.buildRequestBody({ modelID: 'claude', messages, options: { dynamicText } }),
    ];
  }

  it('anthropic_image_only_dynamic_breakpoint_on_image', () => {
    // Empty body with only an image: the text part appended by transportInput is [D] itself (no leading newline).
    const bodies = bodiesFor([
      { role: 'system', content: 'Be precise.' },
      { role: 'user', content: [IMAGE, { type: 'text', text: dynamicText }] },
    ]);
    for (const body of bodies) {
      expect(lastUserBlocks(body)).toEqual([
        { ...imageBlock, cache_control: { type: 'ephemeral' } },
        { type: 'text', text: dynamicText },
      ]);
      expect(cacheControlCount(body)).toBe(1);
    }
  });

  it('anthropic_file_text_injected_before_dynamic', () => {
    // The extracted file text is already injected into the body and [D] follows it: after stripping [D] the breakpoint lands on the block holding the file text (not hit by this bug; locks the behavior).
    const fileText = '<ATTACHMENT_FILE index="1" name="draft.txt">\ndraft body\n</ATTACHMENT_FILE>';
    const head = `read this\n\n${fileText}`;
    for (const content of [`${head}\n\n${dynamicText}`, [{ type: 'text', text: head }, IMAGE, { type: 'text', text: `\n\n${dynamicText}` }] as ContentPart[]]) {
      for (const body of bodiesFor([{ role: 'user', content }])) {
        const blocks = lastUserBlocks(body);
        expect(blocks.at(-1)).toEqual({ type: 'text', text: dynamicText });
        expect(blocks.find((b) => b.type === 'text')!.text).toBe(head);
        expect(blocks.at(-2)!.cache_control).toEqual({ type: 'ephemeral' });
        expect(cacheControlCount(body)).toBe(1);
      }
    }
  });

  it('anthropic_tool_leg_keeps_dynamic_split_on_current_user', () => {
    const tools = [{ type: 'function' as const, function: { name: 'weather', description: 'w', parameters: { type: 'object' } } }];
    const toolTurns = (id: string) => [
      {
        role: 'assistant' as const,
        content: '',
        tool_calls: [{ id, type: 'function' as const, function: { name: 'weather', arguments: '{"city":"Oslo"}' } }],
      },
      { role: 'tool' as const, content: '4°C, rain', tool_call_id: id },
    ];
    // A history user message also happens to end with "\n\n"+[D]: it is not the current user, so nothing is stripped.
    const prefix = [
      { role: 'user' as const, content: `Earlier question\n\n${dynamicText}` },
      { role: 'assistant' as const, content: 'Earlier answer' },
      { role: 'user' as const, content: [IMAGE, { type: 'text', text: dynamicText }] as ContentPart[] },
    ];
    const legs = [[...prefix, ...toolTurns('call_1')], [...prefix, ...toolTurns('call_1'), ...toolTurns('call_2')]];
    const bodies = legs.map((messages) => {
      const params = { providerKind: 'anthropic' as const, apiKey: 'key', modelID: 'claude', messages, tools, options: { dynamicText } };
      return applyToolCallWireAdapter(buildAnthropicRequest(params, null, null, undefined, EXPLICIT), params).body as Record<string, unknown>;
    });
    for (const body of bodies) {
      const messages = body.messages as Array<{ role: string; content: Block[] }>;
      expect(messages[0]!.content).toEqual([{ type: 'text', text: `Earlier question\n\n${dynamicText}` }]);
      // The current user (this turn) text == [D]: [D] is its standalone last block and carries no breakpoint.
      expect(messages[2]!.content.at(-1)).toEqual({ type: 'text', text: dynamicText });
      expect(lastUserBlocks(body)).toEqual([
        { type: 'tool_result', tool_use_id: messages.at(-2)!.content[0]!.id, content: '4°C, rain', cache_control: { type: 'ephemeral' } },
      ]);
      expect(cacheControlCount(body)).toBe(1);
    }
    // The prefix stays unchanged across legs (after removing the breakpoint).
    const strip = (body: Record<string, unknown>) =>
      JSON.parse(JSON.stringify(body.messages, (key, v: unknown) => (key === 'cache_control' ? undefined : v))) as unknown[];
    const [leg1, leg2] = bodies.map(strip) as [unknown[], unknown[]];
    expect(leg2.slice(0, leg1.length)).toEqual(leg1);
  });
});

function loadWireFamilies(): { protocols: { anthropic: { defaultMaxOutputTokens: number } } } {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', 'wire_families.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8'));
    const parent = path.dirname(current);
    if (parent === current) throw new Error('wire_families.v1.json not found');
    current = parent;
  }
}

describe('Anthropic prompt cache follows the catalog policyRef', () => {
  const tools = [{ type: 'function' as const, function: { name: 'weather', description: 'w', parameters: { type: 'object' } } }];
  const toolMessages = [
    ...MESSAGES,
    {
      role: 'assistant' as const,
      content: '',
      tool_calls: [{ id: 'call_1', type: 'function' as const, function: { name: 'weather', arguments: '{}' } }],
    },
    { role: 'tool' as const, content: 'sunny', tool_call_id: 'call_1' },
  ];

  for (const policyRef of [undefined, 'anthropic.automatic', 'openai.responses.automatic']) {
    it(`official without anthropic.explicit (${policyRef ?? 'missing'}): no breakpoint on builder or tool leg`, () => {
      const request = buildAnthropicRequest(
        { providerKind: 'anthropic', apiKey: 'key', modelID: 'claude', messages: MESSAGES },
        null,
        null,
        undefined,
        policyRef,
      );
      expect(cacheControlCount(request.body)).toBe(0);
      const params = { providerKind: 'anthropic' as const, apiKey: 'key', modelID: 'claude', messages: toolMessages, tools };
      const leg = applyToolCallWireAdapter(buildAnthropicRequest(params, null, null, undefined, policyRef), params);
      expect(cacheControlCount(leg.body)).toBe(0);
    });
  }

  it('official explicit: tool leg re-marks the single breakpoint', () => {
    const params = { providerKind: 'anthropic' as const, apiKey: 'key', modelID: 'claude', messages: toolMessages, tools };
    const leg = applyToolCallWireAdapter(buildAnthropicRequest(params, null, null, undefined, EXPLICIT), params);
    expect(cacheControlCount(leg.body)).toBe(1);
    expect(lastUserBlocks(leg.body).at(-1)).toMatchObject({ type: 'tool_result', cache_control: { type: 'ephemeral' } });
  });

  it('dispatch reads promptCache.policyRef and maxOutputTokens from the runtime model', async () => {
    const metadata = (policyRef?: string): RuntimeMetadataResponse => ({
      providers: {
        anthropic: {
          resolveMap: { claude: 'claude' },
          models: { claude: { canonicalModelId: 'claude', maxOutputTokens: 64000, ...(policyRef ? { promptCache: { policyRef } } : {}) } },
        },
      },
    } as unknown as RuntimeMetadataResponse);
    const params = { providerKind: 'anthropic' as const, apiKey: 'key', modelID: 'claude', baseURL: 'https://contract.invalid/v1', messages: MESSAGES };
    const explicit = await buildProviderRequest(params, async () => metadata(EXPLICIT));
    expect(cacheControlCount(explicit.body)).toBe(1);
    expect(explicit.body.max_tokens).toBe(64000);
    const missing = await buildProviderRequest(params, async () => metadata());
    expect(cacheControlCount(missing.body)).toBe(0);
    const explicitLimit = await buildProviderRequest({ ...params, options: { maxOutputTokens: 1000 } }, async () => metadata(EXPLICIT));
    expect(explicitLimit.body.max_tokens).toBe(1000);
  });

  it('protocol default max_tokens matches wire_families and is used only without explicit/model values', () => {
    expect(ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS).toBe(loadWireFamilies().protocols.anthropic.defaultMaxOutputTokens);
    const request = buildAnthropicRequest({ providerKind: 'anthropic', apiKey: 'key', modelID: 'claude', messages: MESSAGES }, null, null);
    expect(request.body.max_tokens).toBe(ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS);
    expect(buildAnthropicRequest({ providerKind: 'anthropic', apiKey: 'key', modelID: 'claude', messages: MESSAGES }, null, null, 64000).body.max_tokens).toBe(64000);
  });

  it('relay keeps its breakpoint and protocol default without a catalog verdict', () => {
    const body = buildRelayAnthropicMessagesBody('claude', MESSAGES, undefined);
    expect(cacheControlCount(body)).toBe(1);
    expect(body.max_tokens).toBe(ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS);
    expect(cacheControlCount(anthropicMessagesStrategy.buildRequestBody({ modelID: 'claude', messages: MESSAGES }))).toBe(1);
  });

  it('projectWire anthropic: catalog verdict gates the breakpoint, no verdict keeps it', () => {
    const plan = { system: null, messages: [{ role: 'user' as const, blocks: [{ kind: 'stable', text: 'hi' }] }] } as never;
    expect(cacheControlCount(projectWire(plan, 'anthropic'))).toBe(1);
    expect(cacheControlCount(projectWire(plan, 'anthropic', undefined, { policyRef: EXPLICIT }))).toBe(1);
    expect(cacheControlCount(projectWire(plan, 'anthropic', undefined, {}))).toBe(0);
  });
});

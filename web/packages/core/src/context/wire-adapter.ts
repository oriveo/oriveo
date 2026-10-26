/**
 * WireAdapter: projects a ContextPlan onto each protocol family's request-body subset
 * (contract: shared/context-contracts/wire-system.v1.json). Pure; attachments keep each
 * provider's own part builders and are not handled here.
 */

import type { ContextRole } from './message';
import type { ContextBlock } from './plan';
import { trimWhiteSpace } from './white-space';
import { usesAnthropicExplicitPromptCache } from '../providers/protocol-implementations';

export type WireFamily =
  | 'openai_chat'
  | 'openai_chat_string_only'
  | 'free'
  | 'llamacpp'
  | 'managed'
  | 'openai_responses'
  | 'anthropic'
  | 'gemini';

export const WIRE_FAMILIES: readonly WireFamily[] = [
  'openai_chat',
  'openai_chat_string_only',
  'free',
  'llamacpp',
  'managed',
  'openai_responses',
  'anthropic',
  'gemini',
];

/** The plan fields the wire needs; a sealed ContextPlan satisfies it. */
export interface WirePlan {
  system: string | null;
  messages: ReadonlyArray<{ role: ContextRole; blocks: readonly ContextBlock[] }> | null;
}

export interface WireToolCall {
  id: string;
  name: string;
  /** JSON-encoded arguments as the model produced them. */
  arguments: string;
}

export interface WireToolResult {
  callId: string;
  name: string;
  output: string;
}

/**
 * A host tool-loop leg after the plan's last user message: the assistant's tool calls, their
 * results, and an optional host notice (e.g. step limit reached) placed after the results.
 */
export interface WireToolLeg {
  calls: WireToolCall[];
  results: WireToolResult[];
  notice: string | null;
}

export type WireBody = Record<string, unknown>;

/** The model catalog's prompt-cache verdict; absent means there is no catalog verdict. */
export interface WirePromptCache {
  policyRef?: string;
}

const STRING_ONLY: ReadonlySet<WireFamily> = new Set(['openai_chat_string_only', 'free', 'llamacpp']);
const BLOCK_SEPARATOR = '\n\n';
const EPHEMERAL = { type: 'ephemeral' } as const;

function planMessages(plan: WirePlan): NonNullable<WirePlan['messages']> {
  if (plan.messages === null) throw new Error('projectWire: plan has no messages (rejected or imageGeneration)');
  return plan.messages;
}

function joined(blocks: readonly ContextBlock[]): string {
  return blocks.map((b) => b.text).join(BLOCK_SEPARATOR);
}

/**
 * Decodes tool-call arguments for families that send them as objects (Anthropic input,
 * Gemini args): empty or all-whitespace → {}; invalid JSON or a non-object value throws.
 */
function toolArguments(raw: string): Record<string, unknown> {
  if (trimWhiteSpace(raw) === '') return {};
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error('projectWire: tool call arguments are not valid JSON');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('projectWire: tool call arguments must be a JSON object');
  }
  return value as Record<string, unknown>;
}

/** Chat-shaped families: OpenAI Chat (with or without parts), Free, llama.cpp, managed. */
function projectChat(plan: WirePlan, family: WireFamily, leg: WireToolLeg | undefined): WireBody {
  const stringOnly = STRING_ONLY.has(family);
  const messages: Array<Record<string, unknown>> = [];
  if (plan.system !== null) messages.push({ role: 'system', content: plan.system });
  for (const m of planMessages(plan)) {
    const content =
      stringOnly || m.blocks.length === 1
        ? joined(m.blocks)
        : m.blocks.map((b) => ({ type: 'text', text: b.text }));
    messages.push({ role: m.role, content });
  }
  if (leg) {
    if (family === 'free') throw new Error('projectWire: Free sends no tools');
    messages.push({
      role: 'assistant',
      content: null,
      tool_calls: leg.calls.map((c) => ({ id: c.id, type: 'function', function: { name: c.name, arguments: c.arguments } })),
    });
    for (const r of leg.results) messages.push({ role: 'tool', tool_call_id: r.callId, content: r.output });
    if (leg.notice !== null) messages.push({ role: 'user', content: leg.notice });
  }
  return { messages };
}

function projectResponses(plan: WirePlan, leg: WireToolLeg | undefined): WireBody {
  const input: Array<Record<string, unknown>> = planMessages(plan).map((m) => ({
    role: m.role,
    content: m.blocks.length === 1 ? m.blocks[0]!.text : m.blocks.map((b) => ({ type: m.role === 'assistant' ? 'output_text' : 'input_text', text: b.text })),
  }));
  if (leg) {
    for (const c of leg.calls) input.push({ type: 'function_call', call_id: c.id, name: c.name, arguments: c.arguments });
    for (const r of leg.results) input.push({ type: 'function_call_output', call_id: r.callId, output: r.output });
    if (leg.notice !== null) input.push({ role: 'user', content: leg.notice });
  }
  return plan.system !== null ? { instructions: plan.system, input } : { input };
}

interface AnthropicBlock {
  block: Record<string, unknown>;
  dynamic: boolean;
}

function projectAnthropic(plan: WirePlan, leg: WireToolLeg | undefined, promptCache: WirePromptCache | undefined): WireBody {
  const turns: Array<{ role: ContextRole; blocks: AnthropicBlock[] }> = planMessages(plan).map((m) => ({
    role: m.role,
    blocks: m.blocks.map((b) => ({ block: { type: 'text', text: b.text }, dynamic: b.kind === 'dynamic' })),
  }));
  if (leg) {
    turns.push({
      role: 'assistant',
      blocks: leg.calls.map((c) => ({
        block: { type: 'tool_use', id: c.id, name: c.name, input: toolArguments(c.arguments) },
        dynamic: false,
      })),
    });
    const blocks: AnthropicBlock[] = leg.results.map((r) => ({
      block: { type: 'tool_result', tool_use_id: r.callId, content: r.output },
      dynamic: false,
    }));
    if (leg.notice !== null) blocks.push({ block: { type: 'text', text: leg.notice }, dynamic: false });
    turns.push({ role: 'user', blocks });
  }
  // Exactly one breakpoint: the last non-dynamic block of the last user message.
  // With a catalog verdict only anthropic.explicit marks; without one (no catalog verdict, e.g. Relay / contract fixtures) it marks as before.
  const marks = promptCache === undefined || usesAnthropicExplicitPromptCache(promptCache.policyRef);
  const lastUser = marks ? [...turns].reverse().find((t) => t.role === 'user') : undefined;
  const anchor = lastUser ? [...lastUser.blocks].reverse().find((b) => !b.dynamic) : undefined;
  if (anchor) anchor.block = { ...anchor.block, cache_control: EPHEMERAL };
  const messages = turns.map((t) => ({ role: t.role, content: t.blocks.map((b) => b.block) }));
  return plan.system !== null ? { system: plan.system, messages } : { messages };
}

function projectGemini(plan: WirePlan, leg: WireToolLeg | undefined): WireBody {
  const contents: Array<Record<string, unknown>> = planMessages(plan).map((m) => ({
    role: m.role === 'assistant' ? 'model' : 'user',
    parts: m.blocks.map((b) => ({ text: b.text })),
  }));
  if (leg) {
    contents.push({
      role: 'model',
      parts: leg.calls.map((c) => ({ functionCall: { name: c.name, args: toolArguments(c.arguments) } })),
    });
    const parts: Array<Record<string, unknown>> = leg.results.map((r) => ({
      functionResponse: { name: r.name, response: { content: r.output } },
    }));
    if (leg.notice !== null) parts.push({ text: leg.notice });
    contents.push({ role: 'user', parts });
  }
  return plan.system !== null ? { systemInstruction: { parts: [{ text: plan.system }] }, contents } : { contents };
}

/** Projects the plan (plus an optional host tool-loop leg) onto one family's request-body subset. */
export function projectWire(
  plan: WirePlan,
  family: WireFamily,
  toolLeg?: WireToolLeg,
  promptCache?: WirePromptCache,
): WireBody {
  switch (family) {
    case 'openai_responses':
      return projectResponses(plan, toolLeg);
    case 'anthropic':
      return projectAnthropic(plan, toolLeg, promptCache);
    case 'gemini':
      return projectGemini(plan, toolLeg);
    default:
      return projectChat(plan, family, toolLeg);
  }
}

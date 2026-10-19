/**
 * The only outbound entry of the main chat:
 * a PlannedChatRequest can only be obtained by projecting a ContextPlan (the brand symbol and constructor are not exported);
 * transportInput hands it, together with the wire history carrying attachments, to sendStream.
 * system is written as role=system only in this file: messages = system first + wire history + [D] (appended to the end of the last user message).
 */
import type { ChatMessage } from '@oriveo/shared';
import type { ContentPart, StreamOptions } from '@oriveo/core/providers/types';
import type { ProxyMessage, ProxyToolDefinition } from '@oriveo/core/providers/request-builders/runtime';
import { CONTEXT_ASSEMBLE_CONSTANTS, type ContextPlan } from '@oriveo/core/context/assemble';

export interface TransportMessage {
  role: 'user' | 'assistant' | 'system';
  content: string | ContentPart[];
}

export interface TransportInput {
  readonly messages: TransportMessage[];
  readonly options: StreamOptions | undefined;
}

/** Outbound input of one tool-loop leg: leg messages and tools pass through unchanged, and options carry [D]. */
export interface ToolLegTransportInput {
  readonly messages: ProxyMessage[];
  readonly tools: ProxyToolDefinition[];
  readonly options: StreamOptions | undefined;
}

export interface PlannedChatRequestFields {
  plan: ContextPlan;
  /** plan.system; null when there is none. */
  system: string | null;
  /** plan.messages projected back to app messages (body + attachments the plan kept; [D] is appended to the last wire user message by transportInput). */
  messages: ChatMessage[];
  /** The [D] blocks joined with "\n\n"; an empty string when there is none. */
  dynamicText: string;
}

// Unexported brand symbol and factory: only projectPlanMessages in this module can produce a PlannedChatRequest.
const plannedChatRequestBrand: unique symbol = Symbol('PlannedChatRequest');

export type PlannedChatRequest = Readonly<PlannedChatRequestFields> & { readonly [plannedChatRequestBrand]: true };

function sealPlannedChatRequest(fields: PlannedChatRequestFields): PlannedChatRequest {
  return Object.freeze({ ...fields, [plannedChatRequestBrand]: true as const });
}

/**
 * Maps plan.messages back to app messages: the body comes from the text blocks, attachments are the ones the plan kept (the other fields of the original message are carried back by message id).
 * A user message the assembler appended itself (the continuation sentence of continue) has no original message, so a send-only user message that is not saved is added from the plan content.
 */
export function projectPlanMessages(plan: ContextPlan, messages: ChatMessage[]): PlannedChatRequest {
  const byId = new Map(messages.map((message) => [message.id, message]));
  const projected = (plan.messages ?? []).flatMap((planMessage): ChatMessage[] => {
    const text = planMessage.blocks.filter((block) => block.kind === 'text').map((block) => block.text).join('');
    const original = byId.get(planMessage.id);
    if (!original) {
      if (planMessage.role !== 'user') return [];
      return [{
        id: planMessage.id,
        role: 'user',
        text,
        state: 'delivered',
        createdAt: messages[messages.length - 1]?.createdAt ?? new Date(0).toISOString(),
        attachments: planMessage.attachments,
      } as ChatMessage];
    }
    return [{ ...original, text, attachments: planMessage.attachments }];
  });
  return sealPlannedChatRequest({
    plan,
    system: plan.system,
    messages: projected,
    dynamicText: planDynamicText(plan) ?? '',
  });
}

/** The [D] text on the last plan message; null when there is none. */
export function planDynamicText(plan: ContextPlan): string | null {
  const last = plan.messages?.[plan.messages.length - 1];
  const dynamic = last?.blocks.filter((block) => block.kind === 'dynamic').map((block) => block.text).join('\n\n') ?? '';
  return dynamic.length > 0 ? dynamic : null;
}

type ChatTransportRequest =
  | { options: StreamOptions | undefined; history: TransportMessage[] }
  // Single-purpose plan (no history attachments): history is the body of the plan messages.
  | { options: StreamOptions | undefined; planMessages: true }
  | { options: StreamOptions | undefined; stateful: { sendInstructions: boolean } };

type ToolLegTransportRequest = {
  options: StreamOptions | undefined;
  toolLeg: { messages: ProxyMessage[]; tools: ProxyToolDefinition[] };
};

/**
 * Outbound input of one attempt.
 * - history: planned.messages (or a subset) after attachment injection as wire history; system is prepended and [D] is appended to the last user message.
 * - planMessages: a single-purpose plan has no wire history with attachments, so planned.messages bodies are used directly as the history.
 * - stateful: the upstream already holds the old context, so only the continuation sentence is sent; with sendInstructions system is carried, [D] is not.
 * - toolLeg: one tool-loop leg. The first leg's messages already have system prepended and [D] appended in the history form; later legs only add
 *   assistant / tool messages after it; messages and tools pass through unchanged, and only options.dynamicText shares its source with the [D] in the messages.
 */
export function transportInput(planned: PlannedChatRequest, input: ToolLegTransportRequest): ToolLegTransportInput;
export function transportInput(planned: PlannedChatRequest, input: ChatTransportRequest): TransportInput;
export function transportInput(
  planned: PlannedChatRequest,
  input: ChatTransportRequest | ToolLegTransportRequest,
): TransportInput | ToolLegTransportInput {
  if ('toolLeg' in input) {
    return {
      messages: input.toolLeg.messages,
      tools: input.toolLeg.tools,
      options: planned.dynamicText ? { ...input.options, dynamicText: planned.dynamicText } : input.options,
    };
  }
  if ('stateful' in input) {
    return {
      messages: [
        ...(input.stateful.sendInstructions && planned.system ? [{ role: 'system' as const, content: planned.system }] : []),
        { role: 'user', content: CONTEXT_ASSEMBLE_CONSTANTS.continuePrompt },
      ],
      options: input.options,
    };
  }
  const history: TransportMessage[] = 'planMessages' in input
    ? planned.messages.map((message) => ({ role: message.role as TransportMessage['role'], content: message.text }))
    : input.history;
  // Copy each message: appending [D] does not write back into the caller's wire history.
  const messages = history.map((message) => ({ ...message }));
  if (planned.system) messages.unshift({ role: 'system', content: planned.system });
  if (!planned.dynamicText) return { messages, options: input.options };
  appendTextToLatestUserMessage(messages, planned.dynamicText);
  return { messages, options: { ...input.options, dynamicText: planned.dynamicText } };
}

export function appendTextToLatestUserMessage(
  messages: Array<{ role: string; content: string | ContentPart[] }>,
  text: string,
): void {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message.role !== 'user') continue;
    // When the body is empty (empty string or no text part) it is just [D] itself, with no leading newline.
    if (typeof message.content === 'string') {
      message.content = message.content ? `${message.content}\n\n${text}` : text;
    } else {
      const hasText = message.content.some((part) => part.type === 'text');
      message.content = [...message.content, { type: 'text', text: hasText ? `\n\n${text}` : text }];
    }
    return;
  }
}

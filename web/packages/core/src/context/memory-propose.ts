/**
 * Host tool propose_memory (contract: shared/context-contracts/memory-propose.v3.json; v3 propose-v3).
 * Pure: the tool definition sent to the model, the fixed tool_result, propose → pending candidate, the per-send mode
 * and the degrade rule. A proposal only ever yields a pending candidate through makeMemoryCandidate, or (v3, scope
 * conversation) an instruct sentence for the conversation-instruction bar; nothing here touches storage or writes an active item.
 */

import {
  classifyMemoryIntent,
  makeMemoryCandidate,
  memoryIntentCanonical,
  type MemoryCandidateOutcome,
  type MemoryCandidateRecord,
  type MemoryCandidateSkipReason,
} from './memory-intent';
import { MEMORY_INTENT_CONTENT_MAX_CODE_POINTS } from './memory-intent-lexicon';
import type { MemoryKind } from './memory-items';
import type { RequestPurpose } from './manifest';
import { trimWhiteSpace } from './white-space';

export const PROPOSE_MEMORY_TOOL_NAME = 'propose_memory';

const KINDS: readonly MemoryKind[] = ['instruction','project','goal','preference','identity','fact','decision','event'];
export type ProposeMemoryScope = 'global' | 'folder' | 'unspecified' | 'conversation';
const SCOPES: readonly ProposeMemoryScope[] = ['global','folder','unspecified','conversation'];

/** Canonical (OpenAI function) shape; each protocol family projects it with the shared tool projection. */
export const PROPOSE_MEMORY_TOOL = {
  type: 'function',
  function: {
    name: PROPOSE_MEMORY_TOOL_NAME,
    description:
      "Propose one long-term memory for the user to confirm, or one standing instruction for this conversation. Call it when the user's own message in this turn asks you to remember something for future conversations, or states a lasting fact or preference about themselves, or a decision or event they will want to look up later, that they clearly want kept beyond this conversation. Also call it when the user asks you to keep answering in a certain way for the rest of this conversation (from now on, going forward, always, never, every time...): set scope to conversation and kind to instruction. One atomic statement per call, keeping the user's meaning and language; never record your own inference. Do not call it for: reminders and to-dos; questions, including 'can you remember...'; corrections or statements that something is no longer true; quoted, hypothetical or role-play text; anything containing passwords, keys, codes, payment or ID details, health, sexuality, religion, politics, ethnicity, criminal record or immigration status. Nothing is saved until the user confirms. After calling, continue your reply normally and do not mention the proposal.",
    parameters: {
      type: 'object',
      properties: {
        proposition: {
          type: 'string',
          description: 'The fact, preference or rule to keep, as one self-contained statement in the language the user wrote.',
        },
        kind: {
          type: 'string',
          enum: [...KINDS],
          description:
            'instruction: a standing rule for how to respond; project: about a project the user works on; goal: something the user is working toward; preference: what the user likes or dislikes; identity: who the user is; fact: any other lasting fact about the user; decision: something the user decided and will want to look up later; event: something that happened that the user will want to look up later.',
        },
        scope: {
          type: 'string',
          enum: [...SCOPES],
          description:
            'global: the user said it applies to all chats; folder: the user said it applies to this project or folder; unspecified: the user named no scope; conversation: a way of answering the user wants kept for the rest of this conversation only (use kind instruction).',
        },
        sourceQuote: {
          type: 'string',
          description: "The exact words in the user's message that this comes from, copied verbatim.",
        },
      },
      required: ['proposition', 'kind', 'scope', 'sourceQuote'],
      additionalProperties: false,
    },
  },
} as const;

/** Answer to every propose_memory call, whatever the outcome, so the model never retries or asks. */
export const PROPOSE_MEMORY_TOOL_RESULT =
  'Recorded as a suggestion; the user will decide whether to save it. Continue your reply. Do not ask about it or say it was saved.';

export const PROPOSE_MEMORY_MAX_PER_TURN = 3;

/** Instruct outcomes per turn (v3); later conversation-scope calls skip instruct_limit. */
export const PROPOSE_MEMORY_MAX_INSTRUCT_PER_TURN = 1;

export type ProposeMemorySkipReason =
  | Exclude<MemoryCandidateSkipReason, 'no_suggestion' | 'auto_suggest_off'>
  | 'invalid_arguments'
  | 'too_long'
  | 'quote_not_in_message'
  | 'secret'
  | 'special'
  | 'conversation_instruction'
  | 'conversation_not_instruction'
  | 'instruct_limit'
  | 'turn_limit';

export type ProposeMemoryOutcome =
  | { action: 'create'; reason: null; candidate: MemoryCandidateRecord }
  | { action: 'skip'; reason: ProposeMemorySkipReason; candidate: null }
  /** scope conversation (v3): the sentence goes to the conversation-instruction bar, never to memory. */
  | { action: 'instruct'; reason: null; candidate: null; sentence: string };

export interface ProposeMemoryContext {
  readonly conversationId: string;
  readonly folderId: string | null;
  readonly messageId: string;
  /** Text of the fresh user message of this turn; sourceQuote must come from it. */
  readonly userText: string;
  readonly nowMs: number;
  readonly activeContents: readonly string[];
  readonly records: readonly MemoryCandidateRecord[];
}

function skip(reason: ProposeMemorySkipReason): ProposeMemoryOutcome {
  return { action: 'skip', reason, candidate: null };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * One propose_memory call → at most one pending candidate or one instruct sentence.
 * priorInTurn = earlier calls of the same turn; priorInstructInTurn = earlier calls of the turn that yielded instruct.
 */
export function proposeMemoryCandidate(
  argumentsJson: string,
  context: ProposeMemoryContext,
  priorInTurn: number,
  priorInstructInTurn = 0,
): ProposeMemoryOutcome {
  if (priorInTurn >= PROPOSE_MEMORY_MAX_PER_TURN) return skip('turn_limit');
  let args: unknown;
  try {
    args = JSON.parse(argumentsJson);
  } catch {
    return skip('invalid_arguments');
  }
  if (!isRecord(args)) return skip('invalid_arguments');
  const { proposition, kind, scope, sourceQuote } = args;
  if (
    typeof proposition !== 'string'
    || typeof sourceQuote !== 'string'
    || !KINDS.includes(kind as MemoryKind)
    || !SCOPES.includes(scope as ProposeMemoryScope)
  ) {
    return skip('invalid_arguments');
  }
  const content = trimWhiteSpace(proposition);
  const quote = memoryIntentCanonical(sourceQuote);
  if (content === '' || quote === '') return skip('invalid_arguments');
  if ([...content].length > MEMORY_INTENT_CONTENT_MAX_CODE_POINTS) return skip('too_long');
  if (!memoryIntentCanonical(context.userText).includes(quote)) return skip('quote_not_in_message');
  const sensitive = (text: string) => classifyMemoryIntent(text).sensitive;
  if ([context.userText, content, sourceQuote].some((t) => sensitive(t) === 'secret')) return skip('secret');
  if ([content, sourceQuote].some((t) => sensitive(t) === 'special')) return skip('special');
  // v3: when the model states the conversation scope, hand it to the "set as conversation instruction" item and do not create a memory candidate
  if (scope === 'conversation') {
    if (kind !== 'instruction') return skip('conversation_not_instruction');
    if (priorInstructInTurn >= PROPOSE_MEMORY_MAX_INSTRUCT_PER_TURN) return skip('instruct_limit');
    return { action: 'instruct', reason: null, candidate: null, sentence: trimWhiteSpace(sourceQuote) };
  }
  // For other scopes, a convention that holds for this conversation still belongs to the "set as conversation instruction" item (lexical path), not to a memory item
  const v1 = classifyMemoryIntent(context.userText);
  if (v1.suggestion === 'conversationInstruction' || v1.blocked === 'conversation_scope') return skip('conversation_instruction');
  const outcome: MemoryCandidateOutcome = makeMemoryCandidate(
    {
      intent: 'implicit_persist',
      rule: null,
      span: null,
      proposition: content,
      kind: kind as MemoryKind,
      scope: scope as ProposeMemoryScope,
      sensitive: 'none',
      blocked: null,
      suggestion: 'memory',
    },
    {
      conversationId: context.conversationId,
      folderId: context.folderId,
      messageId: context.messageId,
      nowMs: context.nowMs,
      activeContents: context.activeContents,
      records: context.records,
    },
  );
  if (outcome.action === 'create') return outcome;
  // makeMemoryCandidate only yields these two for a classification it was not given.
  if (outcome.reason === 'no_suggestion' || outcome.reason === 'auto_suggest_off') return skip('invalid_arguments');
  return skip(outcome.reason);
}

export type ProposeMemoryMode = 'tool' | 'fallback' | 'none';

export interface ProposeMemoryModeInput {
  readonly purpose: RequestPurpose;
  /** A fresh user send (not retry, regenerate, edit, continue or recovery). */
  readonly freshSend: boolean;
  /** Effective useMemory of the conversation. */
  readonly memoryEnabled: boolean;
  readonly autoSuggest: boolean;
  /** The request can carry client tools (the MCP tool predicate, minus the Moonshot built-in web loop). */
  readonly connectionSupportsTools: boolean;
  /** This connection and model got a tool-unsupported rejection earlier in the process. */
  readonly degraded: boolean;
}

/** tool: attach propose_memory; fallback: the memory-intent.v1 route; none: neither. */
export function proposeMemoryMode(input: ProposeMemoryModeInput): ProposeMemoryMode {
  if (input.purpose !== 'chat' || !input.freshSend) return 'none';
  if (!input.memoryEnabled || !input.autoSuggest || !input.connectionSupportsTools || input.degraded) return 'fallback';
  return 'tool';
}

export interface ProposeMemoryRejection {
  /** The client tool-unsupported matcher (tool-unsupported-4xx.json) says yes. */
  readonly toolUnsupported: boolean;
  readonly legIndex: number;
  readonly streamStarted: boolean;
  readonly receivedStructuredToolCalls: boolean;
}

/** Resend without tools, run the fallback route and mark the connection degraded. */
export function shouldDegradeProposeMemory(rejection: ProposeMemoryRejection): boolean {
  return rejection.toolUnsupported
    && rejection.legIndex === 0
    && !rejection.streamStarted
    && !rejection.receivedStructuredToolCalls;
}

/** Key of the in-process degraded set: connection id \n model id. */
export function proposeMemoryDegradedKey(connectionId: string, modelId: string): string {
  return `${connectionId}\n${modelId}`;
}

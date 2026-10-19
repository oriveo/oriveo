/**
 * Context compactor deterministic pure functions (context pipeline §8).
 * Spec: context-contracts/checkpoint.v1.json rules[7..10].
 */

import { ContextBudget } from './budget';
import {
  ContextCheckpoint,
  type CheckpointSpanMessage,
  type SummaryValidationReason,
} from './checkpoint';
import { escapeXmlText } from './sanitize';
import { trimWhiteSpace } from './white-space';

export const CONTEXT_COMPACTOR_CONSTANTS = {
  summaryPromptTemplate:
    'You are writing a CONTEXT CHECKPOINT so this conversation can continue after older messages are removed.\n' +
    "The user's own messages are preserved separately; do not restate them, and do not restate any <oriveo-*> blocks.\n" +
    'Write in {language}. Use EXACTLY these level-2 headings in this order; write "(none)" if empty:\n' +
    '## Goal                 — what the user is trying to achieve in this conversation\n' +
    '## Key Facts & Decisions\n' +
    '## Work Produced        — artifacts created so far (e.g. chapters, code, plans): title + 1-line gist each\n' +
    '## Open Threads         — unanswered questions, pending tasks, what the user asked for next\n' +
    '## Style & Language     — language, tone, format conventions in use\n' +
    'Do not invent facts. Do not address the user. Max {S_max} tokens.',
  languageFallback: "the language the assistant's answers in this conversation are written in",
  serializedSystem:
    "You write context checkpoints that let a conversation continue after older messages are removed. Follow the format given in the user's message exactly.",
  attachmentPlaceholder: '[{kind}: {name}]',
  maxSummaryAttempts: 2,
  breaker: { failuresToTrip: 2, fallbackTurns: 10 },
} as const;

export interface SummaryRequestAttachment {
  kind: 'image' | 'file';
  name: string;
}

export interface SummaryRequestSpanMessage {
  id: string;
  role: 'user' | 'assistant';
  text: string;
  attachments?: SummaryRequestAttachment[];
}

export interface SummaryRequestInput {
  U: number;
  prefixTokens: number;
  rhoHi: number;
  language?: string | null;
  summaryMax: number;
  previousCheckpointText?: string | null;
  previousSummary?: string | null;
  span: readonly SummaryRequestSpanMessage[];
}

export interface SummaryRequestMessage {
  role: 'user' | 'assistant';
  text: string;
}

export type SummaryRequest =
  | {
      shape: 'appended' | 'serialized';
      /** null = keep the session system prompt and tools. */
      system: string | null;
      toolChoice: 'none';
      maxOutputTokens: number;
      messages: SummaryRequestMessage[];
      estInputTokens: number;
    }
  | { shape: 'tooLarge'; appendedTokens: number; serializedTokens: number };

export interface CompactMessage extends CheckpointSpanMessage {
  text: string;
  isDirective?: boolean;
}

export interface CompactInput {
  conversationId: string;
  B: number;
  rhoHi: number;
  messages: readonly CompactMessage[];
  previous?: { coversTo: string; summary: string } | null;
  /** Summary model outputs in call order; null = the call failed. */
  summaryOutputs: ReadonlyArray<string | null>;
}

export type CompactFailureReason = SummaryValidationReason | 'callError';

export type CompactResult =
  | { outcome: 'noop' }
  | { outcome: 'fallback'; attempts: number; failures: CompactFailureReason[][]; spanTokens: number }
  | {
      outcome: 'summary';
      attempts: number;
      failures: CompactFailureReason[][];
      spanTokens: number;
      coversFrom: string;
      coversTo: string;
      messagesCovered: number;
      keptUserIds: string[];
      checkpointId: string;
      coversDigest: string;
      text: string;
    };

const constants = CONTEXT_COMPACTOR_CONSTANTS;

/** Literal placeholder substitution; `$` patterns in the value are never interpreted. */
function fill(template: string, placeholder: string, value: string): string {
  return template.split(placeholder).join(value);
}

/** Absent = null / undefined or only Unicode White_Space. */
function present(text: string | null | undefined): text is string {
  return text != null && trimWhiteSpace(text).length > 0;
}

/** Rule 7: prompt with resolved language (or the fallback phrase) and summaryMax. */
function summaryPrompt(language: string | null | undefined, summaryMax: number): string {
  const resolved = present(language) ? language : constants.languageFallback;
  // {S_max} first so a language name that happens to contain a placeholder stays literal
  return fill(fill(constants.summaryPromptTemplate, '{S_max}', String(summaryMax)), '{language}', resolved);
}

/** Message text followed by one placeholder line per attachment; empty parts dropped. */
function spanText(message: SummaryRequestSpanMessage): string {
  const placeholders = (message.attachments ?? []).map((a) =>
    fill(fill(constants.attachmentPlaceholder, '{kind}', a.kind), '{name}', a.name),
  );
  return [message.text, ...placeholders].filter((part) => part.length > 0).join('\n');
}

/** Rule 8: appended request when it fits U, else serialized transcript, else tooLarge. */
function summaryRequest(input: SummaryRequestInput): SummaryRequest {
  const { U, prefixTokens, rhoHi, summaryMax } = input;
  const prompt = summaryPrompt(input.language, summaryMax);
  const texts = input.span.map(spanText);

  const appended: SummaryRequestMessage[] = input.span.map((m, i) => ({ role: m.role, text: texts[i] }));
  if (present(input.previousCheckpointText) && appended.length > 0) {
    appended[0] = { ...appended[0], text: `${input.previousCheckpointText}\n\n${appended[0].text}` };
  }
  const last = appended[appended.length - 1];
  if (last && last.role === 'user') {
    appended[appended.length - 1] = { ...last, text: `${last.text}\n\n${prompt}` };
  } else {
    appended.push({ role: 'user', text: prompt });
  }
  const appendedInput =
    prefixTokens + appended.reduce((sum, m) => sum + ContextBudget.estimateMessage(m.text, rhoHi), 0);
  const appendedTokens = appendedInput + summaryMax;
  if (appendedTokens <= U) {
    return {
      shape: 'appended',
      system: null,
      toolChoice: 'none',
      maxOutputTokens: summaryMax,
      messages: appended,
      estInputTokens: appendedInput,
    };
  }

  const lines = ['<transcript>'];
  if (present(input.previousSummary)) {
    lines.push('<previous-summary>', escapeXmlText(input.previousSummary), '</previous-summary>');
  }
  input.span.forEach((m, i) => {
    lines.push(`<message id="${m.id}" role="${m.role}">${escapeXmlText(texts[i])}</message>`);
  });
  lines.push('</transcript>');
  const userText = `${lines.join('\n')}\n\n${prompt}`;
  const system = constants.serializedSystem;
  const serializedInput = ContextBudget.estimateMessage(system, rhoHi) + ContextBudget.estimateMessage(userText, rhoHi);
  const serializedTokens = serializedInput + summaryMax;
  if (serializedTokens <= U) {
    return {
      shape: 'serialized',
      system,
      toolChoice: 'none',
      maxOutputTokens: summaryMax,
      messages: [{ role: 'user', text: userText }],
      estInputTokens: serializedInput,
    };
  }
  return { shape: 'tooLarge', appendedTokens, serializedTokens };
}

/** Rule 9: select span, try summary outputs, assemble the checkpoint or report fallback. */
function compact(input: CompactInput): CompactResult {
  const { messages, B, rhoHi } = input;
  const span = ContextCheckpoint.selectSpan(messages, B, input.previous?.coversTo ?? null);
  if (span.action === 'noop') return { outcome: 'noop' };

  const covered = messages.slice(0, span.messagesCovered);
  const spanIds = new Set(span.spanIds);
  const spanTokens =
    messages.filter((m) => spanIds.has(m.id)).reduce((sum, m) => sum + m.estTokens, 0) +
    (present(input.previous?.summary) ? ContextBudget.estimateText(input.previous.summary, rhoHi) : 0);
  const summaryMax = ContextBudget.derive(B).summaryMax;

  const failures: CompactFailureReason[][] = [];
  let attempts = 0;
  let summary: string | null = null;
  for (const output of input.summaryOutputs.slice(0, constants.maxSummaryAttempts)) {
    attempts += 1;
    if (output === null) {
      failures.push(['callError']);
      continue;
    }
    // First normalize a "## Title — explanation" heading copied by the model into a bare title; validation and storage both use the normalized text
    const normalized = ContextCheckpoint.normalizeHeadings(output);
    const validation = ContextCheckpoint.validateSummary(normalized, summaryMax, spanTokens, rhoHi);
    if (validation.valid) {
      summary = normalized;
      break;
    }
    failures.push(validation.reasons);
  }
  if (summary === null) return { outcome: 'fallback', attempts, failures, spanTokens };

  const kept = ContextCheckpoint.pickUserMessages(
    covered
      .filter((m) => m.role === 'user')
      .map((m) => ({ id: m.id, text: m.text, isDirective: m.isDirective === true })),
    B,
    rhoHi,
  );
  return {
    outcome: 'summary',
    attempts,
    failures,
    spanTokens,
    coversFrom: span.coversFrom,
    coversTo: span.coversTo,
    messagesCovered: span.messagesCovered,
    keptUserIds: kept.map((m) => m.id),
    checkpointId: ContextCheckpoint.checkpointId(
      input.conversationId,
      span.coversTo,
      ContextCheckpoint.constants.packerVersion,
    ),
    coversDigest: ContextCheckpoint.coversDigest(covered.map((m) => ({ id: m.id, text: m.text }))),
    text: ContextCheckpoint.serialize(span.coversFrom, span.coversTo, span.messagesCovered, kept, summary),
  };
}

export const ContextCompactor = {
  constants: CONTEXT_COMPACTOR_CONSTANTS,
  summaryPrompt,
  summaryRequest,
  compact,
};

export type BreakerEvent = 'llmFailure' | 'llmSuccess' | 'turn' | 'retry';
export type BreakerMode = 'llm' | 'fallbackOnly';

/** Rule 10: immutable circuit breaker for LLM summarization. */
export class ContextCompactionBreaker {
  static readonly initial = new ContextCompactionBreaker(0, 0);

  constructor(
    readonly failures: number,
    readonly turnsLeft: number,
  ) {}

  get mode(): BreakerMode {
    return this.turnsLeft > 0 ? 'fallbackOnly' : 'llm';
  }

  apply(event: BreakerEvent): ContextCompactionBreaker {
    const { failuresToTrip, fallbackTurns } = constants.breaker;
    switch (event) {
      case 'llmFailure': {
        const failures = this.failures + 1;
        return failures >= failuresToTrip
          ? new ContextCompactionBreaker(0, fallbackTurns)
          : new ContextCompactionBreaker(failures, this.turnsLeft);
      }
      case 'llmSuccess':
        return new ContextCompactionBreaker(0, this.turnsLeft);
      case 'turn':
        return new ContextCompactionBreaker(this.failures, Math.max(0, this.turnsLeft - 1));
      case 'retry':
        return ContextCompactionBreaker.initial;
    }
  }
}

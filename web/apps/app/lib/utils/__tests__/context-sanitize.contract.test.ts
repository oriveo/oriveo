import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';
import type { Attachment, ChatMessage } from '@oriveo/shared';
import { sanitizeOutboundMessages, UNANSWERED_ENVELOPE_NOTE } from '../chat-stream-utils';

interface FixtureMessage {
  id: string;
  role: 'user' | 'assistant';
  text: string;
  state: ChatMessage['state'];
  attachments?: Array<{ id: string; kind: Attachment['kind'] }>;
}

interface FixtureCase {
  id: string;
  input: { messages: FixtureMessage[]; keepAssistantId?: string };
  expected: Array<{ id: string; role: string; text: string; attachments: string[] }>;
}

interface SanitizeContract {
  unansweredEnvelope: { note: string };
  cases: FixtureCase[];
}

// The contract fixture lives under shared/ at the repository root; walk up from cwd to find it
function loadContract(): SanitizeContract {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'context-contracts', 'sanitize.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8'));
    dir = path.dirname(dir);
  }
  throw new Error('sanitize.v1.json not found');
}

const contract = loadContract();

function toChatMessage(m: FixtureMessage): ChatMessage {
  return {
    id: m.id,
    role: m.role,
    text: m.text,
    providerKind: 'openRouter',
    providerName: 'OpenRouter',
    modelName: 'openai/gpt-5.4',
    estimatedCost: 0,
    state: m.state,
    createdAt: '2026-10-15T00:00:00.000Z',
    attachments: m.attachments?.map((a) => ({
      id: a.id,
      kind: a.kind,
      fileName: `${a.id}.bin`,
      mimeType: a.kind === 'image' ? 'image/png' : 'application/octet-stream',
      base64Data: 'AAAA',
    })),
  };
}

describe('sanitize.v1 contract', () => {
  it('production envelope note matches the contract byte for byte', () => {
    expect(UNANSWERED_ENVELOPE_NOTE).toBe(contract.unansweredEnvelope.note);
  });

  it.each(contract.cases.map((c) => [c.id, c] as const))('%s', (_id, c) => {
    const result = sanitizeOutboundMessages(c.input.messages.map(toChatMessage), c.input.keepAssistantId);
    expect(
      result.map((m) => ({
        id: m.id,
        role: m.role,
        text: m.text,
        attachments: (m.attachments ?? []).map((a) => a.id),
      })),
    ).toEqual(c.expected);
  });

  it('merged user keeps non-content fields of the last user in the run', () => {
    const [u1, a1, u2] = contract.cases.find((c) => c.id === 'failed_assistant_between_users_merges_into_envelope')!
      .input.messages.map(toChatMessage);
    const result = sanitizeOutboundMessages([u1, a1, { ...u2, createdAt: '2026-10-15T01:00:00.000Z', modelName: 'latest-model' }]);
    expect(result).toHaveLength(1);
    expect(result[0].createdAt).toBe('2026-10-15T01:00:00.000Z');
    expect(result[0].modelName).toBe('latest-model');
  });
});

import { describe, expect, it } from 'vitest';

import { ContextSanitizer, UNANSWERED_ENVELOPE_NOTE } from '../sanitize';
import { ContextContractFixture, toContextMessage, type FixtureMessage } from './fixture';

interface SanitizeContract {
  unansweredEnvelope: { tag: string; note: string };
  cases: Array<{
    id: string;
    input: { messages: FixtureMessage[]; keepAssistantId?: string };
    expected: Array<{ id: string; role: string; text: string; attachments: string[] }>;
  }>;
}

const contract = ContextContractFixture.load<SanitizeContract>('sanitize.v1.json');

describe('ContextContractSanitize', () => {
  it('unanswered envelope note matches the fixture byte for byte', () => {
    expect(UNANSWERED_ENVELOPE_NOTE).toBe(contract.unansweredEnvelope.note);
  });

  it.each(contract.cases.map((c) => [c.id, c] as const))('%s', (id, c) => {
    const result = ContextSanitizer.sanitize(c.input.messages.map(toContextMessage), c.input.keepAssistantId);
    const actual = result.map((m) => ({
      id: m.id,
      role: m.role,
      text: m.text,
      attachments: m.attachments.map((a) => a.id),
    }));
    expect(actual, id).toStrictEqual(c.expected);
  });
});

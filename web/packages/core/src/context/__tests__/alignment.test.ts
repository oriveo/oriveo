import { describe, expect, it } from 'vitest';

import type { Attachment } from '@oriveo/shared/pure-types';

import * as assembleModule from '../assemble';
import { ContextAssembler } from '../assemble';
import { ContextBudget } from '../budget';
import { RhoCalibration, RhoCalibrationTable, type RhoCalibrationTableJSON } from '../calibration';
import type { ContextMessage } from '../message';
import * as planModule from '../plan';

// Supplementary assertions for the cross-platform alignment conclusions (alignment items 2 / 6 / 8 / brand).
describe('ContextContractLedger alignment', () => {
  it('table JSON entries are sorted by (transportInstanceId, modelId)', () => {
    const table = new RhoCalibrationTable();
    table.set('t-b', 'm-a', RhoCalibration.initial());
    table.set('t-a', 'm-b', RhoCalibration.initial());
    table.set('t-a', 'm-a', RhoCalibration.initial());
    expect(table.toJSON().entries.map((e) => [e.transportInstanceId, e.modelId])).toEqual([
      ['t-a', 'm-a'],
      ['t-a', 'm-b'],
      ['t-b', 'm-a'],
    ]);
  });

  it('table decode rejects version other than 1', () => {
    const json = { version: 2, entries: [] } as unknown as RhoCalibrationTableJSON;
    expect(() => RhoCalibrationTable.fromJSON(json)).toThrow();
  });
});

describe('ContextContractBudget integer arithmetic', () => {
  it('R uses integer ceil(0.10W), not double multiplication', () => {
    // 1030 * 0.1 = 103.00000000000001 in IEEE double; integer ceil gives 103.
    const budget = ContextBudget.window({ W: 1030, windowKind: 'total', maxOutput: { user: 100 }, budgetCap: 'auto' });
    expect(budget.R).toBe(103);
  });

  it('ring percent uses integer ceil division', () => {
    // 7 / 100 * 100 = 7.000000000000001 in IEEE double; integer ceil gives 7.
    const ring = ContextBudget.display({
      windowKnown: true,
      pHat: 7,
      B: 100,
      basis: 'observed',
      observedEver: true,
      overflowed: false,
    });
    expect(ring).toStrictEqual({ display: 'percent', percent: 7, tone: 'neutral' });
  });
});

describe('ContextContractAssemble alignment', () => {
  it('compaction carries memory but no [D] and no reminder', () => {
    const plan = ContextAssembler.assemble({
      purpose: 'compaction',
      window: { W: 200000, windowKind: 'total', maxOutput: { model: 8192 } },
      conversation: { id: 'c1', useMemory: true, instructions: 'Write only in Arabic.' },
      memoryItems: [{ id: 'm1', kind: 'preference', content: 'Prefers concise answers.' }],
      history: [1, 2, 3, 4, 5, 6].flatMap((i) => [
        { id: `u${i}`, role: 'user' as const, text: `Turn ${i}`, state: 'delivered' as const, attachments: [] },
        { id: `a${i}`, role: 'assistant' as const, text: `Answer ${i}`, state: 'delivered' as const, attachments: [] },
      ]),
      current: 'Summarize the conversation.',
      dynamic: { recall: [{ id: 'r1', text: 'x' }] },
    });
    expect(plan.segments.map((s) => s.kind)).toEqual(['instructions', 'memory']);
    expect(plan.reminder).toBe(false);
    expect(plan.messages?.at(-1)?.blocks).toEqual([{ kind: 'text', text: 'Summarize the conversation.' }]);
  });

  it('plan factory is not exported from any module', () => {
    const exported = [...Object.keys(planModule), ...Object.keys(assembleModule)];
    expect(exported.filter((name) => /seal|make|create/i.test(name))).toEqual([]);
  });
});

describe('ContextContractAlign', () => {
  const window = { W: 2048, windowKind: 'total' as const, maxOutput: { model: 256 } };
  const msg = (id: string, role: 'user' | 'assistant', text: string, attachments: Attachment[] = []): ContextMessage => ({
    id,
    role,
    text,
    state: 'delivered',
    attachments,
  });
  const big = 'x'.repeat(3400);

  it('align_12 compaction advice is computed only for chat / continue / toolLoopLeg', () => {
    const base = { window, rhoHi: 0.5, conversation: { id: 'c1', useMemory: true }, current: 'Next' };
    const history = [msg('u1', 'user', big), msg('a1', 'assistant', 'ok')];
    expect(ContextAssembler.assemble({ ...base, purpose: 'chat', history }).compaction).toBe('required');
    for (const purpose of ['compaction', 'crosscheck', 'memoryExtraction', 'imageGeneration'] as const) {
      expect(ContextAssembler.assemble({ ...base, purpose, history }).compaction, purpose).toBe('none');
    }
  });

  it('align_13 shrink and reject apply to compaction, not to crosscheck / memoryExtraction / imageGeneration', () => {
    const tiny = { W: 1024, windowKind: 'total' as const, maxOutput: { model: 128 } };
    const conversation = { id: 'c1', useMemory: true, instructions: 'i'.repeat(2000) };
    const history = [msg('u1', 'user', 'Q')];
    const compaction = ContextAssembler.assemble({ purpose: 'compaction', window: tiny, conversation, history, current: 'Go' });
    expect(compaction.reject).toBe('instructions_too_long');
    for (const purpose of ['crosscheck', 'memoryExtraction', 'imageGeneration'] as const) {
      const plan = ContextAssembler.assemble({ purpose, window: tiny, conversation, history, current: 'Go', purposeSystem: 'Review.' });
      expect(plan.reject, purpose).toBeNull();
      expect(plan.omitted, purpose).toStrictEqual({ knowledge: 0, notes: 0, memory: 0 });
    }
  });

  it('align_14 reminder user count uses raw history users plus current (before sanitize)', () => {
    // Five user messages with a failed assistant in between merge into fewer after sanitizing, but the count still follows the original 5 + current = 6.
    const history = [1, 2, 3, 4, 5].flatMap((i) => [
      msg(`u${i}`, 'user', `Turn ${i}`),
      { ...msg(`a${i}`, 'assistant', 'err'), state: 'failed' as const },
    ]);
    const plan = ContextAssembler.assemble({
      purpose: 'chat',
      window: { W: 200000, windowKind: 'total', maxOutput: { model: 8192 } },
      conversation: { id: 'c1', useMemory: true, instructions: 'Be brief.' },
      history,
      current: 'Turn 6',
    });
    expect(plan.messages).toHaveLength(1);
    expect(plan.reminder).toBe(true);
  });

  it('align_15 current message id comes from currentId, default "current"', () => {
    const input = { purpose: 'chat' as const, window, conversation: { id: 'c1', useMemory: true }, history: [], current: 'Hi' };
    expect(ContextAssembler.assemble(input).messages?.[0].id).toBe('current');
    expect(ContextAssembler.assemble({ ...input, currentId: 'u9' }).messages?.[0].id).toBe('u9');
  });

  it('align_16 memory kind / status / layer are raw strings; unknown status / layer are skipped without error', () => {
    const plan = ContextAssembler.assemble({
      purpose: 'chat',
      window,
      conversation: { id: 'c1', useMemory: true },
      memoryItems: [
        { id: 'm1', kind: 'preference', content: 'Keep.' },
        { id: 'm2', kind: 'preference', content: 'Unknown status.', status: 'zzz' },
        { id: 'm3', kind: 'preference', content: 'Unknown layer.', layer: 'zzz' },
      ],
      history: [],
      current: 'Hi',
    });
    expect(plan.system).toContain('<entry>Keep.</entry>');
    expect(plan.system).not.toContain('Unknown');
  });

  it('align_17 empty-text message has no text block but still counts 4; empty host texts are omitted', () => {
    const image: Attachment = { id: 'img', kind: 'image', fileName: 'img', mimeType: 'image/png' };
    const plan = ContextAssembler.assemble({
      purpose: 'toolLoopLeg',
      window,
      rhoHi: 0.5,
      conversation: { id: 'c1', useMemory: true },
      toolSafety: '   ',
      history: [],
      current: '',
      currentAttachments: [image],
      dynamic: { attachmentGuide: '  ' },
    });
    expect(plan.system).toBeNull();
    expect(plan.messages?.[0].blocks).toEqual([]);
    expect(plan.messages?.[0].attachments.map((a) => a.id)).toEqual(['img']);
    expect(plan.budget.estimatedInput).toBe(4);
    const chat = ContextAssembler.assemble({
      purpose: 'chat',
      window,
      conversation: { id: 'c1', useMemory: true },
      history: [],
      current: 'Hi',
      dynamic: { attachmentGuide: '  ' },
    });
    expect(chat.messages?.[0].blocks).toEqual([{ kind: 'text', text: 'Hi' }]);
  });

  const wide = { W: 200000, windowKind: 'total' as const, maxOutput: { model: 8192 } };
  const conv = { id: 'c1', useMemory: true };

  it('align_20 keepAssistantId is passed through to sanitize', () => {
    const plan = ContextAssembler.assemble({
      purpose: 'continue',
      window: wide,
      conversation: conv,
      history: [msg('u1', 'user', 'Q'), { ...msg('a1', 'assistant', 'partial'), state: 'failed' }],
      keepAssistantId: 'a1',
    });
    expect(plan.messages?.map((m) => m.id)).toEqual(['u1', 'a1', 'current']);
  });

  it('align_21 absent current appends no message and does not count toward reminder', () => {
    const history = [1, 2, 3, 4, 5, 6].flatMap((i) => [msg(`u${i}`, 'user', `Turn ${i}`), msg(`a${i}`, 'assistant', `A${i}`)]);
    history.pop();
    const base = { purpose: 'chat' as const, window: wide, conversation: { ...conv, instructions: 'Be brief.' } };
    const five = ContextAssembler.assemble({ ...base, history: history.slice(0, -2), current: null });
    expect(five.messages?.at(-1)?.id).toBe('u5');
    expect(five.reminder).toBe(false);
    const six = ContextAssembler.assemble({ ...base, history });
    expect(six.messages?.at(-1)?.id).toBe('u6');
    expect(six.reminder).toBe(true);
  });

  it('align_22 reject estimates the last sanitized message regardless of role', () => {
    const plan = ContextAssembler.assemble({
      purpose: 'continue',
      window: { W: 1024, windowKind: 'total', maxOutput: { model: 128 } },
      rhoHi: 0.5,
      conversation: conv,
      history: [msg('u1', 'user', 'Q'), { ...msg('a1', 'assistant', 'm'.repeat(2000)), state: 'interrupted' }],
      keepAssistantId: 'a1',
      current: null,
    });
    // The last message of continue is the fixed continuation sentence (user); with compaction and no current, the last message is an assistant.
    expect(plan.reject).toBeNull();
    const compaction = ContextAssembler.assemble({
      purpose: 'compaction',
      window: { W: 1024, windowKind: 'total', maxOutput: { model: 128 } },
      rhoHi: 0.5,
      conversation: conv,
      history: [msg('u1', 'user', 'Q'), msg('a1', 'assistant', 'm'.repeat(2000))],
    });
    expect(compaction.reject).toBe('message_too_long');
  });

  it('align_23 continue ignores currentAttachments', () => {
    const image: Attachment = { id: 'img', kind: 'image', fileName: 'img', mimeType: 'image/png' };
    const plan = ContextAssembler.assemble({
      purpose: 'continue',
      window: wide,
      conversation: conv,
      history: [msg('u1', 'user', 'Q'), msg('a1', 'assistant', 'A')],
      currentAttachments: [image],
    });
    expect(plan.messages?.at(-1)?.attachments).toEqual([]);
  });

  it('align_24 blank notes / knowledge / memory are removed before shrink and not counted as omitted', () => {
    const plan = ContextAssembler.assemble({
      purpose: 'chat',
      window: wide,
      conversation: {
        ...conv,
        pinnedNotes: [{ title: 'Blank', text: '   ' }],
        knowledgeFiles: [{ name: 'blank.md', text: '\n' }],
      },
      memoryItems: [{ id: 'm1', kind: 'preference', content: '  ' }],
      history: [],
      current: 'Hi',
    });
    expect(plan.system).toBeNull();
    expect(plan.segments).toEqual([]);
    expect(plan.omitted).toStrictEqual({ knowledge: 0, notes: 0, memory: 0 });
  });

  it('align_25 merged user run treats only an empty string as empty latest text', () => {
    const plan = ContextAssembler.assemble({
      purpose: 'chat',
      window: wide,
      conversation: conv,
      history: [msg('u1', 'user', 'Earlier'), { ...msg('a1', 'assistant', ''), state: 'failed' }],
      // A whitespace-only body only passes sanitize's content filter when it carries an attachment.
      current: ' ',
      currentAttachments: [{ id: 'img', kind: 'image', fileName: 'img', mimeType: 'image/png' }],
    });
    expect(plan.messages?.[0].blocks[0].text.endsWith('</oriveo-unanswered>\n\n ')).toBe(true);
  });

  it('align_26 imagePrompt is null when no non-empty user text exists', () => {
    const plan = ContextAssembler.assemble({
      purpose: 'imageGeneration',
      window: wide,
      conversation: conv,
      history: [msg('u1', 'user', '  ')],
      current: '',
    });
    expect(plan.imagePrompt).toBeNull();
  });
});

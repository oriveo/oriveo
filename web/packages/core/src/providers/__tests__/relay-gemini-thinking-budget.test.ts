/**
 * The thinkingBudget on the relay Gemini production path equals iOS / Android / Server `gem_budget`
 * (1024 / 4096 / 16384 / 24576). The old values 2048 / 8192 would make the same level send different budgets on the three platforms.
 */
import { describe, expect, it } from 'vitest';
import { buildRelayGeminiGenerateContentBody } from '../relay-orchestrator';
import { mapGeminiReasoningBudget } from '../relay-adapter';
import type { StreamOptions } from '../types';

const EXPECTED: ReadonlyArray<[NonNullable<StreamOptions['reasoning']>, number]> = [
  ['fast', 1024],
  ['balanced', 4096],
  ['deep', 16384],
  ['max', 24576],
];

describe('relay Gemini thinkingBudget', () => {
  it.each(EXPECTED)('%s → %i on the production body builder', (reasoning, budget) => {
    const body = buildRelayGeminiGenerateContentBody([{ role: 'user', content: 'hi' }], { reasoning } as StreamOptions);
    const config = body.generationConfig as { thinkingConfig?: { thinkingBudget?: number } } | undefined;
    expect(config?.thinkingConfig?.thinkingBudget).toBe(budget);
    expect(mapGeminiReasoningBudget(reasoning)).toBe(budget);
  });

  it('automatic sends no thinkingConfig', () => {
    const body = buildRelayGeminiGenerateContentBody([{ role: 'user', content: 'hi' }], { reasoning: 'automatic' } as StreamOptions);
    expect(body.generationConfig).toBeUndefined();
  });
});

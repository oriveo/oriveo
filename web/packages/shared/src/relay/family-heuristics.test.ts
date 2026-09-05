import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  compatibleRelayKinds,
  inferModelFamily,
  suggestedRelayKind,
  type RelayModelFamily,
} from './family-heuristics';

interface Fixture {
  modelId: string;
  expected: RelayModelFamily | null;
  note?: string;
}

/**
 *  `shared/test-fixtures/relay/family-fixtures.json`
 * iOS / Android  
 */
const FIXTURE_PATH = resolve(
  __dirname,
  '../../../../../shared/test-fixtures/relay/family-fixtures.json',
);
const fixtures = JSON.parse(readFileSync(FIXTURE_PATH, 'utf8')) as Fixture[];

describe('inferModelFamily', () => {
  for (const fixture of fixtures) {
    const label = fixture.note
      ? `${fixture.modelId || '<empty>'} → ${fixture.expected ?? 'null'} (${fixture.note})`
      : `${fixture.modelId || '<empty>'} → ${fixture.expected ?? 'null'}`;
    it(label, () => {
      expect(inferModelFamily(fixture.modelId)).toBe(fixture.expected);
    });
  }

  it('ignores case and surrounding whitespace', () => {
    expect(inferModelFamily('  GPT-4o  ')).toBe('openai');
    expect(inferModelFamily('CLAUDE-OPUS-4')).toBe('anthropic');
  });

  it('returns null for null / undefined', () => {
    expect(inferModelFamily(null)).toBeNull();
    expect(inferModelFamily(undefined)).toBeNull();
  });
});

describe('compatibleRelayKinds', () => {
  it('OpenAI family accepts both OpenAI compatible and Codex style profiles', () => {
    expect(compatibleRelayKinds('openai')).toEqual(['openai_compatible', 'codex_style']);
    expect(suggestedRelayKind('openai')).toBe('openai_compatible');
  });

  it('Anthropic and Google families map to their dedicated relay kinds', () => {
    expect(compatibleRelayKinds('anthropic')).toEqual(['anthropic_compatible']);
    expect(suggestedRelayKind('anthropic')).toBe('anthropic_compatible');

    expect(compatibleRelayKinds('google')).toEqual(['gemini_compatible']);
    expect(suggestedRelayKind('google')).toBe('gemini_compatible');
  });

  it('non-trinity and unknown families do not trigger protocol suggestions', () => {
    expect(compatibleRelayKinds('deepseek')).toEqual([]);
    expect(compatibleRelayKinds('qwen')).toEqual([]);
    expect(compatibleRelayKinds(null)).toEqual([]);
    expect(suggestedRelayKind('deepseek')).toBeNull();
    expect(suggestedRelayKind(null)).toBeNull();
  });
});

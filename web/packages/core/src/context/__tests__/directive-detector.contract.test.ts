import { describe, expect, it } from 'vitest';

import { detectDirective, imageStylePrefix, type DirectiveDetection } from '../directive-detector';
import {
  DIRECTIVE_IMAGE_STYLE_PREFIX_MAX,
  DIRECTIVE_LEXICON,
  DIRECTIVE_MAX_SCAN_CODE_POINTS,
  DIRECTIVE_QUESTION_ENDERS,
  DIRECTIVE_QUESTION_STARTERS,
  DIRECTIVE_QUOTE_PAIRS,
  DIRECTIVE_SENTENCE_ENDERS,
} from '../directive-lexicon';
import { WHITE_SPACE } from '../white-space';
import { ContextContractFixture } from './fixture';

type LexiconTable = Record<string, unknown> & { mode: string };

interface DirectiveDetectorContract {
  maxScanCodePoints: number;
  imageStylePrefixMax: number;
  whitespace: string[];
  sentenceEnders: string[];
  questionEnders: string[];
  questionStarters: string[];
  quotePairs: Array<[string, string]>;
  lexicon: Record<string, LexiconTable>;
  cases: Array<{ id: string; lang: string; text: string; expected: DirectiveDetection }>;
  stylePrefixCases: Array<{ id: string; instructions: string; expected: string }>;
}

const contract = ContextContractFixture.load<DirectiveDetectorContract>('directive-detector.v2.json');

describe('ContextContractDirectiveDetector', () => {
  it('cases', () => {
    const failures: string[] = [];
    for (const c of contract.cases) {
      const actual = detectDirective(c.text);
      if (JSON.stringify(actual) !== JSON.stringify(c.expected)) {
        failures.push(`${c.id}: expected ${JSON.stringify(c.expected)} got ${JSON.stringify(actual)}`);
      }
    }
    expect(failures).toStrictEqual([]);
  });

  it('stylePrefixCases', () => {
    for (const c of contract.stylePrefixCases) {
      expect(imageStylePrefix(c.instructions), c.id).toBe(c.expected);
    }
  });

  it('lexicon_matches_fixture', () => {
    const embedded = DIRECTIVE_LEXICON.map(({ code, ...rest }) => [code, rest] as const);
    const fixture = Object.entries(contract.lexicon);
    expect(embedded.map(([code]) => code)).toStrictEqual(fixture.map(([code]) => code));
    for (const [code, table] of fixture) {
      const mine = embedded.find(([c]) => c === code)?.[1];
      expect(mine, code).toStrictEqual(table);
    }
  });

  it('constants_match_fixture', () => {
    expect(DIRECTIVE_MAX_SCAN_CODE_POINTS).toBe(contract.maxScanCodePoints);
    expect(DIRECTIVE_IMAGE_STYLE_PREFIX_MAX).toBe(contract.imageStylePrefixMax);
    expect(DIRECTIVE_SENTENCE_ENDERS).toStrictEqual(contract.sentenceEnders);
    expect(DIRECTIVE_QUESTION_ENDERS).toStrictEqual(contract.questionEnders);
    expect(DIRECTIVE_QUESTION_STARTERS).toStrictEqual(contract.questionStarters);
    expect(DIRECTIVE_QUOTE_PAIRS).toStrictEqual(contract.quotePairs);
  });

  it('white_space_matches_fixture', () => {
    expect([...WHITE_SPACE]).toEqual(contract.whitespace);
  });

  // Regression: the fence check once rescanned to end of text at every position (O(n^2));
  // compaction runs this on every user message of a long history on the main thread.
  it('long_history_detection_stays_linear', () => {
    const message = 'This is an ordinary sentence about the weather and the town. '.repeat(80);
    const started = performance.now();
    for (let i = 0; i < 100; i++) detectDirective(message);
    expect(performance.now() - started).toBeLessThan(1500);
  });
});

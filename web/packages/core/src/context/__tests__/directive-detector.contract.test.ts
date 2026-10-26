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

  // Linearity is judged by the time ratio when the input size doubles, not by an absolute wall-clock budget:
  // a fixed budget measures machine speed (slow CI runners fail it), the ratio measures complexity.
  // Linear gives about 2x (measured 1.8-2.1); quadratic gives 4x in theory and about 3-3.9x measured once
  // linear fixed costs are mixed in, so the limit is 2.5. Input is truncated at DIRECTIVE_MAX_SCAN_CODE_POINTS,
  // so 2N must stay below the cap, otherwise truncation would flatten the ratio to 1.
  const RATIO_LIMIT = 2.5;
  const ROUNDS = 5;
  const timeOf = (inputs: string[], loops: number): number => {
    for (let i = 0; i < loops; i++) for (const t of inputs) detectDirective(t); // warm up the JIT
    const samples: number[] = [];
    for (let r = 0; r < ROUNDS; r++) {
      const started = performance.now();
      for (let i = 0; i < loops; i++) for (const t of inputs) detectDirective(t);
      samples.push(performance.now() - started);
    }
    return Math.min(...samples); // take the minimum: scheduling jitter can only inflate a sample, never shrink it
  };
  const scaleRatio = (build: (n: number) => string[], n: number, loops: number): number => {
    const small = build(n);
    const large = build(n * 2);
    for (const t of large) expect([...t].length).toBeLessThanOrEqual(DIRECTIVE_MAX_SCAN_CODE_POINTS);
    return timeOf(large, loops) / timeOf(small, loops);
  };

  // Regression: the fence check once rescanned to end of text at every position (O(n^2));
  // compaction runs this on every user message of a long history on the main thread.
  it('long_history_detection_stays_linear', () => {
    const build = (n: number): string[] => ['This is an ordinary sentence about the weather and the town. '.repeat(n)];
    expect(scaleRatio(build, 20, 8)).toBeLessThan(RATIO_LIMIT);
    // loose absolute cap only guards against exponential blow-up; it is not used to judge linearity
    const started = performance.now();
    detectDirective(build(40)[0]!);
    expect(performance.now() - started).toBeLessThan(200);
  });

  // Near markers sweep tokens once per term: a 4000-code-point sentence dense with `a` terms and no `b`
  // must stay cheap (no pairwise or backtracking search).
  it('near_markers_stay_linear', () => {
    const build = (n: number): string[] => ['꼭 계속해서 '.repeat(n * 3), 'اكتب لا تستخدم دائما '.repeat(n)];
    expect(scaleRatio(build, 90, 5)).toBeLessThan(RATIO_LIMIT);
    const started = performance.now();
    for (const t of build(180)) detectDirective(t);
    expect(performance.now() - started).toBeLessThan(200);
  });
});

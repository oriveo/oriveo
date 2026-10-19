import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import { createTranslator } from 'use-intl/core';
import { CompactionBreakers } from '../../context-pipeline/compaction-coordinator';
import { summarizeContextUsage, type UsageCheckpointInput, type UsageManifestInput } from '../usage-summary';
import {
  breakerRetryShown,
  panelBodyOf,
  panelButtonsOf,
  panelLegendOf,
  settingsUsageValueOf,
} from '../usage-panel-model';

// Context panel and settings usage row: pure value functions + 16-locale copy.

interface SummaryCase {
  id: string;
  input: { manifests: UsageManifestInput[]; checkpoint: UsageCheckpointInput | null };
}

function repoFile(relative: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, relative);
    if (existsSync(candidate)) return candidate;
    const next = path.dirname(current);
    if (next === current) throw new Error(relative);
    current = next;
  }
}

const fixture = JSON.parse(readFileSync(repoFile('shared/context-contracts/usage.v1.json'), 'utf8')) as {
  summaryCases: SummaryCase[];
};

/** The latest request applied a checkpoint, which was cleared afterwards (no valid checkpoint now). */
function clearedSummary() {
  const testCase = fixture.summaryCases.find((c) => c.id === 'observed_38');
  if (!testCase) throw new Error('observed_38');
  const manifests = testCase.input.manifests.map((m, i, all) => (i === all.length - 1 ? { ...m, checkpointId: 'k1' } : m));
  return summarizeContextUsage(manifests, null);
}

function summaryOf(id: string) {
  const testCase = fixture.summaryCases.find((c) => c.id === id);
  if (!testCase) throw new Error(id);
  return summarizeContextUsage(testCase.input.manifests, testCase.input.checkpoint);
}

describe('context usage panel model', () => {
  beforeEach(() => {
    CompactionBreakers.reset();
  });

  it('panel_buttons_follow_checkpoint', () => {
    expect(panelButtonsOf({ hasCheckpoint: false, compacting: false, sending: false })).toEqual({
      compact: { disabled: false },
      newChatWithSummary: false,
      clear: false,
    });
    expect(panelButtonsOf({ hasCheckpoint: true, compacting: false, sending: false })).toEqual({
      compact: { disabled: false },
      newChatWithSummary: true,
      clear: true,
    });
    expect(panelButtonsOf({ hasCheckpoint: true, compacting: true, sending: false }).compact.disabled).toBe(true);
    expect(panelButtonsOf({ hasCheckpoint: false, compacting: false, sending: true }).compact.disabled).toBe(true);
  });

  it('panel_breaker_retry_shown_when_fallback_only', () => {
    // Initial state of the production circuit breaker: not tripped, no [Retry] shown.
    expect(breakerRetryShown(CompactionBreakers.mode('c1'))).toBe(false);
    expect(breakerRetryShown('fallbackOnly')).toBe(true);
    expect(breakerRetryShown('llm')).toBe(false);
  });

  it('panel_legend_lists_positive_segments', () => {
    // observed_38: library 11000, instructions 600, memory 2000; summary 0 is not listed; conversation and free space are always listed.
    expect(panelLegendOf(summaryOf('observed_38').segments)).toEqual([
      { kind: 'conversation', tokens: 30176 },
      { kind: 'library', tokens: 11000 },
      { kind: 'instructions', tokens: 600 },
      { kind: 'memory', tokens: 2000 },
      { kind: 'free', tokens: 71424 },
    ]);
    // Conversation clamped to 0; free space 0 is still listed.
    expect(panelLegendOf(summaryOf('over_100_without_overflow_shows_bang').segments)).toEqual([
      { kind: 'conversation', tokens: 116000 },
      { kind: 'free', tokens: 0 },
    ]);
    expect(panelLegendOf(summaryOf('conversation_clamped_at_zero').segments).map((item) => item.kind)).toEqual([
      'conversation',
      'library',
      'instructions',
      'free',
    ]);
    expect(panelLegendOf(null)).toEqual([]);

    // Ring body: percent and never_observed draw the ring; the rest show a dashed circle + hint.
    expect(panelBodyOf(summaryOf('observed_38'))).toEqual({ kind: 'ring', percent: 38, about: false, basis: 'observed' });
    expect(panelBodyOf(summaryOf('latest_estimated_after_earlier_observed'))).toEqual({
      kind: 'ring',
      percent: 44,
      about: true,
      basis: 'estimated',
    });
    expect(panelBodyOf(summaryOf('never_observed_unavailable_with_estimate'))).toEqual({
      kind: 'ring',
      percent: 18,
      about: true,
      basis: 'estimated',
    });
    expect(panelBodyOf(summaryOf('window_unknown'))).toEqual({ kind: 'unavailable', hint: 'hintWindowUnknown' });
    expect(panelBodyOf(summaryOf('compacted_since_last_request'))).toEqual({ kind: 'unavailable', hint: 'hintCompacted' });
    // After clearing the condensed summary, before the next send: keep using hintEmpty.
    expect(panelBodyOf(clearedSummary())).toEqual({ kind: 'unavailable', hint: 'hintEmpty' });
  });

  it('settings_usage_value_text', () => {
    expect(settingsUsageValueOf(summaryOf('observed_38'))).toEqual({ key: 'percent', percent: 38 });
    expect(settingsUsageValueOf(summaryOf('over_100_without_overflow_shows_bang'))).toEqual({ key: 'percent', percent: 101 });
    expect(settingsUsageValueOf(summaryOf('latest_estimated_after_earlier_observed'))).toEqual({
      key: 'aboutPercent',
      percent: 44,
    });
    expect(settingsUsageValueOf(summaryOf('never_observed_unavailable_with_estimate'))).toEqual({
      key: 'aboutPercent',
      percent: 18,
    });
    expect(settingsUsageValueOf(summaryOf('window_unknown'))).toEqual({ key: 'unavailable' });
    expect(settingsUsageValueOf(summaryOf('compacted_since_last_request'))).toEqual({ key: 'unavailable' });
    expect(settingsUsageValueOf(clearedSummary())).toEqual({ key: 'unavailable' });
    expect(settingsUsageValueOf(null)).toEqual({ key: 'unavailable' });
  });

  it('compacted_count_singular_formats', () => {
    const messages = JSON.parse(readFileSync(path.join(process.cwd(), 'messages', 'en.json'), 'utf8'));
    const t = createTranslator({ locale: 'en', messages, namespace: 'pages.chat.contextUsage' });
    expect(t('compactedCount', { count: 1, time: '2m ago' })).toBe('Condensed 1 time · 2m ago');
    expect(t('compactedCount', { count: 3, time: '2m ago' })).toBe('Condensed 3 times · 2m ago');
  });

  it('panel_strings_present_in_16_locales', () => {
    const locales = [
      'ar', 'de', 'en', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant',
    ];
    const keys = [
      'title', 'measured', 'estimated', 'aboutPercent', 'segmentConversation', 'segmentLibrary', 'segmentSummary',
      'segmentInstructions', 'segmentMemory', 'segmentFree', 'unavailable', 'hintWindowUnknown',
      'hintCompacted', 'hintEmpty', 'compactedCount', 'omittedNotes', 'omittedKnowledge', 'omittedMemory',
      'breakerPaused', 'retry',
    ];
    const plural = new Set(['compactedCount', 'omittedNotes', 'omittedKnowledge', 'omittedMemory']);
    const placeholders: Record<string, string[]> = {
      aboutPercent: ['{percent}'],
      compactedCount: ['{count}', '{time}'],
      omittedNotes: ['{count}'],
      omittedKnowledge: ['{count}'],
      omittedMemory: ['{count}'],
    };
    for (const locale of locales) {
      const messages = JSON.parse(readFileSync(path.join(process.cwd(), 'messages', `${locale}.json`), 'utf8'));
      const usage = messages.pages.chat.contextUsage as Record<string, string>;
      expect(typeof messages.common.done).toBe('string');
      for (const key of keys) {
        const value = usage[key];
        expect({ locale, key, ok: typeof value === 'string' && value.trim().length > 0 }).toEqual({ locale, key, ok: true });
        if (plural.has(key)) expect({ locale, key, plural: value.startsWith('{count, plural,') }).toEqual({ locale, key, plural: true });
        for (const token of placeholders[key] ?? []) {
          expect({ locale, key, token, has: value.includes(token) }).toEqual({ locale, key, token, has: true });
        }
      }
    }
  });
});

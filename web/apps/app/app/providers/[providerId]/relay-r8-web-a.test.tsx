import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel } from '@oriveo/shared';
import { formatCompactRelativeTime, type CompactRelativeTimeText } from '../../../lib/utils/format-utils';
import { ModelBrowser } from './ModelBrowser';

/** Model library first screen does not auto-scroll; relay relative-time convention. */

function makeModel(id: string, groupKey: string, groupName: string): AIModel {
  return { id, name: id, capabilities: [], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '', groupKey, groupName };
}

describe('Model library first screen does not auto-scroll', () => {
  const scrollIntoView = vi.fn();
  const original = Element.prototype.scrollIntoView;

  beforeEach(() => {
    localStorage.clear();
    scrollIntoView.mockReset();
    Element.prototype.scrollIntoView = scrollIntoView;
  });

  afterEach(() => {
    Element.prototype.scrollIntoView = original;
  });

  it('restored expanded groups do not scrollIntoView; only a user tapping a group opens and scrolls', () => {
    const models = [makeModel('openai/gpt-4.1', 'openai', 'OpenAI'), makeModel('anthropic/claude-3.7-sonnet', 'anthropic', 'Anthropic')];
    const browser = () => (
      <ModelBrowser catalogModels={models} providerKind="openRouter" providerLabel="OpenRouter" onToggleModel={vi.fn()} />
    );
    const first = render(browser());
    fireEvent.click(screen.getByTestId('shortcut-anthropic'));
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    first.unmount();
    scrollIntoView.mockReset();

    // Re-enter: the expanded state is restored from local storage, but the first screen does not scroll.
    render(browser());
    expect(screen.getByTestId('group-anthropic').getAttribute('data-expanded')).toBe('true');
    expect(scrollIntoView).not.toHaveBeenCalled();

    // Scroll only when the user opens another group.
    fireEvent.click(screen.getByTestId('group-openai').querySelector('button[aria-expanded]')!);
    expect(screen.getByTestId('group-openai').getAttribute('data-expanded')).toBe('true');
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
  });
});

describe('RL2-RELTIME-01 relay relative time', () => {
  const text: CompactRelativeTimeText = {
    justNow: 'Just now',
    minutesAgo: (count) => `${count} min ago`,
    hoursAgo: (count) => `${count} hr ago`,
    yesterday: 'Yesterday',
  };
  const now = new Date(2026, 9, 13, 10, 0, 0);
  const at = (date: Date) => formatCompactRelativeTime(date.toISOString(), now, 'en', text);

  it('< 60 s Just now; < 60 min "N min ago"; < 24 h "N hr ago"; yesterday "Yesterday"; otherwise MMMd in the same year, yMMMd across years', () => {
    expect(at(new Date(2026, 9, 13, 9, 59, 30))).toBe('Just now');
    expect(at(new Date(2026, 9, 13, 9, 55, 0))).toBe('5 min ago');
    expect(at(new Date(2026, 9, 13, 9, 0, 1))).toBe('59 min ago');
    expect(at(new Date(2026, 9, 13, 7, 0, 0))).toBe('3 hr ago');
    // Yesterday on the calendar but under 24 h: still counted in hours.
    expect(at(new Date(2026, 9, 12, 23, 0, 0))).toBe('11 hr ago');
    expect(at(new Date(2026, 9, 12, 8, 0, 0))).toBe('Yesterday');
    expect(at(new Date(2026, 9, 10, 8, 0, 0))).toBe(new Intl.DateTimeFormat('en', { month: 'short', day: 'numeric' }).format(new Date(2026, 9, 10)));
    expect(at(new Date(2025, 9, 10, 8, 0, 0))).toBe(
      new Intl.DateTimeFormat('en', { year: 'numeric', month: 'short', day: 'numeric' }).format(new Date(2025, 9, 10)),
    );
    expect(formatCompactRelativeTime('not-a-date', now, 'en', text)).toBe('');
  });

  it('the two relay call sites (keys row Last, detail Checked) switch to the new function, and the copy keys are complete in all 16 languages', () => {
    const root = process.cwd();
    for (const file of ['app/providers/[providerId]/components/RelayKeysPage.tsx', 'app/providers/[providerId]/components/RelayDetailBoard.tsx']) {
      const source = readFileSync(path.join(root, file), 'utf8');
      expect(source).not.toMatch(/formatRelativeTime\(/);
      expect(source).toMatch(/formatCompactRelativeTime\(/);
    }
    const keys = ['relativeJustNow', 'relativeMinutesAgo', 'relativeHoursAgo', 'relativeYesterday'];
    for (const locale of ['en', 'ar', 'de', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant']) {
      const messages = JSON.parse(readFileSync(path.join(root, 'messages', `${locale}.json`), 'utf8'));
      for (const key of keys) expect(typeof messages.pages.relayDetail[key], `${locale}.${key}`).toBe('string');
      expect(messages.pages.relayDetail.relativeMinutesAgo).toContain('{count}');
      expect(messages.pages.relayDetail.relativeHoursAgo).toContain('{count}');
    }
    const en = JSON.parse(readFileSync(path.join(root, 'messages', 'en.json'), 'utf8')).pages.relayDetail;
    expect([en.relativeJustNow, en.relativeMinutesAgo, en.relativeHoursAgo, en.relativeYesterday]).toEqual([
      'Just now', '{count} min ago', '{count} hr ago', 'Yesterday',
    ]);
  });
});

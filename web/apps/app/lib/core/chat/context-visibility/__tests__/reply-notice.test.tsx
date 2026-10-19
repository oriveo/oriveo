import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { StopReason } from '@oriveo/core/context/stop-reason';
import { replyNoticeOf, type ReplyNoticeInput } from '../reply-notice';
import { ReplyNotice } from '../../../../../components/chat/ReplyNotice';

vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string) => `${namespace ?? ''}.${key}`,
}));

// Incomplete-reply footer: stopReason -> notice copy key and whether it carries [Continue generating].

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

const fixture = JSON.parse(readFileSync(repoFile('shared/context-contracts/stop-reason.v1.json'), 'utf8')) as {
  enum: StopReason[];
  ui: Record<string, { notice: string; continueAction: boolean } | null>;
};

const camel = (snake: string) => snake.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());

function base(stopReason: StopReason | undefined): ReplyNoticeInput {
  return { role: 'assistant', stopReason, isLastMessage: true, isStreaming: false, hasRecoveryCard: false, isGenerating: false };
}

describe('reply notice', () => {
  it('reply_notice_follows_stop_reason_fixture', () => {
    expect(Object.keys(fixture.ui).sort()).toEqual([...fixture.enum].sort());
    for (const [reason, ui] of Object.entries(fixture.ui)) {
      const notice = replyNoticeOf(base(reason as StopReason));
      if (ui === null) {
        expect({ reason, notice }).toEqual({ reason, notice: null });
        continue;
      }
      expect({ reason, key: notice?.key, showContinue: notice?.showContinue }).toEqual({
        reason,
        key: camel(ui.notice),
        showContinue: ui.continueAction,
      });
      expect({ reason, tone: notice?.tone }).toEqual({ reason, tone: reason === 'content_filter' ? 'secondary' : 'warning' });
    }
    // Old messages have no stopReason: nothing is shown.
    expect(replyNoticeOf(base(undefined))).toBeNull();
    // A user message does not show it even if it carries a stopReason.
    expect(replyNoticeOf({ ...base('length'), role: 'user' })).toBeNull();
  });

  it('reply_continue_only_on_last_assistant', () => {
    expect(replyNoticeOf(base('length'))?.showContinue).toBe(true);
    expect(replyNoticeOf(base('incomplete'))?.showContinue).toBe(true);
    // Not the last message: the notice stays, the button is not given.
    const older = replyNoticeOf({ ...base('length'), isLastMessage: false });
    expect(older).toEqual({ key: 'incompleteOutputLimit', tone: 'warning', showContinue: false });
    // Generating (another message is streaming): the button is not given.
    const busy = replyNoticeOf({ ...base('incomplete'), isGenerating: true });
    expect(busy).toEqual({ key: 'incompleteConnection', tone: 'warning', showContinue: false });
  });

  it('reply_notice_hidden_when_recovery_card_or_streaming', () => {
    for (const reason of ['length', 'incomplete', 'content_filter', 'context_window_exceeded'] as const) {
      expect(replyNoticeOf({ ...base(reason), hasRecoveryCard: true })).toBeNull();
      expect(replyNoticeOf({ ...base(reason), isStreaming: true })).toBeNull();
    }
  });

  it('reply_continue_is_primary_button_with_icon', () => {
    // Same as iOS: "Continue generating" is a primary-color text button with a leading play icon, not bare bold text; the click behavior is unchanged.
    const notice = replyNoticeOf(base('length'));
    expect(notice?.showContinue).toBe(true);
    const onContinue = vi.fn();
    render(<ReplyNotice notice={notice!} onContinue={onContinue} />);
    const button = screen.getByRole('button', { name: 'pages.chat.recovery.continueBtn' });
    expect(button.className).toContain('continueBtn');
    const icon = button.querySelector('svg');
    expect(icon?.getAttribute('aria-hidden')).toBe('true');
    expect(button.firstElementChild).toBe(icon);
    const css = readFileSync(repoFile('web/apps/app/components/chat/ReplyNotice.module.css'), 'utf8');
    const rule = /\.continueBtn\s*\{([^}]*)\}/.exec(css)?.[1] ?? '';
    expect(rule).toMatch(/color:\s*var\(--o-primary-text-on-surface\)/);
    fireEvent.click(button);
    expect(onContinue).toHaveBeenCalledTimes(1);
    cleanup();
  });

  it('reply_strings_present_in_16_locales', () => {
    const locales = [
      'ar', 'de', 'en', 'es', 'fr', 'hi', 'id', 'ja', 'ko', 'pt-BR', 'ru', 'th', 'tr', 'vi', 'zh-Hans', 'zh-Hant',
    ];
    const keys = Object.values(fixture.ui)
      .filter((ui): ui is { notice: string; continueAction: boolean } => ui !== null)
      .map((ui) => camel(ui.notice));
    expect(keys.sort()).toEqual(['contextOverflow', 'filtered', 'incompleteConnection', 'incompleteOutputLimit']);
    for (const locale of locales) {
      const messages = JSON.parse(readFileSync(path.join(process.cwd(), 'messages', `${locale}.json`), 'utf8'));
      const notice = (messages.pages.chat.replyNotice ?? {}) as Record<string, string>;
      for (const key of keys) {
        const value = notice[key];
        expect({ locale, key, ok: typeof value === 'string' && value.trim().length > 0 }).toEqual({ locale, key, ok: true });
      }
      const continueBtn = messages.pages.chat.recovery.continueBtn;
      expect({ locale, ok: typeof continueBtn === 'string' && continueBtn.length > 0 }).toEqual({ locale, ok: true });
    }
  });
});

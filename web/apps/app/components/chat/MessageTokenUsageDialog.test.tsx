import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { render, screen, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import {
  MessageTokenUsageDialog,
  messageTokenTotal,
  type MessageTokenUsageSnapshot,
} from './MessageTokenUsageDialog';

vi.mock('next-intl', () => ({
  useLocale: () => 'en-US',
  useTranslations: (namespace: string) => (key: string) => {
    const messages: Record<string, string> = {
      'pages.chat.tokenUsage.title': 'Token usage',
      'pages.chat.tokenUsage.subtitle': 'This reply',
      'pages.chat.tokenUsage.input': 'Input',
      'pages.chat.tokenUsage.output': 'Output',
      'pages.chat.tokenUsage.cacheRead': 'Cache read',
      'pages.chat.tokenUsage.cacheWrite': 'Cache write',
      'pages.chat.tokenUsage.total': 'Total',
      'pages.chat.tokenUsage.unavailable': 'No data',
      'pages.chat.tokenUsage.cost': 'Cost',
      'pages.chat.tokenUsage.estimated': 'Estimated',
      'common.close': 'Close',
    };
    return messages[`${namespace}.${key}`] ?? key;
  },
}));

/**
 * Rendering contract of the token usage dialog: three value states (positive, explicit zero,
 * field absent) crossed with card visibility and the total.
 *
 * The main fields (input, output, total) always render, and show the missing-value term when a
 * value cannot be read - that means "the upstream did not report this number", not "this
 * capability is unsupported". Optional fields (cache read and write) omit the whole row when
 * absent.
 */
function renderDialog(usage: MessageTokenUsageSnapshot) {
  return render(<MessageTokenUsageDialog open usage={usage} onClose={vi.fn()} />);
}

/** Pick the input metric card, to assert that the cache sub-rows really are drawn inside it. */
function inputCard(): HTMLElement {
  const label = screen.getByText('Input');
  const card = label.closest('div');
  if (!card) throw new Error('input metric card not found');
  return card;
}

describe('MessageTokenUsageDialog', () => {
  it('renders cache read and write inside the input card rather than as sibling cards of equal weight', () => {
    renderDialog({
      inputTokens: 12_480,
      outputTokens: 856,
      cachedInputTokens: 9_216,
      cacheCreationInputTokens: 128,
    });

    const card = inputCard();
    // Key structural assertion: both entries must sit inside the input card's DOM subtree. Laying
    // them out as sibling cards fails here, and that layout is exactly what invites users to add
    // four numbers up and get a total that does not match.
    expect(within(card).getByText('Cache read')).not.toBeNull();
    expect(within(card).getByText('Cache write')).not.toBeNull();
    expect(within(card).getByText('9,216')).not.toBeNull();
    expect(within(card).getByText('128')).not.toBeNull();

    // Cache entries must not leak into the output card.
    const outputCard = screen.getByText('Output').closest('div')!;
    expect(within(outputCard).queryByText('Cache read')).toBeNull();
  });

  it('still renders an explicit 0 reported by the upstream as 0', () => {
    renderDialog({ inputTokens: 1_000, outputTokens: 20, cachedInputTokens: 0 });

    const card = inputCard();
    expect(within(card).getByText('Cache read')).not.toBeNull();
    expect(within(card).getByText('0')).not.toBeNull();
    // Only reads were observed, so the write row must not appear out of nowhere.
    expect(screen.queryByText('Cache write')).toBeNull();
  });

  it('omits the whole row when the cache fields are absent, without a placeholder that pretends the data was collected', () => {
    renderDialog({ inputTokens: 1_000, outputTokens: 20 });

    expect(screen.queryByText('Cache read')).toBeNull();
    expect(screen.queryByText('Cache write')).toBeNull();
    // The main fields render as usual.
    expect(screen.getByText('Input')).not.toBeNull();
    expect(screen.getByText('1,000')).not.toBeNull();
  });

  it('shows a "no data" term when a main field is unavailable, not "unsupported"', () => {
    renderDialog({});

    // One placeholder each for input, output and total.
    expect(screen.getAllByText('No data')).toHaveLength(3);
    expect(screen.queryByText('Unavailable')).toBeNull();
  });

  it('requires both input and output for the total, and does not double count cache', () => {
    renderDialog({
      inputTokens: 12_480,
      outputTokens: 856,
      cachedInputTokens: 9_216,
      cacheCreationInputTokens: 128,
    });
    // 12,480 + 856, not 12,480 + 856 + 9,216 + 128.
    expect(screen.getByText('13,336')).not.toBeNull();
  });

  it('messageTokenTotal returns undefined for all three missing combinations', () => {
    expect(messageTokenTotal({ inputTokens: 100, outputTokens: 20 })).toBe(120);
    expect(messageTokenTotal({ inputTokens: 0, outputTokens: 0 })).toBe(0);
    expect(messageTokenTotal({ inputTokens: 100 })).toBeUndefined();
    expect(messageTokenTotal({ outputTokens: 20 })).toBeUndefined();
    expect(messageTokenTotal({})).toBeUndefined();
  });

  it('costRowRendersWithEstimatedTag', () => {
    renderDialog({
      inputTokens: 1_000,
      outputTokens: 20,
      providerKind: 'anthropic',
      estimatedCost: 0.0123,
      costSource: 'localEstimate',
    });

    const label = screen.getByText('Cost');
    const row = label.closest('div');
    if (!row) throw new Error('cost row not found');
    expect(within(row).getByText('Estimated')).not.toBeNull();
    expect(within(row).getByText('$0.01')).not.toBeNull();
  });

  it('opening focuses the non-interactive title, not the close button', () => {
    const raf = vi.spyOn(window, 'requestAnimationFrame').mockImplementation((cb) => {
      cb(0);
      return 0;
    });
    renderDialog({ inputTokens: 10, outputTokens: 2 });
    raf.mockRestore();
    const title = screen.getByRole('heading', { name: 'Token usage' });
    expect(title.getAttribute('tabindex')).toBe('-1');
    expect(document.activeElement).toBe(title);
    expect(document.activeElement).not.toBe(screen.getByRole('button', { name: 'Close' }));
  });
});

describe('token usage sheet styles', () => {
  const css = readFileSync(resolve(__dirname, 'MessageTokenUsageDialog.module.css'), 'utf8');
  const rule = (selector: string) => {
    const match = new RegExp(`(?:^|\\n)${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^}]*)\\}`).exec(css);
    if (!match) throw new Error(`rule ${selector} not found`);
    return match[1];
  };

  it('total number is neutral primary text, not the brand color', () => {
    expect(rule('.total strong')).toMatch(/color:\s*var\(--o-text\);/);
  });

  it('close button uses a logical inset so it sits at the line end in RTL', () => {
    expect(rule('.close')).toMatch(/inset-inline-end:\s*14px/);
    expect(rule('.close')).not.toMatch(/(?:^|\s)right:/);
  });

  it('cost value uses the metric value font family with tabular numerals', () => {
    const family = /font-family:\s*([^;]+);/.exec(rule('.metricValue'))?.[1];
    expect(family).toBeTruthy();
    expect(rule('.costValue')).toContain(`font-family: ${family};`);
    expect(rule('.costValue')).toMatch(/font-variant-numeric:\s*tabular-nums;/);
  });

  it('total row shares the 16px inline padding of the metric and cost cards', () => {
    expect(rule('.total')).toMatch(/padding:\s*18px 16px 0;/);
    expect(rule('.metric')).toMatch(/padding:\s*16px;/);
    expect(rule('.cost')).toMatch(/padding:\s*14px 16px;/);
  });
});

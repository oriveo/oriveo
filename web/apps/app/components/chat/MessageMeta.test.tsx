import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { MessageMeta } from './MessageMeta';

vi.mock('next-intl', () => ({
  useLocale: () => 'en-US',
  useTranslations: (namespace: string) => (key: string, values?: { owner?: string }) => {
    const messages: Record<string, string> = {
      'pages.chat.copy': 'Copy',
      'pages.chat.copied': 'Copied',
      'pages.chat.saveAsNote': 'Save as Note',
      'pages.chat.crosscheckAction': 'Cross-check with another model',
      'pages.chat.tokenUsage.title': 'Token usage',
      'pages.chat.tokenUsage.subtitle': 'This model request',
      'pages.chat.tokenUsage.input': 'Input',
      'pages.chat.tokenUsage.output': 'Output',
      'pages.chat.tokenUsage.cacheRead': 'Cache read',
      'pages.chat.tokenUsage.cacheWrite': 'Cache write',
      'pages.chat.tokenUsage.total': 'Total',
      'pages.chat.tokenUsage.unavailable': 'Unavailable',
      'pages.chat.capabilityResult.web': 'Web',
      'pages.chat.capabilityResult.requested': '{owner}: requested',
      'pages.chat.capabilityResult.observed': '{owner}: used',
      'contextMenu.regenerate': 'Regenerate',
      'sidebar.more': 'More',
      'common.close': 'Close',
    };
    return (messages[`${namespace}.${key}`] ?? key).replace('{owner}', values?.owner ?? '{owner}');
  },
}));

describe('MessageMeta', () => {
  const renderMeta = (props?: Partial<Parameters<typeof MessageMeta>[0]>) => render(
    <MessageMeta
      providerName="OpenAI"
      modelName="GPT-4o"
      estimatedCost={0}
      copied={false}
      onCopy={vi.fn()}
      onRetry={vi.fn()}
      onSaveNote={vi.fn()}
      onCrosscheck={vi.fn()}
      tokenUsage={{ inputTokens: 1200, outputTokens: 300, cachedInputTokens: 800, cacheCreationInputTokens: 40 }}
      {...props}
    />,
  );

  it('keeps copy and Save as Note visible while moving regenerate and cross-check into More', () => {
    const onRetry = vi.fn();
    const onSaveNote = vi.fn();
    const onCrosscheck = vi.fn();

    renderMeta({ onRetry, onSaveNote, onCrosscheck });

    const copyButton = screen.getByRole('button', { name: 'Copy' });
    expect(copyButton.getAttribute('aria-label')).toBe('Copy');

    const saveButton = screen.getByRole('button', { name: 'Save as Note' });
    expect(saveButton.textContent).toContain('Save as Note');

    expect(screen.queryByRole('button', { name: 'Regenerate' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Cross-check with another model' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'More' }));

    fireEvent.click(screen.getByRole('menuitem', { name: 'Regenerate' }));
    expect(onRetry).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: 'More' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Cross-check with another model' }));
    expect(onCrosscheck).toHaveBeenCalledTimes(1);
  });

  it('shows the actual tiny cost in conversation details without a less-than sign', () => {
    renderMeta({ estimatedCost: 0.00002 });

    expect(screen.getByText('$0.00002')).not.toBeNull();
    expect(screen.queryByText(/</)).toBeNull();
  });

  it('renders persisted capability execution facts as compact localized pills', () => {
    renderMeta({ capabilityResults: [{ owner: 'web', state: 'observed', source: 'provider_recipe', revision: 'r3' }] });
    expect(screen.getByText('Web: used')).not.toBeNull();
  });

  it('renders a final-wire requested fact while the stream is in flight', () => {
    renderMeta({ capabilityResults: [{ owner: 'web', state: 'requested', source: 'provider_recipe', revision: 'r3' }] });
    expect(screen.getByText('Web: requested')).not.toBeNull();
  });

  it('closes the More menu on Escape and restores focus to More', () => {
    renderMeta();

    const moreButton = screen.getByRole('button', { name: 'More' });
    moreButton.focus();
    fireEvent.click(moreButton);

    expect(document.activeElement).toBe(screen.getByRole('menuitem', { name: /Token usage/ }));

    fireEvent.keyDown(document, { key: 'Escape' });

    expect(screen.queryByRole('menu')).toBeNull();
    expect(document.activeElement).toBe(moreButton);
  });

  it('moves focus through More menu items with arrow, Home, and End keys', () => {
    renderMeta();

    fireEvent.click(screen.getByRole('button', { name: 'More' }));

    const regenerateItem = screen.getByRole('menuitem', { name: 'Regenerate' });
    const crosscheckItem = screen.getByRole('menuitem', { name: 'Cross-check with another model' });
    const usageItem = screen.getByRole('menuitem', { name: /Token usage/ });

    expect(document.activeElement).toBe(usageItem);

    fireEvent.keyDown(usageItem, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(regenerateItem);

    fireEvent.keyDown(regenerateItem, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(crosscheckItem);

    fireEvent.keyDown(crosscheckItem, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(usageItem);

    fireEvent.keyDown(usageItem, { key: 'ArrowUp' });
    expect(document.activeElement).toBe(crosscheckItem);

    fireEvent.keyDown(crosscheckItem, { key: 'Home' });
    expect(document.activeElement).toBe(usageItem);

    fireEvent.keyDown(usageItem, { key: 'End' });
    expect(document.activeElement).toBe(crosscheckItem);
  });

  it('portals the More menu to document.body with fixed positioning so the composer overlay cannot cover it', () => {
    renderMeta();

    fireEvent.click(screen.getByRole('button', { name: 'More' }));

    const menu = screen.getByRole('menu');
    // It must portal to body, or it gets buried in the stacking context of the message list or the input bar, where the frosted input bar covers it near the bottom and clicks fall through.
    expect(menu.parentElement).toBe(document.body);
    expect((menu as HTMLElement).style.position).toBe('fixed');
  });

  it('closes the More menu when clicking outside and avoids a hard-coded English group label', () => {
    const { container } = renderMeta();

    fireEvent.click(screen.getByRole('button', { name: 'More' }));
    expect(screen.getByRole('menu')).not.toBeNull();

    fireEvent.pointerDown(document.body);

    expect(screen.queryByRole('menu')).toBeNull();
    expect(container.querySelector('[aria-label="message actions"]')).toBeNull();
  });

  it('opens token usage details and does not double-count cache tokens in total', () => {
    renderMeta();

    fireEvent.click(screen.getByRole('button', { name: 'More' }));
    fireEvent.click(screen.getByRole('menuitem', { name: /Token usage/ }));

    expect(screen.getByRole('heading', { name: 'Token usage' })).not.toBeNull();
    expect(screen.getByText('1,500')).not.toBeNull();
    expect(screen.getByText('800')).not.toBeNull();
    expect(screen.getByText('40')).not.toBeNull();
  });

  it('hides unobservable cache metrics but keeps an explicitly observed zero', () => {
    const { unmount } = renderMeta({
      tokenUsage: { inputTokens: 1200, outputTokens: 300 },
    });
    fireEvent.click(screen.getByRole('button', { name: 'More' }));
    fireEvent.click(screen.getByRole('menuitem', { name: /Token usage/ }));
    expect(screen.queryByText('Cache read')).toBeNull();
    expect(screen.queryByText('Cache write')).toBeNull();

    unmount();
    renderMeta({
      tokenUsage: { inputTokens: 1200, outputTokens: 300, cachedInputTokens: 0 },
    });
    fireEvent.click(screen.getByRole('button', { name: 'More' }));
    fireEvent.click(screen.getByRole('menuitem', { name: /Token usage/ }));
    expect(screen.getByText('Cache read')).not.toBeNull();
    expect(screen.queryByText('Cache write')).toBeNull();
    expect(screen.getByText('0')).not.toBeNull();
  });
});

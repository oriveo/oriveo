import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { QuoteContextChip } from './QuoteContextChip';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => ({
    quoteSelectedContent: 'Selected content',
    quoteFullContext: 'Full quoted context',
    quoteRemove: 'Remove quote',
  }[key] ?? key),
}));

const quoteContext = {
  schemaVersion: 1 as const,
  sourceMessageId: 'source-1',
  sourceRole: 'assistant' as const,
  contentKind: 'prose' as const,
  leadingText: 'Before ',
  selectedText: 'the exact selection',
  trailingText: ' after',
  contextTruncated: false,
};

describe('QuoteContextChip', () => {
  it('renders a single-line summary and opens a scrollable preview with exact highlight', () => {
    render(<QuoteContextChip quoteContext={quoteContext} presentation="composer" />);
    fireEvent.click(screen.getByRole('button', { name: /Selected content/ }));
    const dialog = screen.getByRole('dialog', { name: 'Full quoted context' });
    expect(dialog.querySelector('mark')?.textContent).toBe('the exact selection');
    expect(dialog.textContent).toContain('Before the exact selection after');
  });

  it('supports Escape, outside click, and an accessible 44px remove action', () => {
    const onRemove = vi.fn();
    render(
      <div>
        <QuoteContextChip quoteContext={quoteContext} presentation="composer" onRemove={onRemove} />
        <button type="button">Outside</button>
      </div>,
    );
    const main = screen.getByRole('button', { name: /Selected content/ });
    fireEvent.click(main);
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('dialog')).toBeNull();

    fireEvent.click(main);
    fireEvent.pointerDown(screen.getByRole('button', { name: 'Outside' }));
    expect(screen.queryByRole('dialog')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Remove quote' }));
    expect(onRemove).toHaveBeenCalledOnce();
  });

  it('uses a distinct sent presentation without a remove action', () => {
    const { container } = render(<QuoteContextChip quoteContext={quoteContext} presentation="sent" />);
    expect(container.querySelector('[data-presentation="sent"]')).not.toBeNull();
    expect(screen.queryByRole('button', { name: 'Remove quote' })).toBeNull();
  });
});

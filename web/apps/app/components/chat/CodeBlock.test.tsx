import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { CodeBlock } from './CodeBlock';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => {
    const messages: Record<string, string> = {
      copied: 'Copied',
      copyCode: 'Copy code',
      copyFailed: 'Copy failed',
      copyPlainText: 'Copy plain text',
      saveAsNote: 'Save as Note',
    };
    return messages[key] ?? key;
  },
}));

vi.mock('../ContextMenu', () => ({
  ContextMenu: () => null,
  useContextMenu: () => ({
    menu: null,
    handleContextMenu: vi.fn(),
    closeMenu: vi.fn(),
  }),
}));

describe('CodeBlock', () => {
  it('renders Save as Note as visible button text when note capture is available', () => {
    render(
      <CodeBlock
        language="ts"
        plainText="const answer = 42;"
        onSaveNote={vi.fn()}
      />,
    );

    const saveButton = screen.getByRole('button', { name: 'Save as Note' });
    expect(saveButton.textContent).toContain('Save as Note');
  });

  it('saves code blocks as fenced markdown from the visible Save as Note action', () => {
    const onSaveNote = vi.fn();

    render(
      <CodeBlock
        language="ts"
        plainText="const answer = 42;"
        onSaveNote={onSaveNote}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Save as Note' }));

    expect(onSaveNote).toHaveBeenCalledWith('```ts\nconst answer = 42;\n```');
  });
});

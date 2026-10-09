import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AttachmentSizeLimitDialog } from './AttachmentSizeLimitDialog';

const en = JSON.parse(readFileSync(resolve(process.cwd(), 'messages/en.json'), 'utf8')) as {
  pages: { chat: Record<string, string> };
};

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    en.pages.chat[key]!.replace(/\{(\w+)\}/g, (_placeholder, name: string) => String(values?.[name] ?? `{${name}}`)),
}));

describe('AttachmentSizeLimitDialog', () => {
  afterEach(cleanup);

  it('states the limit the app actually enforces and leaves no placeholder unfilled', () => {
    render(<AttachmentSizeLimitDialog open onClose={() => {}} />);

    const message = screen.getByRole('alertdialog').querySelector('#attachment-size-limit-message')!.textContent!;
    expect(message).toContain('over 50 MB');
    expect(message).not.toMatch(/\{\w+\}/);
  });
});

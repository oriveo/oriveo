import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { EditApiKeyDialog } from './EditApiKeyDialog';

// Stable reference: a new function on every render would repeatedly trigger effects that depend on t.
const intl = vi.hoisted(() => ({
  t: (key: string, values?: Record<string, unknown>) => (values ? `${key}(${JSON.stringify(values)})` : key),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => intl.t,
  useLocale: () => 'en',
}));

// Masked = native type=password, plain text = type=text; the -webkit-text-security class is no longer used.
function isMasked(input: HTMLInputElement): boolean {
  expect(input.classList.contains('secretMasked')).toBe(false);
  expect(['password', 'text']).toContain(input.type);
  return input.type === 'password';
}

function expectSecretContract(input: HTMLInputElement) {
  expect(input.getAttribute('autocomplete')).toBe('off');
  expect(input.hasAttribute('data-1p-ignore')).toBe(true);
  expect(input.getAttribute('data-lpignore')).toBe('true');
  expect(input.hasAttribute('data-bwignore')).toBe(true);
}

describe('Official provider key-replacement field is masked by default and visible after toggling the eye', () => {
  it('the new key is masked by default, the eye reveals it as plain text, and clicking again masks it', () => {
    render(<EditApiKeyDialog currentKeyPreview="9Zc2" onSave={() => undefined} onCancel={() => undefined} />);
    const input = screen.getByLabelText('editApiKey', { selector: 'input' }) as HTMLInputElement;
    fireEvent.change(input, { target: { value: 'sk-official-demo-0123456789' } });
    expectSecretContract(input);
    expect(isMasked(input)).toBe(true);

    fireEvent.click(screen.getByRole('button', { name: 'showKey' }));
    expect(isMasked(input)).toBe(false);

    fireEvent.click(screen.getByRole('button', { name: 'hideKey' }));
    expect(isMasked(input)).toBe(true);
  });
});

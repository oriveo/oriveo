import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { ModelTrigger } from './ModelTrigger';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

describe('ModelTrigger', () => {
  it('appends the caller className after the shared trigger class', () => {
    render(<ModelTrigger modelName="GPT-5.4" className="tryTrigger" />);
    const button = screen.getByRole('button', { name: 'switchModel' });
    expect(button.classList.contains('tryTrigger')).toBe(true);
    expect(button.classList.length).toBeGreaterThan(1);
  });

  it('keeps the default class list when no className is given', () => {
    render(<ModelTrigger modelName="GPT-5.4" />);
    const button = screen.getByRole('button', { name: 'switchModel' });
    expect(button.className).not.toContain('undefined');
    expect(button.className.trim()).not.toBe('');
  });

  it('isolates the model name as an LTR run', () => {
    render(<ModelTrigger modelName="GPT-5.4" />);
    const name = screen.getByText('GPT-5.4');
    expect(name.tagName).toBe('BDI');
    expect(name.getAttribute('dir')).toBe('ltr');
  });

  it('shows the select prompt without a bdi wrapper when no model is set', () => {
    const { container } = render(<ModelTrigger />);
    expect(screen.getByText('selectModel')).toBeTruthy();
    expect(container.querySelector('bdi')).toBeNull();
  });
});

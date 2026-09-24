import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { BackupPasswordInput } from './BackupPasswordInput';

// The real @oriveo/ui Input and eye icons; the test setup replaces next-intl with a mock that returns the key as is.
describe('BackupPasswordInput', () => {
  it('starts masked and toggles between masked and plain text with a state-aware label', () => {
    render(<BackupPasswordInput placeholder="passwordPlaceholder" value="secret-123" onChange={() => {}} />);

    const input = screen.getByPlaceholderText('passwordPlaceholder') as HTMLInputElement;
    expect(input.type).toBe('password');

    fireEvent.click(screen.getByRole('button', { name: 'showCharacters' }));
    expect(input.type).toBe('text');
    expect(screen.queryByRole('button', { name: 'showCharacters' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'hideCharacters' }));
    expect(input.type).toBe('password');
    expect(screen.getByRole('button', { name: 'showCharacters' })).toBeTruthy();
  });

  it('keeps the toggle out of form submission and the input value untouched', () => {
    const onChange = () => {};
    render(<BackupPasswordInput placeholder="p" value="abc" onChange={onChange} />);

    const toggle = screen.getByRole('button', { name: 'showCharacters' }) as HTMLButtonElement;
    expect(toggle.type).toBe('button');
    fireEvent.click(toggle);
    expect((screen.getByPlaceholderText('p') as HTMLInputElement).value).toBe('abc');
  });
});

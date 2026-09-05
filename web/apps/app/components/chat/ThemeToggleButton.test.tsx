import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ThemeToggleButton } from './ThemeToggleButton';

const { mockUpdateTheme, mockGetVanillaStore, mockUseAppStore, mockUseIsDarkTheme } = vi.hoisted(() => ({
  mockUpdateTheme: vi.fn(),
  mockGetVanillaStore: vi.fn(() => ({ id: 'store' })),
  mockUseAppStore: vi.fn((selector: (state: { preferences: { theme: 'system' | 'light' | 'dark' } }) => unknown) =>
    selector({ preferences: { theme: 'system' } }),
  ),
  mockUseIsDarkTheme: vi.fn(),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => {
    const labels: Record<string, string> = {
      themeLight: 'Light',
      themeDark: 'Dark',
    };
    return labels[key] ?? key;
  },
}));

vi.mock('../../providers/StoreProvider', () => ({
  getVanillaStore: () => mockGetVanillaStore(),
  useAppStore: (selector: (state: { preferences: { theme: 'system' | 'light' | 'dark' } }) => unknown) =>
    mockUseAppStore(selector),
}));

vi.mock('../../lib/core/preference-ops', () => ({
  updateTheme: (...args: unknown[]) => mockUpdateTheme(...args),
}));

vi.mock('../../lib/hooks/useIsDarkTheme', () => ({
  useIsDarkTheme: () => mockUseIsDarkTheme(),
}));

describe('ThemeToggleButton', () => {
  beforeEach(() => {
    mockUpdateTheme.mockReset();
    mockGetVanillaStore.mockClear();
    mockUseAppStore.mockImplementation((selector) =>
      selector({ preferences: { theme: 'system' } }),
    );
    mockUseIsDarkTheme.mockReturnValue(false);
  });

  it('switches to dark when the resolved theme is light', () => {
    render(<ThemeToggleButton />);

    fireEvent.click(screen.getByRole('button', { name: 'Dark' }));

    expect(mockUpdateTheme).toHaveBeenCalledWith({ id: 'store' }, 'dark');
  });

  it('switches to light when the resolved theme is dark', () => {
    mockUseIsDarkTheme.mockReturnValue(true);

    render(<ThemeToggleButton />);

    fireEvent.click(screen.getByRole('button', { name: 'Light' }));

    expect(mockUpdateTheme).toHaveBeenCalledWith({ id: 'store' }, 'light');
  });
});

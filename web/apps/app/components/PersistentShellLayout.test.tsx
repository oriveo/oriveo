import type { ReactNode } from 'react';
import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { PersistentShellLayout } from './PersistentShellLayout';

const mocks = vi.hoisted(() => ({
  pathname: '/chat',
  showToast: vi.fn(),
}));

vi.mock('next/navigation', () => ({
  usePathname: () => mocks.pathname,
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: { param?: string }) =>
    key === 'generationParameterSelfHealed'
      ? `This model rejected ${values?.param}. Retried with its default setting.`
      : key,
}));

vi.mock('./AppShellWrapper', () => ({
  AppShellWrapper: ({ children }: { children: ReactNode }) => (
    <div data-testid="app-shell-wrapper">{children}</div>
  ),
}));

vi.mock('./Toast', () => ({
  ToastContainer: () => <div data-testid="toast-container" />,
  showToast: (...args: unknown[]) => mocks.showToast(...args),
}));

vi.mock('./ServiceReachabilityBanner', () => ({
  ServiceReachabilityBanner: () => <div data-testid="reachability-banner" />,
}));

describe('PersistentShellLayout', () => {
  beforeEach(() => {
    mocks.pathname = '/chat';
    mocks.showToast.mockReset();
  });

  it('keeps regular app routes inside the app shell', () => {
    render(
      <PersistentShellLayout>
        <div>Inner Content</div>
      </PersistentShellLayout>,
    );

    expect(screen.getByTestId('app-shell-wrapper')).toBeTruthy();
    expect(screen.getByText('Inner Content')).toBeTruthy();
  });

  it('renders welcome without the sidebar shell', () => {
    mocks.pathname = '/welcome';

    render(
      <PersistentShellLayout>
        <div>Welcome Content</div>
      </PersistentShellLayout>,
    );

    expect(screen.queryByTestId('app-shell-wrapper')).toBeNull();
    expect(screen.getByText('Welcome Content')).toBeTruthy();
    expect(screen.getByTestId('toast-container')).toBeTruthy();
    expect(screen.getByTestId('reachability-banner')).toBeTruthy();
  });

  it('shows a localized warning after a parameter self-heals', () => {
    render(
      <PersistentShellLayout>
        <div>Inner Content</div>
      </PersistentShellLayout>,
    );

    window.dispatchEvent(new CustomEvent('oriveo:unsupported-param-self-healed', {
      detail: { param: 'top_p' },
    }));

    expect(mocks.showToast).toHaveBeenCalledWith(
      'This model rejected top_p. Retried with its default setting.',
      5000,
      undefined,
      'warning',
    );
  });
});

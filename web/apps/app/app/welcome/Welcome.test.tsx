import type { ReactNode } from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Welcome } from './Welcome';

type MockState = {
  hasCompletedOnboarding: boolean;
  providers: Array<{ id: string }>;
  setHasCompletedOnboarding: (value: boolean) => void;
};

let mockState: MockState;
const mocks = vi.hoisted(() => ({
  replace: vi.fn(),
  push: vi.fn(),
  resolveEntryRoute: vi.fn(),
  trackEvent: vi.fn(),
  setHasCompletedOnboarding: vi.fn(),
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: mocks.push,
    replace: mocks.replace,
  }),
}));

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
}));

vi.mock('../../lib/utils/entry-route', () => ({
  resolveEntryRoute: mocks.resolveEntryRoute,
}));

vi.mock('../../lib/core/telemetry', () => ({
  trackEvent: (...args: unknown[]) => mocks.trackEvent(...args),
}));

vi.mock('./LocaleMenu', () => ({
  LocaleMenu: () => <div data-testid="locale-menu" />,
}));

vi.mock('../../components/ThemeToggle', () => ({
  ThemeToggle: () => <div data-testid="theme-toggle" />,
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({ children, onClick, disabled }: { children: ReactNode; onClick?: () => void; disabled?: boolean }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
  OriveoLogo: ({ size }: { size?: number }) => (
    <span data-testid="oriveo-logo" data-size={size} />
  ),
}));

describe('Welcome', () => {
  beforeEach(() => {
    mockState = {
      hasCompletedOnboarding: false,
      providers: [],
      setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
    };
    mocks.push.mockReset();
    mocks.replace.mockReset();
    mocks.resolveEntryRoute.mockReset();
    mocks.trackEvent.mockReset();
    mocks.setHasCompletedOnboarding.mockReset();
    mocks.resolveEntryRoute.mockReturnValue('/chat');
  });

  it('offers both entry points and never redirects on its own', () => {
    render(<Welcome />);

    expect(mocks.replace).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'addProvider' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'enterHome' })).toBeTruthy();
  });

  it('reports the welcome step once, even across re-renders', () => {
    const { rerender } = render(<Welcome />);
    rerender(<Welcome />);

    const stepEvents = mocks.trackEvent.mock.calls.filter(([name]) => name === 'onboarding_step_viewed');
    expect(stepEvents).toHaveLength(1);
    expect(stepEvents[0][1]).toMatchObject({ step: 'welcome', step_index: 0 });
  });

  it('sends the primary action to provider setup and marks onboarding complete', () => {
    render(<Welcome />);
    fireEvent.click(screen.getByRole('button', { name: 'addProvider' }));

    expect(mocks.push).toHaveBeenCalledWith('/providers/new');
    expect(mocks.setHasCompletedOnboarding).toHaveBeenCalledWith(true);
    expect(mocks.trackEvent).toHaveBeenCalledWith(
      'onboarding_completed',
      expect.objectContaining({ source: 'byok_providers', skipped_provider_setup: true }),
    );
  });

  it('resolves the entry route from the current provider count when entering the app', () => {
    mockState.providers = [{ id: 'provider-1' }];
    mocks.resolveEntryRoute.mockReturnValue('/chat');

    render(<Welcome />);
    fireEvent.click(screen.getByRole('button', { name: 'enterHome' }));

    expect(mocks.resolveEntryRoute).toHaveBeenCalledWith({
      hasCompletedOnboarding: true,
      providerCount: 1,
    });
    expect(mocks.replace).toHaveBeenCalledWith('/chat');
    expect(mocks.trackEvent).toHaveBeenCalledWith(
      'onboarding_completed',
      expect.objectContaining({ source: 'enter_home', skipped_provider_setup: false }),
    );
  });

  it('completes onboarding only once no matter how many actions are taken', () => {
    render(<Welcome />);
    fireEvent.click(screen.getByRole('button', { name: 'addProvider' }));
    fireEvent.click(screen.getByRole('button', { name: 'enterHome' }));

    expect(mocks.setHasCompletedOnboarding).toHaveBeenCalledTimes(1);
    expect(mocks.trackEvent.mock.calls.filter(([name]) => name === 'onboarding_completed')).toHaveLength(1);
  });
});

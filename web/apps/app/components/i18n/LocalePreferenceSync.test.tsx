// @vitest-environment jsdom
import React from 'react';
import { render } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mockRefresh = vi.fn();
let mockLanguage: string | undefined = 'system';

vi.mock('next/navigation', () => ({
  useRouter: () => ({ refresh: mockRefresh }),
}));

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (s: unknown) => unknown) =>
    selector({ preferences: { language: mockLanguage } }),
}));

import { LocalePreferenceSync } from './LocalePreferenceSync';
import { getLocaleCookie } from '../../lib/i18n/locale-utils';

function setCookie(value: string) {
  document.cookie = `NEXT_LOCALE=${value}; path=/`;
}

describe('LocalePreferenceSync', () => {
  beforeEach(() => {
    mockRefresh.mockClear();
    setCookie('en');
  });

  // Regression: a synced preference pulled preferences.language to zh-Hans while the cookie was
  // still en. The settings page said Simplified Chinese, the UI stayed English, and the user could
  // not fix it by hand: the option to pick was already the selected one, so onChange never fired.
  it('when the preference and the cookie diverge, the preference wins: it writes the cookie back and lets SSR re-render', () => {
    mockLanguage = 'zh-Hans';
    render(<LocalePreferenceSync />);

    expect(getLocaleCookie()).toBe('zh-Hans');
    expect(mockRefresh).toHaveBeenCalledTimes(1);
  });

  it('does not refresh when the cookie already matches, otherwise every mount refreshes for nothing', () => {
    setCookie('ja');
    mockLanguage = 'ja';
    render(<LocalePreferenceSync />);

    expect(mockRefresh).not.toHaveBeenCalled();
  });

  it('system means follow the browser: no cookie write and no refresh', () => {
    mockLanguage = 'system';
    render(<LocalePreferenceSync />);

    expect(getLocaleCookie()).toBe('en');
    expect(mockRefresh).not.toHaveBeenCalled();
  });

  it('handles the same language only once across re-mounts, without refreshing repeatedly', () => {
    mockLanguage = 'de';
    const { rerender } = render(<LocalePreferenceSync />);
    rerender(<LocalePreferenceSync />);

    expect(mockRefresh).toHaveBeenCalledTimes(1);
  });

  it('an unrecognized language tag never touches the cookie', () => {
    mockLanguage = 'kl-GL';
    render(<LocalePreferenceSync />);

    expect(getLocaleCookie()).toBe('en');
    expect(mockRefresh).not.toHaveBeenCalled();
  });
});

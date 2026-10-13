// @vitest-environment jsdom
import React from 'react';
import { render } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mockRefresh = vi.fn();
let mockLanguage: string | undefined = 'system';
// The language the server actually rendered (what the user is looking at).
let mockRenderedLocale = 'en';

vi.mock('next-intl', () => ({
  useLocale: () => mockRenderedLocale,
}));

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
    mockRenderedLocale = 'en';
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
    mockRenderedLocale = 'ja';
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

  // Regression: within one page session the preference went zh-Hans -> system -> zh-Hans.
  // Choosing System writes the cookie as system and the interface returns to English; when the
  // preference comes back to zh-Hans the "zh-Hans was handled" marker is still set, so it was
  // skipped: the dropdown says Simplified Chinese while the interface is English.
  it('the same language coming back after System still brings the interface along', () => {
    mockLanguage = 'zh-Hans';
    const { rerender } = render(<LocalePreferenceSync />);
    expect(mockRefresh).toHaveBeenCalledTimes(1);
    mockRenderedLocale = 'zh-Hans';
    rerender(<LocalePreferenceSync />);

    mockLanguage = 'system';
    setCookie('system');
    mockRenderedLocale = 'en';
    rerender(<LocalePreferenceSync />);

    mockLanguage = 'zh-Hans';
    rerender(<LocalePreferenceSync />);

    expect(getLocaleCookie()).toBe('zh-Hans');
    expect(mockRefresh).toHaveBeenCalledTimes(2);
  });

  // The cookie matches the preference but the interface on screen is another language: the
  // test is the language the user actually sees, not the cookie.
  it('when the cookie already matches but the rendered language does not, SSR still re-renders once', () => {
    setCookie('zh-Hans');
    mockRenderedLocale = 'en';
    mockLanguage = 'zh-Hans';
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

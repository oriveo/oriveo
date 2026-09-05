import { describe, expect, it } from 'vitest';
import {
  isHydrationErrorEvent,
  isIgnorableMobileBrowserInjection,
} from '../ignore-mobile-browser-injection';
import type { SentryEventLike } from '../types';

const hydrationException: SentryEventLike = {
  exception: {
    values: [{ value: "Hydration failed because the server rendered HTML didn't match the client." }],
  },
};

describe('isIgnorableMobileBrowserInjection', () => {
  it('filters Hydration errors from MiuiBrowser via tags', () => {
    const event: SentryEventLike = { ...hydrationException, tags: { 'browser.name': 'MiuiBrowser' } };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  it('filters Hydration errors from UCBrowser via contexts.browser', () => {
    const event: SentryEventLike = {
      ...hydrationException,
      contexts: { browser: { name: 'UCBrowser' } },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  it('filters Hydration errors from HuaweiBrowser via request User-Agent header', () => {
    const event: SentryEventLike = {
      ...hydrationException,
      request: { headers: { 'User-Agent': 'Mozilla/5.0 ... HuaweiBrowser/15.0' } },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  it('filters Hydration errors from Quark via lowercase user-agent header', () => {
    const event: SentryEventLike = {
      ...hydrationException,
      request: { headers: { 'user-agent': 'Mozilla/5.0 ... Quark/7.6.0.123' } },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  it('filters Minified React hydration codes from the normalized QQ Browser display name', () => {
    const event: SentryEventLike = {
      exception: { values: [{ value: 'Minified React error #418' }] },
      tags: { 'browser.name': 'QQ Browser Mobile' },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  it('filters the observed stackless SVG image rejection from QQ Browser Mobile', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            type: 'UnhandledRejection',
            value:
              'Non-Error promise rejection captured with value: Unable to load image data:image/svg+xml;base64,PHN2ZyBhcmlhLWhpZGRlbj0idHJ1ZQ==',
            stacktrace: { frames: [] },
          },
        ],
      },
      tags: { browser: 'QQ Browser Mobile 20.4' },
    };

    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  it('keeps the same SVG image rejection from a normal browser', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            type: 'UnhandledRejection',
            value:
              'Non-Error promise rejection captured with value: Unable to load image data:image/svg+xml;base64,PHN2Zw==',
            stacktrace: { frames: [] },
          },
        ],
      },
      tags: { browser: 'Chrome Mobile 140.0' },
    };

    expect(isIgnorableMobileBrowserInjection(event)).toBe(false);
  });

  it('keeps SVG image rejections with an application stack', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            type: 'UnhandledRejection',
            value:
              'Non-Error promise rejection captured with value: Unable to load image data:image/svg+xml;base64,PHN2Zw==',
            stacktrace: { frames: [{ filename: 'http://localhost:3001/_next/app.js' }] },
          },
        ],
      },
      tags: { browser: 'QQ Browser Mobile 20.4' },
    };

    expect(isIgnorableMobileBrowserInjection(event)).toBe(false);
  });

  it('keeps non-SVG image rejections from injecting browsers', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            type: 'UnhandledRejection',
            value:
              'Non-Error promise rejection captured with value: Unable to load image data:image/png;base64,iVBORw0KGgo=',
            stacktrace: { frames: [] },
          },
        ],
      },
      tags: { browser: 'QQ Browser Mobile 20.4' },
    };

    expect(isIgnorableMobileBrowserInjection(event)).toBe(false);
  });

  it('does not filter Hydration from desktop Chrome', () => {
    const event: SentryEventLike = { ...hydrationException, tags: { 'browser.name': 'Chrome' } };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(false);
  });

  it('does not filter unrelated errors from MiuiBrowser', () => {
    const event: SentryEventLike = {
      exception: { values: [{ value: 'TypeError: foo is not a function' }] },
      tags: { 'browser.name': 'MiuiBrowser' },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(false);
  });

  it('returns false when neither browser nor message matches', () => {
    expect(isIgnorableMobileBrowserInjection({})).toBe(false);
  });

  // Taken from a real event (2026-08-16). Firefox for iOS spoofs its UA as Mobile Safari, so any
  // UA-based gate misses it; the predicate has to key off the browser's private namespace.
  it('filters the Firefox-for-iOS reader-mode injection despite its Safari-spoofed UA', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          type: 'TypeError',
          value: "undefined is not an object (evaluating 'window.__firefox__.reader.checkReadability')",
          stacktrace: {
            frames: [{ filename: 'app:///zh-Hant/chatbox-alternative', function: 'global code' }],
          },
        }],
      },
      tags: { 'browser.name': 'Mobile Safari' },
      contexts: { browser: { name: 'Mobile Safari' } },
      request: {
        headers: {
          'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1',
        },
      },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  // Taken from a real event (2026-08-23). A content-extraction and form-autofill script injected
  // by an in-app WebView failed while calling back into its own `mbrowser` bridge. The UA carries
  // only `wv` and no brand token, Sentry classifies it as "Chrome Mobile WebView", and a brand
  // gate is guaranteed to miss it. Its only frame is the injected script's `<anonymous>`.
  const WEBVIEW_INJECTION_UA =
    'Mozilla/5.0 (Linux; Android 12; ANG-AN00 Build/HUAWEIANG-AN00; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/114.0.5735.196 Mobile Safari/537.36';

  it('filters the Android WebView auto-fill bridge failure despite its brandless wv UA', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          type: 'TypeError',
          value: 'mbrowser.loadAutoFillFormData is not a function',
          stacktrace: { frames: [{ filename: '<anonymous>', function: 'execute_auto_fill' }] },
        }],
      },
      tags: { 'browser.name': 'Chrome Mobile WebView' },
      contexts: { browser: { name: 'Chrome Mobile WebView' } },
      request: { headers: { 'User-Agent': WEBVIEW_INJECTION_UA } },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  it('filters the same host bridge on its page-load callback', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          type: 'TypeError',
          value: 'mbrowser.onPageLoaded is not a function',
          stacktrace: { frames: [{ filename: '<anonymous>' }] },
        }],
      },
      request: { headers: { 'User-Agent': WEBVIEW_INJECTION_UA } },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  // A real event (2026-08-20): an ad SDK inside the Honor browser failed calling native through
  // DSBridge. `honorbrowser` is not in the brand table, so again only the bridge namespace can
  // identify it.
  it('filters the DSBridge ad-SDK failure from an unlisted host browser', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          type: 'TypeError',
          value: '_dsbridge.call is not a function',
          stacktrace: {
            frames: [{ filename: 'app:///AdSdk/1cce1519eb5b4c99b493da57f11f6fc4_20260630102646.js' }],
          },
        }],
      },
      tags: { 'browser.name': 'Honor Browser' },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(true);
  });

  it('KEEPS a real TypeError from our own bundle inside the same WebView', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          type: 'TypeError',
          value: 'browserStore.hydrate is not a function',
          stacktrace: {
            frames: [{ filename: 'app:///_next/static/chunks/be7ef3f5-abc.js' }],
          },
        }],
      },
      tags: { 'browser.name': 'Chrome Mobile WebView' },
      request: { headers: { 'User-Agent': WEBVIEW_INJECTION_UA } },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(false);
  });

  it('KEEPS a real TypeError from our own bundle on the same Safari UA', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          type: 'TypeError',
          value: "undefined is not an object (evaluating 'page.slug')",
          stacktrace: {
            frames: [{ filename: 'http://localhost:3000/_next/static/chunks/app.js' }],
          },
        }],
      },
      tags: { 'browser.name': 'Mobile Safari' },
    };
    expect(isIgnorableMobileBrowserInjection(event)).toBe(false);
  });
});

describe('isHydrationErrorEvent', () => {
  it('matches hydration mismatch regardless of browser (desktop Chrome leaks past mobile filter)', () => {
    const event: SentryEventLike = { ...hydrationException, tags: { 'browser.name': 'Chrome' } };
    // The mobile injection filter lets desktop Chrome through, which is where this noise came from, but the dedicated hydration rule still matches.
    expect(isIgnorableMobileBrowserInjection(event)).toBe(false);
    expect(isHydrationErrorEvent(event)).toBe(true);
  });

  it('matches Minified React hydration codes from message', () => {
    expect(
      isHydrationErrorEvent({ exception: { values: [{ value: 'Minified React error #423' }] } }),
    ).toBe(true);
  });

  it('matches when only event.message is present', () => {
    expect(isHydrationErrorEvent({ message: "Text content does not match server-rendered HTML" })).toBe(
      true,
    );
  });

  it('does not match unrelated runtime errors', () => {
    expect(
      isHydrationErrorEvent({ exception: { values: [{ value: 'TypeError: foo is not a function' }] } }),
    ).toBe(false);
  });

  it('returns false for empty event', () => {
    expect(isHydrationErrorEvent({})).toBe(false);
  });
});

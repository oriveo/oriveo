/* Test setup — mock external modules */

import { afterEach, vi } from 'vitest';
import { cleanup } from '@testing-library/react';

// Application tests exercise code that records telemetry, not Sentry's webpack
// transformer internals. Loading the real Next.js SDK in Vitest 4 crosses its
// CJS/ESM bundler boundary and executes the APM webpack transformer, which is
// neither a production path nor a useful unit-test dependency. Individual
// Sentry contract tests can replace this default mock in their own file.
vi.mock('@sentry/nextjs', () => {
  const scope = {
    setContext: vi.fn(),
    setExtra: vi.fn(),
    setExtras: vi.fn(),
    setFingerprint: vi.fn(),
    setLevel: vi.fn(),
    setTag: vi.fn(),
    setTags: vi.fn(),
    setUser: vi.fn(),
  };
  return {
    addBreadcrumb: vi.fn(),
    browserTracingIntegration: vi.fn(() => ({})),
    captureException: vi.fn(),
    captureMessage: vi.fn(),
    captureRequestError: vi.fn(),
    captureRouterTransitionStart: vi.fn(),
    init: vi.fn(),
    replayIntegration: vi.fn(() => ({})),
    setUser: vi.fn(),
    withScope: vi.fn((callback: (value: typeof scope) => void) => callback(scope)),
    withSentryConfig: vi.fn((config: unknown) => config),
  };
});

// @testing-library auto-cleanup does not take effect with globals:true, so it is registered by
// hand: unmount the render result after each case, or leftover DOM leaks across cases and
// queryByRole matches a node left behind by the previous one.
afterEach(() => {
  cleanup();
});

// Mock next-intl
vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
  useLocale: () => 'en',
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) => children,
  getLocale: () => Promise.resolve('en'),
  getMessages: () => Promise.resolve({}),
}));

// Mock next/navigation
vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: vi.fn(),
    replace: vi.fn(),
    back: vi.fn(),
    prefetch: vi.fn(),
  }),
  usePathname: () => '/',
  useSearchParams: () => new URLSearchParams(),
}));

// Mock crypto.randomUUID
if (!globalThis.crypto) {
  Object.defineProperty(globalThis, 'crypto', {
    value: {
      randomUUID: () => Math.random().toString(36).slice(2) + Date.now().toString(36),
      getRandomValues: <T extends ArrayBufferView>(arr: T) => arr,
      subtle: {} as SubtleCrypto,
    },
  });
}

if (!globalThis.localStorage || typeof globalThis.localStorage.clear !== 'function') {
  const store = new Map<string, string>();
  Object.defineProperty(globalThis, 'localStorage', {
    value: {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => { store.set(key, value); },
      removeItem: (key: string) => { store.delete(key); },
      clear: () => { store.clear(); },
      key: (index: number) => [...store.keys()][index] ?? null,
      get length() { return store.size; },
    },
    configurable: true,
  });
}

// jsdom does not implement matchMedia. A complete mock (both the old and the new listener API) is
// installed unconditionally: setupFiles runs before every test file, so this also clears the
// pollution of a partial matchMedia (one without addEventListener) installed by an individual
// test, which would otherwise crash components that depend on prefers-color-scheme such as
// useIsDarkTheme.
//
// The window guard is required: setupFiles runs for every test file, including server-side cases
// using `// @vitest-environment node` (Next.js API routes). There is no window there, and an
// unguarded access would fail the whole file with a ReferenceError during setup.
if (typeof window !== 'undefined') {
  Object.defineProperty(window, 'matchMedia', {
    writable: true,
    configurable: true,
    value: (query: string) => ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }),
  });
}

import { describe, expect, it } from 'vitest';
import { isIgnorableBrowserExtensionError } from '../ignore-browser-extension-noise';
import type { SentryEventLike } from '../types';

describe('isIgnorableBrowserExtensionError', () => {
  it('filters addListener errors from injected blob scripts', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          value: "Cannot read properties of undefined (reading 'addListener')",
          stacktrace: {
            frames: [
              { filename: 'blob:app:///6c141a31-b8d8-4c5d-bdba-d9e779a1e77a' },
            ],
          },
        }],
      },
    };

    expect(isIgnorableBrowserExtensionError(event)).toBe(true);
  });

  it('filters errors from chrome-extension stack frames', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          value: "Cannot read property 'addListener' of undefined",
          stacktrace: {
            frames: [
              { filename: 'chrome-extension://abcdefgh/content.js' },
            ],
          },
        }],
      },
    };

    expect(isIgnorableBrowserExtensionError(event)).toBe(true);
  });

  it('does not filter app bundle errors with the same message', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          value: "Cannot read properties of undefined (reading 'addListener')",
          stacktrace: {
            frames: [
              { filename: 'app:///_next/static/chunks/app.js' },
            ],
          },
        }],
      },
    };

    expect(isIgnorableBrowserExtensionError(event)).toBe(false);
  });

  it('does not filter unrelated blob script errors', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          value: "Cannot read properties of undefined (reading 'removeChild')",
          stacktrace: {
            frames: [
              { filename: 'blob:app:///6c141a31-b8d8-4c5d-bdba-d9e779a1e77a' },
            ],
          },
        }],
      },
    };

    expect(isIgnorableBrowserExtensionError(event)).toBe(false);
  });

  it('filters M_ID failures from injected app executor scripts', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          value: "Cannot read properties of undefined (reading 'M_ID')",
          stacktrace: {
            frames: [
              { filename: 'app:///executors/200.js', function: 'F' },
            ],
          },
        }],
      },
    };

    expect(isIgnorableBrowserExtensionError(event)).toBe(true);
  });

  it('does not filter M_ID failures from a Next.js application bundle', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          value: "Cannot read properties of undefined (reading 'M_ID')",
          stacktrace: {
            frames: [
              { filename: 'app:///_next/static/chunks/app/blog/page.js' },
            ],
          },
        }],
      },
    };

    expect(isIgnorableBrowserExtensionError(event)).toBe(false);
  });

  it('falls back to abs_path when filename is missing', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{
          value: "Cannot read properties of undefined (reading 'addListener')",
          stacktrace: {
            frames: [
              { abs_path: 'moz-extension://uuid/content.js' },
            ],
          },
        }],
      },
    };

    expect(isIgnorableBrowserExtensionError(event)).toBe(true);
  });
});

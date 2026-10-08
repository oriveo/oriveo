import { describe, expect, it } from 'vitest';
import {
  isErrorThrownEntirelyByBrowserExtension,
  isIgnorableBrowserExtensionError,
} from '../ignore-browser-extension-noise';
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

function errorWithStack(message: string, stack: string, cause?: unknown): Error {
  const error = new Error(message);
  error.stack = stack;
  if (cause !== undefined) (error as Error & { cause?: unknown }).cause = cause;
  return error;
}

describe('isErrorThrownEntirelyByBrowserExtension', () => {
  const EXT = 'chrome-extension://nkbihfbeogaeaoehlefnkodbefgpgknn/scripts/inpage.js';

  it('drops a wallet inpage script rejecting with a cause chain', () => {
    const cause = errorWithStack(
      'MetaMask extension not found',
      `Error: MetaMask extension not found\n    at ${EXT}:4:42708`,
    );
    const outer = errorWithStack(
      'Failed to connect to MetaMask',
      `i: Failed to connect to MetaMask\n    at Object.connect (${EXT}:7:84292)\n    at async ${EXT}:7:90001`,
      cause,
    );
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: outer })).toBe(true);
  });

  it('does not depend on the message: any extension-only stack is dropped', () => {
    const error = errorWithStack(
      'x is not a function',
      `TypeError: x is not a function\n    at new Promise (<anonymous>)\n    at t (${EXT}:1:2)`,
    );
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: error })).toBe(true);
  });

  it('recognises Firefox, Safari and blob-backed extension frames', () => {
    for (const stack of [
      'connect@moz-extension://0a1b2c3d-uuid/inpage.js:7:1\n@moz-extension://0a1b2c3d-uuid/inpage.js:9:3',
      'connect@safari-web-extension://ABCDEF/inpage.js:7:1\npromiseReactionJob@[native code]',
      'global code@webkit-masked-url://hidden/:1:1',
      'Error: boom\n    at run (blob:chrome-extension://abcdefgh/6c141a31-b8d8:1:1)',
    ]) {
      expect(isErrorThrownEntirelyByBrowserExtension({ originalException: errorWithStack('boom', stack) })).toBe(true);
    }
  });

  it('keeps errors whose stack touches a page script, in either direction', () => {
    const extensionCallsUs = errorWithStack(
      'boom',
      `Error: boom\n    at handler (https://app.example.com/_next/static/chunks/app.js:1:1)\n    at dispatch (${EXT}:1:2)`,
    );
    const weCallExtension = errorWithStack(
      'boom',
      `Error: boom\n    at wrapped (${EXT}:1:2)\n    at send (https://app.example.com/_next/static/chunks/app.js:1:1)`,
    );
    const pageBlob = errorWithStack('boom', 'Error: boom\n    at run (blob:https://app.example.com/6c141a31:1:1)');
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: extensionCallsUs })).toBe(false);
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: weCallExtension })).toBe(false);
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: pageBlob })).toBe(false);
  });

  it('keeps an extension error whose cause was thrown by the page', () => {
    const cause = errorWithStack('ours', 'Error: ours\n    at f (https://app.example.com/_next/static/chunks/app.js:1:1)');
    const outer = errorWithStack('wrapped', `Error: wrapped\n    at g (${EXT}:1:2)`, cause);
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: outer })).toBe(false);
  });

  it('ignores extension URLs that only appear in the message line', () => {
    const error = errorWithStack(
      `Refused to load ${EXT}`,
      `Error: Refused to load ${EXT}\n    at f (https://app.example.com/_next/static/chunks/app.js:1:1)`,
    );
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: error })).toBe(false);
  });

  it('abstains when there is no usable stack', () => {
    expect(isErrorThrownEntirelyByBrowserExtension(undefined)).toBe(false);
    expect(isErrorThrownEntirelyByBrowserExtension({})).toBe(false);
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: 'MetaMask extension not found' })).toBe(false);
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: { message: 'no stack' } })).toBe(false);
    expect(
      isErrorThrownEntirelyByBrowserExtension({
        originalException: errorWithStack('native', 'Error: native\n    at new Promise (<anonymous>)'),
      }),
    ).toBe(false);
  });

  it('terminates on a cyclic cause chain', () => {
    const error = errorWithStack('loop', `Error: loop\n    at f (${EXT}:1:1)`);
    (error as Error & { cause?: unknown }).cause = error;
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: error })).toBe(true);
  });
});

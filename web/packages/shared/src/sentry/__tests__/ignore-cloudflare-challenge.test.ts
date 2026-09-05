import { describe, expect, it } from 'vitest';
import { isIgnorableCloudflareChallengeError } from '../ignore-cloudflare-challenge';
import type { SentryEventLike } from '../types';

describe('isIgnorableCloudflareChallengeError', () => {
  it('filters the Safari contentWindow TypeError from the CF inline loader', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            value: "null is not an object (evaluating 'a.contentWindow.document')",
            stacktrace: {
              frames: [
                { filename: 'app:///_next/static/chunks/205-88e6984e311de9bb.js' },
                { filename: 'app:///privacy' },
              ],
            },
          },
        ],
      },
    };
    expect(isIgnorableCloudflareChallengeError(event)).toBe(true);
  });

  it('filters generic messages mentioning contentWindow.document', () => {
    const event: SentryEventLike = {
      exception: {
        values: [{ value: "TypeError: Cannot read properties of null (reading 'document') at a.contentWindow.document" }],
      },
    };
    expect(isIgnorableCloudflareChallengeError(event)).toBe(true);
  });

  it('filters the Chromium null document variant from the CF inline loader', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            value: "Cannot read properties of null (reading 'document')",
            stacktrace: {
              frames: [
                {
                  filename: 'app:///ar/account-deletion',
                  function: 'HTMLDocument.c',
                },
              ],
            },
          },
        ],
      },
    };
    expect(isIgnorableCloudflareChallengeError(event)).toBe(true);
  });

  it('filters errors whose stack contains a /cdn-cgi/ frame', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            value: 'Script error.',
            stacktrace: {
              frames: [
                { filename: 'http://localhost:3001/cdn-cgi/challenge-platform/scripts/jsd/main.js' },
              ],
            },
          },
        ],
      },
    };
    expect(isIgnorableCloudflareChallengeError(event)).toBe(true);
  });

  it('keeps unrelated null TypeErrors from app bundles', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            value: "null is not an object (evaluating 'user.profile.name')",
            stacktrace: {
              frames: [{ filename: 'app:///_next/static/chunks/main.js' }],
            },
          },
        ],
      },
    };
    expect(isIgnorableCloudflareChallengeError(event)).toBe(false);
  });

  it('keeps the Chromium null document message when it comes from an app bundle', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            value: "Cannot read properties of null (reading 'document')",
            stacktrace: {
              frames: [
                {
                  filename: 'app:///_next/static/chunks/main.js',
                  function: 'c',
                },
              ],
            },
          },
        ],
      },
    };
    expect(isIgnorableCloudflareChallengeError(event)).toBe(false);
  });

  it('keeps events with no exception payload', () => {
    expect(isIgnorableCloudflareChallengeError({ message: 'plain message' })).toBe(false);
  });
});

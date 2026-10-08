/**
 * Pins the reason extension errors have to be recognised from the hint: the client frame
 * normalisation in `@sentry/nextjs` also replaces the origin of extension frames with `app://`,
 * so deciding "is this an extension" from frame addresses inside `beforeSend` cannot work.
 *
 * The SDK's real integration runs here (imported by file path, which bypasses the whole-package
 * mock of `@sentry/nextjs` in the test setup), and the same error is then handed to
 * `isErrorThrownEntirelyByBrowserExtension`. If an SDK upgrade stops erasing extension origins,
 * the rewrite assertion turns red. The frame-prefix rule becomes usable again at that point, and
 * the hint-based rule still holds without changes.
 *
 * The rewrite depends on the browser's URL parsing. Chrome registers `chrome-extension:` as a
 * standard scheme, so `new URL(…).origin` is `chrome-extension://<id>`. Node and jsdom return the
 * string `"null"`, which turns the SDK's `replace(origin, 'app://')` into a no-op. The test only
 * shims the origin of that one scheme to match Chrome; the SDK's rewrite logic itself is real.
 */
import { afterEach, describe, expect, it, vi } from 'vitest';
import { isErrorThrownEntirelyByBrowserExtension, isIgnorableBrowserExtensionError } from '@oriveo/shared';
import { nextjsClientStackFrameNormalizationIntegration } from '../../../../../node_modules/@sentry/nextjs/build/esm/client/clientNormalizationIntegration.js';

const EXTENSION_SCRIPT = 'chrome-extension://nkbihfbeogaeaoehlefnkodbefgpgknn/scripts/inpage.js';

class ChromeLikeURL extends URL {
  get origin(): string {
    return this.protocol === 'chrome-extension:' ? `${this.protocol}//${this.host}` : super.origin;
  }
}

describe('Next.js Sentry client frame normalisation and extension origins', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('leaves extension frames alone without Chrome URL parsing, as Node and jsdom do natively', () => {
    expect(new URL(EXTENSION_SCRIPT).origin).toBe('null');
  });

  it('rewrites extension frames to app:/// so the event loses the origin, while the original stack still tells', () => {
    vi.stubGlobal('URL', ChromeLikeURL);
    const integration = nextjsClientStackFrameNormalizationIntegration({
      assetPrefix: undefined,
      basePath: undefined,
      rewriteFramesAssetPrefixPath: '',
      experimentalThirdPartyOriginStackFrames: false,
    });
    const original = new Error('Failed to connect to MetaMask');
    original.stack = `i: Failed to connect to MetaMask\n    at Object.connect (${EXTENSION_SCRIPT}:7:84292)`;
    const event = {
      exception: {
        values: [{
          type: 'i',
          value: 'Failed to connect to MetaMask',
          stacktrace: { frames: [{ filename: EXTENSION_SCRIPT, function: 'Object.connect', lineno: 7, colno: 84292 }] },
        }],
      },
    };

    const processed = integration.processEvent!(event as never, {}, {} as never) as typeof event;

    // This is the address a reported event ends up carrying.
    expect(processed.exception.values[0].stacktrace.frames[0].filename).toBe('app:///scripts/inpage.js');
    // The message-plus-frame-prefix rule cannot see it; the origin-based rule is unaffected by
    // the rewrite.
    expect(isIgnorableBrowserExtensionError(processed)).toBe(false);
    expect(isErrorThrownEntirelyByBrowserExtension({ originalException: original })).toBe(true);
  });
});

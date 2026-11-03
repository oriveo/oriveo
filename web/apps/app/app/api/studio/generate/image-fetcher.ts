/**
 * Server-side Studio image fetcher: every hop of an upstream image URL passes the
 * SSRF guard and the connection is pinned to the address the guard resolved.
 * Plain http is accepted for image URLs (they carry no credentials); the port
 * allowlist and private IP blocklist still apply. Image URLs are not MCP traffic,
 * so they stay out of the MCP redaction table.
 * Up to MAX_REDIRECTS redirects are followed, each one re-checked; the byte and
 * time limits come from fetchStudioImage. Guard blocks, redirect overflow and
 * transport errors are thrown so fetchStudioImage classifies them.
 */
import { assertUrlNotSsrf } from '../../_shared/ssrf-guard';
import { requestUpstreamWithPinnedAddress } from '../../mcp/forward/upstream-request';
import { fetchStudioImage } from '../../../../lib/core/studio/image-fetch';
import type { ImageMaterializeOutcome } from '../../../../lib/core/studio/image-response';

export interface StudioImageFetcherOptions {
  request?: typeof requestUpstreamWithPinnedAddress;
  assertUrl?: typeof assertUrlNotSsrf;
}

const MAX_REDIRECTS = 3;

function cancelBody(response: Response): void {
  void response.body?.cancel().catch(() => undefined);
}

export function createStudioImageFetcher(
  opts: StudioImageFetcherOptions = {},
): (url: string, signal: AbortSignal) => Promise<ImageMaterializeOutcome> {
  const request = opts.request ?? requestUpstreamWithPinnedAddress;
  const assertUrl = opts.assertUrl ?? assertUrlNotSsrf;

  return (url, signal) => {
    const guardedFetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      const combined = init?.signal ? AbortSignal.any([init.signal, signal]) : signal;
      let current = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
      for (let hop = 0; ; hop++) {
        const { address } = await assertUrl(current, { allowHttp: true });
        const response = await request(
          { url: current, method: 'GET', headers: {}, signal: combined, address },
          { registerRedaction: false },
        );
        const location = response.status >= 300 && response.status < 400 ? response.headers.get('Location') : null;
        if (!location) return response;
        cancelBody(response);
        if (hop >= MAX_REDIRECTS) throw new Error('Studio image redirect limit exceeded');
        current = new URL(location, current);
      }
    };
    return fetchStudioImage(url, { fetch: guardedFetch as typeof fetch });
  };
}

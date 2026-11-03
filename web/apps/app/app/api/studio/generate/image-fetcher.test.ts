import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// Public host names resolve to a fixed public address so the real SSRF guard runs
// without touching the network.
const dnsMocks = vi.hoisted(() => ({
  resolve4: vi.fn(async () => ['203.0.113.10']),
  resolve6: vi.fn(async () => {
    throw Object.assign(new Error('ENODATA'), { code: 'ENODATA' });
  }),
  lookup: vi.fn(async () => [{ address: '203.0.113.10', family: 4 }]),
}));

vi.mock('node:dns/promises', () => ({
  default: dnsMocks,
  ...dnsMocks,
}));

import { createStudioImageFetcher } from './image-fetcher';
import type { UpstreamRequestInput } from '../../mcp/forward/upstream-request';
import { redactRegisteredMcpDirectUrls } from '../../../../lib/sentry/redact-url';

/** Minimal PNG: signature + IHDR header with width 2 and height 3. */
function pngBytes(): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(33);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  bytes.set([0x00, 0x00, 0x00, 0x0d], 8);
  bytes.set([0x49, 0x48, 0x44, 0x52], 12);
  bytes.set([0x00, 0x00, 0x00, 0x02], 16);
  bytes.set([0x00, 0x00, 0x00, 0x03], 20);
  return bytes;
}

function redirect(location: string, status = 302): Response {
  return new Response(null, { status, headers: { Location: location } });
}

const request = vi.fn<(input: UpstreamRequestInput) => Promise<Response>>();

beforeEach(() => {
  request.mockReset();
  // Drop any queued one-off resolution so a case that is blocked before DNS cannot leak it.
  dnsMocks.resolve4.mockReset();
  dnsMocks.resolve4.mockImplementation(async () => ['203.0.113.10']);
});

describe('createStudioImageFetcher', () => {
  describe('pinned', () => {
    it('fetches a public png and pins the request to the guarded address', async () => {
      request.mockResolvedValueOnce(new Response(pngBytes(), { status: 200 }));
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('https://images.example.com/a.png', new AbortController().signal);

      expect(outcome).toMatchObject({ ok: true, mime: 'image/png', width: 2, height: 3 });
      expect(request).toHaveBeenCalledTimes(1);
      const input = request.mock.calls[0][0];
      expect(input.url.href).toBe('https://images.example.com/a.png');
      expect(input.method).toBe('GET');
      expect(input.address).toMatchObject({ address: '203.0.113.10' });
    });
  });

  describe('redirects', () => {
    it('follows a relative redirect and guards the next hop', async () => {
      request
        .mockResolvedValueOnce(redirect('/b.png'))
        .mockResolvedValueOnce(new Response(pngBytes(), { status: 200 }));
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('https://images.example.com/dir/a.png', new AbortController().signal);

      expect(outcome).toMatchObject({ ok: true, width: 2, height: 3 });
      expect(request).toHaveBeenCalledTimes(2);
      expect(request.mock.calls[1][0].url.href).toBe('https://images.example.com/b.png');
      expect(request.mock.calls[1][0].address).toMatchObject({ address: '203.0.113.10' });
    });

    it('fails after four redirects', async () => {
      request.mockImplementation(async (input) => redirect(`${input.url.href}x`));
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('https://images.example.com/a', new AbortController().signal);

      expect(outcome).toEqual({ ok: false, failure: 'network' });
      expect(request).toHaveBeenCalledTimes(4);
    });
  });

  describe('blocked', () => {
    it('blocks a redirect to a private address without sending the second hop', async () => {
      request.mockResolvedValueOnce(redirect('https://10.0.0.5/x.png'));
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('https://images.example.com/a.png', new AbortController().signal);

      expect(outcome).toEqual({ ok: false, failure: 'network' });
      expect(request).toHaveBeenCalledTimes(1);
    });

    it('blocks a private first hop without sending any request', async () => {
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('https://169.254.169.254/latest/meta-data', new AbortController().signal);

      expect(outcome).toEqual({ ok: false, failure: 'network' });
      expect(request).not.toHaveBeenCalled();
    });
  });

  describe('plain http', () => {
    it('fetches a public plain http image through the real guard', async () => {
      request.mockResolvedValueOnce(new Response(pngBytes(), { status: 200 }));
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('http://images.example.com/a.png', new AbortController().signal);

      expect(outcome).toMatchObject({ ok: true, mime: 'image/png', width: 2, height: 3 });
      expect(request).toHaveBeenCalledTimes(1);
      expect(request.mock.calls[0][0].url.href).toBe('http://images.example.com/a.png');
      expect(request.mock.calls[0][0].address).toMatchObject({ address: '203.0.113.10' });
    });

    it('follows a redirect from https to a public plain http hop', async () => {
      request
        .mockResolvedValueOnce(redirect('http://cdn.example.com/b.png'))
        .mockResolvedValueOnce(new Response(pngBytes(), { status: 200 }));
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('https://images.example.com/a.png', new AbortController().signal);

      expect(outcome).toMatchObject({ ok: true, width: 2, height: 3 });
      expect(request).toHaveBeenCalledTimes(2);
      expect(request.mock.calls[1][0].url.href).toBe('http://cdn.example.com/b.png');
    });

    it('still blocks a plain http private address literal', async () => {
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('http://10.0.0.5/x.png', new AbortController().signal);

      expect(outcome).toEqual({ ok: false, failure: 'network' });
      expect(request).not.toHaveBeenCalled();
    });

    it('still blocks a plain http host that resolves to a private address', async () => {
      dnsMocks.resolve4.mockResolvedValueOnce(['10.0.0.7']);
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('http://images.example.com/a.png', new AbortController().signal);

      expect(outcome).toEqual({ ok: false, failure: 'network' });
      expect(request).not.toHaveBeenCalled();
    });

    it('still blocks a plain http url on a port outside the allowlist', async () => {
      const fetcher = createStudioImageFetcher({ request });

      const outcome = await fetcher('http://images.example.com:9999/a.png', new AbortController().signal);

      expect(outcome).toEqual({ ok: false, failure: 'network' });
      expect(request).not.toHaveBeenCalled();
    });
  });

  describe('real pinning', () => {
    let server: http.Server;
    let port = 0;
    const seen: Array<{ host: string | undefined; url: string | undefined }> = [];

    beforeEach(async () => {
      seen.length = 0;
      server = http.createServer((req, res) => {
        seen.push({ host: req.headers.host, url: req.url });
        res.writeHead(200, { 'Content-Type': 'image/png' });
        res.end(Buffer.from(pngBytes()));
      });
      await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
      port = (server.address() as AddressInfo).port;
    });

    afterEach(async () => {
      vi.unstubAllEnvs();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    });

    it('connects to the guarded address with the real request and keeps the url out of the MCP redaction table', async () => {
      // Production turns pinning on. The host name is unresolvable (.test is reserved), so the
      // request can only reach the local server through the address the guard handed over. The
      // guard is stubbed because the real one rejects loopback and random ports in production.
      vi.stubEnv('NODE_ENV', 'production');
      const assertUrl = vi.fn(async () => ({ address: { address: '127.0.0.1', family: 4 } }));
      const fetcher = createStudioImageFetcher({ assertUrl });
      const url = `http://img.test:${port}/a.png`;

      const outcome = await fetcher(url, new AbortController().signal);

      expect(outcome).toMatchObject({ ok: true, mime: 'image/png', width: 2, height: 3 });
      expect(assertUrl).toHaveBeenCalledTimes(1);
      expect(seen).toEqual([{ host: `img.test:${port}`, url: '/a.png' }]);
      expect(redactRegisteredMcpDirectUrls(url)).toBe(url);
    });
  });

  describe('cancel', () => {
    it('passes an aborted signal to the request once the caller aborts', async () => {
      request.mockImplementation(
        (input) =>
          new Promise<Response>((_resolve, reject) => {
            input.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
          }),
      );
      const fetcher = createStudioImageFetcher({ request });
      const controller = new AbortController();

      const pending = fetcher('https://images.example.com/a.png', controller.signal);
      await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(1));
      controller.abort();
      const outcome = await pending;

      expect(request.mock.calls[0][0].signal.aborted).toBe(true);
      expect(outcome.ok).toBe(false);
    });
  });
});

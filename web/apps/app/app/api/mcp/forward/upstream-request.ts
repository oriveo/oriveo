import type { LookupAddress } from "node:dns";
import type { IncomingHttpHeaders, IncomingMessage } from "node:http";
import http from "node:http";
import https from "node:https";
import { Readable } from "node:stream";
import * as Sentry from "@sentry/nextjs";
import { registerMcpDirectRequestURL } from "../../../../lib/sentry/redact-url";

/**
 * The upstream request of the MCP forwarding route: sent directly with node:http(s), with DNS
 * resolution pinned to the address the SSRF guard validated.
 *
 * It lives in its own file for two reasons: a Next route file may only export HTTP methods and route
 * config, so tests cannot reach functions inside it; and this is exactly the production code that
 * tests bypass when they inject a requester, which is how a hang on 204 responses can go unnoticed.
 */

export type UpstreamMethod = "GET" | "POST" | "DELETE";

export interface UpstreamRequestInput {
  url: URL;
  method: UpstreamMethod;
  headers: Record<string, string>;
  body?: string;
  signal: AbortSignal;
  address: LookupAddress;
}

export interface UpstreamRequestOptions {
  /**
   * Whether to pin the connection to `input.address`. By default it is pinned only in production
   * (against DNS-rebinding SSRF); in dev mode Node resolves the name itself, because under the
   * fake-IP pool of a local proxy tool (Surge / ClashX / WARP) a pinned address is unreachable.
   */
  pinAddress?: boolean;
  /** Additional trusted CA (PEM). Only for self-signed certificates in tests; never passed in production. */
  ca?: string;
}

/**
 * The null body statuses of the Fetch specification: giving one of these a non-null body makes
 * `new Response` throw a TypeError. 204 is common in MCP (session termination via DELETE in the
 * older protocol, 202/204 for notification POSTs).
 */
const NULL_BODY_STATUSES = new Set([101, 103, 204, 205, 304]);

/**
 * Converts the three parts of a node:http response into a Fetch `Response`. A pure function: any
 * input that cannot be represented throws, and the caller rejects. An exception must never be left
 * inside a node event callback, where the Promise would never settle.
 */
export function toFetchResponse(
  statusCode: number | undefined,
  nodeHeaders: IncomingHttpHeaders,
  openBody: () => ReadableStream<Uint8Array>,
): Response {
  // `Response` accepts only 200..599. node's response callback never yields 1xx; this guards against
  // a malformed upstream.
  if (statusCode === undefined || !Number.isInteger(statusCode) || statusCode < 200 || statusCode > 599) {
    throw new Error("MCP upstream returned an unusable status code");
  }
  const headers = new Headers();
  for (const [key, value] of Object.entries(nodeHeaders)) {
    if (value === undefined) continue;
    try {
      if (Array.isArray(value)) {
        for (const item of value) headers.append(key, item);
      } else {
        headers.set(key, String(value));
      }
    } catch {
      // If a single header's name or value is not valid Fetch syntax, drop just that one rather than
      // letting it take down the whole response.
    }
  }
  if (NULL_BODY_STATUSES.has(statusCode)) {
    return new Response(null, { status: statusCode, headers });
  }
  return new Response(openBody(), { status: statusCode, headers });
}

export function requestUpstreamWithPinnedAddress(
  input: UpstreamRequestInput,
  options: UpstreamRequestOptions = {},
): Promise<Response> {
  const client = input.url.protocol === "https:" ? https : http;
  const requestHeaders: Record<string, string> = {
    ...input.headers,
    Host: input.url.host,
  };
  const shouldPinIP = options.pinAddress ?? process.env.NODE_ENV === "production";

  return new Promise<Response>((resolve, reject) => {
    let responseMessage: IncomingMessage | null = null;
    const baseOptions: https.RequestOptions = {
      protocol: input.url.protocol,
      hostname: input.url.hostname,
      port: input.url.port || undefined,
      path: `${input.url.pathname}${input.url.search}`,
      method: input.method,
      headers: requestHeaders,
      // With the connection address pinned to an IP, SNI and certificate validation still have to
      // use the original hostname.
      servername: input.url.hostname,
    };
    if (options.ca) baseOptions.ca = options.ca;
    if (shouldPinIP) {
      baseOptions.lookup = (_hostname, lookupOptions, callback) => {
        if (typeof lookupOptions === "object" && lookupOptions?.all) {
          callback(null, [{ address: input.address.address, family: input.address.family }]);
          return;
        }
        callback(null, input.address.address, input.address.family);
      };
    }

    const abort = () => {
      const error = new Error("MCP upstream request aborted");
      responseMessage?.destroy(error);
      request.destroy(error);
    };

    // The target address must not reach Sentry: an MCP server's address is often a credential in
    // itself, and the hostname is a usage trace that should not leave the process. The SDK's http
    // integration by default records a breadcrumb and opens a span for every outbound request, and
    // adds `sentry-trace` / `baggage` headers to it; creating the request in a "no tracing" context
    // prevents all three. Registering the origin is the second layer: if the first one ever stops
    // working (an SDK upgrade changing semantics), the redaction hook still masks every address of
    // this origin.
    registerMcpDirectRequestURL(input.url.href);
    const request = Sentry.suppressTracing(() => client.request(baseOptions, (response) => {
      responseMessage = response;
      response.once("close", () => {
        input.signal.removeEventListener("abort", abort);
      });
      try {
        const converted = toFetchResponse(
          response.statusCode,
          response.headers,
          () => Readable.toWeb(response) as ReadableStream<Uint8Array>,
        );
        // Nobody reads the body of a null-body response; unless it is drained the socket is never
        // released.
        if (converted.body === null) response.resume();
        resolve(converted);
      } catch (error) {
        // This is a node event callback: a thrown exception only becomes an uncaughtException, and
        // the Promise hangs forever.
        input.signal.removeEventListener("abort", abort);
        response.destroy();
        request.destroy();
        reject(error);
      }
    }));

    input.signal.addEventListener("abort", abort, { once: true });

    request.once("error", (error) => {
      input.signal.removeEventListener("abort", abort);
      reject(error);
    });

    if (input.signal.aborted) {
      abort();
      return;
    }

    // A single end(body): node adds Content-Length from it. write followed by end would become
    // chunked, and many token endpoints do not accept chunked form requests.
    if (input.body !== undefined) {
      request.end(input.body);
    } else {
      request.end();
    }
  });
}

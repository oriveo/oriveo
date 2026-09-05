// Shell for the shared request helpers: executeProviderRequest, describeProviderRequestError and
// buildRelayReasoningParams. The pure logic and the 120s timeout bridge live in @oriveo/core; this
// file injects the web UpstreamTransport built on the global fetch.
import { executeProviderRequest as coreExecuteProviderRequest } from "@oriveo/core/providers/request-builders/utils";
import type { ProviderRequest } from "./types";
import type { UpstreamTransport } from "@oriveo/core";
import { getRuntimeConfig } from "../../../../../lib/core/metadata/metadata-client";

export {
  buildRelayReasoningParams,
  describeProviderRequestError,
} from "@oriveo/core/providers/request-builders/utils";

/**
 * Web upstream transport, using the global fetch resolved at call time so tests can replace it
 * with vi.stubGlobal('fetch').
 * redirect:'manual' matters: the SSRF guard only validates the initial URL, so following
 * redirects would let an upstream redirect the request to an internal or metadata address with
 * a 302 Location and no re-check. Nothing is followed here, matching the 3xx rejection on the relay
 * forward path, and this covers every upstream request going through this transport
 * (chat/stream, relay-stream, sse-parser, moonshot-tool-loop).
 */
export const webUpstreamTransport: UpstreamTransport = {
  fetch: (url, init) => fetch(url, { ...init, redirect: "manual" }),
};

export function executeProviderRequest(
  req: ProviderRequest,
  clientSignal?: AbortSignal,
): Promise<Response> {
  const timeoutSecs = getRuntimeConfig()?.networkPolicy.upstreamFirstByteTimeoutSecs;
  const timeoutMs =
    typeof timeoutSecs === "number" && Number.isFinite(timeoutSecs) && timeoutSecs > 0
      ? timeoutSecs * 1000
      : undefined;
  return coreExecuteProviderRequest(req, webUpstreamTransport, clientSignal, { timeoutMs });
}

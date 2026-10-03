// @vitest-environment node
import * as Sentry from "@sentry/nextjs";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { redactSentrySpan } from "../redact-url";
import { serverBeforeSend, serverBeforeSendTransaction } from "../server-before-send";

// The global setup replaces @sentry/nextjs with a stub; this suite needs the real SDK.
vi.unmock("@sentry/nextjs");

/**
 * These tests run the real Sentry SDK pipeline: `Sentry.captureRequestError` (the `onRequestError`
 * of instrumentation.ts) -> the RequestData integration writes the inbound request headers into
 * the event -> our `beforeSend` -> transport. The assertions look at the envelope the transport
 * actually receives rather than at a hand-built event, because the SDK decides which event field
 * the request headers end up in, not the test.
 */

const CREDENTIAL = "mcp-secret-token-abc123";
const TARGET = "https://mcp.example.com/abcdefghij0123456789/mcp";
const RELAY_KEY = "sk-relay-secret-key-xyz";

const envelopes: string[] = [];

function requestErrorContext(routePath: string) {
  return { routerKind: "App Router", routePath, routeType: "route" } as const;
}

function mcpRequest(method = "POST") {
  return {
    path: "/api/mcp/forward",
    method,
    headers: {
      "content-type": "application/json",
      "user-agent": "vitest",
      "x-mcp-credential": CREDENTIAL,
      "x-mcp-target-url": TARGET,
      "x-mcp-headers": JSON.stringify({ "Mcp-Name": "delete_everything" }),
      "x-mcp-method": "POST",
      authorization: `Bearer ${CREDENTIAL}`,
    },
  };
}

async function captureAndFlush(error: unknown, request: ReturnType<typeof mcpRequest>, routePath: string) {
  Sentry.captureRequestError(error, request, requestErrorContext(routePath));
  await Sentry.flush(5000);
}

function sentEvents(): Array<Record<string, unknown>> {
  const events: Array<Record<string, unknown>> = [];
  for (const raw of envelopes) {
    for (const line of raw.split("\n")) {
      if (!line.includes('"exception"')) continue;
      events.push(JSON.parse(line) as Record<string, unknown>);
    }
  }
  return events;
}

describe("server Sentry hooks: credential-bearing request headers never leave the process", () => {
  beforeAll(() => {
    Sentry.init({
      dsn: "https://public@sentry.invalid/1",
      tracesSampleRate: 0,
      defaultIntegrations: false,
      // Matches the two production default integrations that matter here: RequestData writes the
      // request headers, and LinkedErrors expands the cause chain into exception.values (a
      // protective abort hides in the cause).
      integrations: [Sentry.requestDataIntegration(), Sentry.linkedErrorsIntegration()],
      beforeSend: serverBeforeSend,
      beforeSendTransaction: serverBeforeSendTransaction,
      beforeSendSpan: redactSentrySpan,
      transport: () => ({
        send: async (envelope) => {
          envelopes.push(
            (envelope[1] as unknown[][])
              .map((item) => item.map((part) => (typeof part === "string" ? part : JSON.stringify(part))).join("\n"))
              .join("\n"),
          );
          return {};
        },
        flush: async () => true,
      }),
    });
  });

  afterAll(async () => {
    await Sentry.close(1000);
  });

  beforeEach(() => {
    envelopes.length = 0;
  });

  it("still reports a real error on the MCP route, with the x-mcp-* and authorization headers removed", async () => {
    await captureAndFlush(
      new TypeError("Cannot read properties of undefined (reading 'foo')"),
      mcpRequest(),
      "/api/mcp/forward",
    );

    const events = sentEvents();
    // The pipeline works end to end: the event was sent and the SDK did attach request headers.
    expect(events).toHaveLength(1);
    const headers = (events[0].request as { headers: Record<string, string> }).headers;
    expect(headers["content-type"]).toBe("application/json");
    expect(headers["user-agent"]).toBe("vitest");
    expect(Object.keys(headers).filter((name) => name.startsWith("x-mcp-"))).toEqual([]);
    expect(headers.authorization).toBeUndefined();

    // The credential, target address and tool name appear nowhere in the envelope.
    const wire = envelopes.join("\n");
    expect(wire).not.toContain(CREDENTIAL);
    expect(wire).not.toContain("mcp.example.com");
    expect(wire).not.toContain("delete_everything");
  });

  it("removes the equivalent credential headers on the relay route (x-relay-proxy-config holds an apiKey)", async () => {
    await captureAndFlush(
      new TypeError("boom"),
      {
        path: "/api/relay/forward",
        method: "POST",
        headers: {
          "content-type": "application/json",
          "user-agent": "vitest",
          "x-relay-proxy-config": JSON.stringify({ apiKey: RELAY_KEY }),
          "x-relay-upstream-url": "https://relay.internal.example/v1/chat/completions",
          "x-mcp-credential": "",
          "x-mcp-target-url": "",
          "x-mcp-headers": "",
          "x-mcp-method": "",
          authorization: "",
        },
      },
      "/api/relay/forward",
    );
    expect(sentEvents()).toHaveLength(1);
    const wire = envelopes.join("\n");
    expect(wire).not.toContain(RELAY_KEY);
    expect(wire).not.toContain("relay.internal.example");
    expect(wire).not.toContain("x-relay-");
  });

  it("does not report protective aborts or mid-stream disconnects on the MCP route", async () => {
    for (const message of [
      "MCP stream idle timeout (no data for 90 seconds)",
      "MCP stream exceeded maximum duration of 600 seconds",
      "MCP response exceeded the 8MB limit",
      "MCP upstream request aborted",
    ]) {
      await captureAndFlush(
        new Error("failed to pipe response", { cause: new Error(message) }),
        mcpRequest(),
        "/api/mcp/forward",
      );
    }
    // node:http: the peer closes the connection halfway through the response body.
    await captureAndFlush(new Error("aborted"), mcpRequest("GET"), "/api/mcp/forward");
    await captureAndFlush(new Error("read ECONNRESET"), mcpRequest("DELETE"), "/api/mcp/forward");

    expect(sentEvents()).toHaveLength(0);
  });

  it("counter-example: aborted on a non-streaming route is still reported (the filter only covers streaming routes)", async () => {
    await captureAndFlush(new Error("aborted"), { ...mcpRequest(), path: "/api/metadata" }, "/api/metadata");
    expect(sentEvents()).toHaveLength(1);
    expect(envelopes.join("\n")).not.toContain(CREDENTIAL);
  });

  it("redacts transaction events the same way: credential headers go from both the request headers and the root span attributes", () => {
    const event = serverBeforeSendTransaction({
      type: "transaction" as const,
      request: {
        url: "https://app.example.com/api/mcp/forward",
        headers: { "X-Mcp-Credential": CREDENTIAL, "content-type": "application/json" },
      },
      contexts: {
        trace: {
          data: {
            "http.request.header.x_mcp_credential": CREDENTIAL,
            "http.request.header.x_mcp_target_url": TARGET,
            "http.request.header.content_type": "application/json",
            "http.request.method": "POST",
          },
        },
      },
    });
    expect(JSON.stringify(event)).not.toContain(CREDENTIAL);
    expect(JSON.stringify(event)).not.toContain("mcp.example.com");
    expect(event.request.headers).toEqual({ "content-type": "application/json" });
    expect(event.contexts.trace.data).toEqual({
      "http.request.header.content_type": "application/json",
      "http.request.method": "POST",
    });
  });
});

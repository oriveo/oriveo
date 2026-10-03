import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DELETE, GET, POST } from "./route";
import {
  createForwardMcpTransport,
  MCP_FORWARD_MAX_CALL_TIMEOUT_SECONDS,
  MCP_FORWARD_UPSTREAM_TIMEOUT_SECONDS,
  MCP_RUNTIME_CONFIG_FALLBACK,
  McpClient,
  McpClientError,
  McpTransportError,
} from "@oriveo/core/mcp/index";
import { __resetRateLimitForTests } from "../../chat/stream/rate-limit";
import { isIgnorableMcpProtectiveAbort } from "../../../../lib/sentry/ignore-relay-noise";
import {
  __resetMcpForwardConcurrencyForTests,
  forwardSlotsInUse,
  MAX_CONCURRENT_FORWARDS_PER_IP,
} from "./concurrency";

const mocks = vi.hoisted(() => ({
  lookup: vi.fn(),
  resolve4: vi.fn(),
  resolve6: vi.fn(),
}));

vi.mock("node:dns/promises", () => ({
  default: { lookup: mocks.lookup, resolve4: mocks.resolve4, resolve6: mocks.resolve6 },
  lookup: mocks.lookup,
  resolve4: mocks.resolve4,
  resolve6: mocks.resolve6,
}));

type TestGlobal = typeof globalThis & {
  __oriveoMcpForwardUpstreamRequester?: (input: unknown) => Promise<Response>;
};

type CapturedRequest = {
  url: URL;
  method: string;
  headers: Record<string, string>;
  body?: string;
  signal: AbortSignal;
  address: { address: string; family: number };
};

const captured: CapturedRequest[] = [];

function setUpstreamRequester(response: () => Response): void {
  (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester = async (input) => {
    captured.push(input as CapturedRequest);
    return response();
  };
}

function setUpstreamRequesterOnce(responses: Array<() => Response>): void {
  let index = 0;
  (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester = async (input) => {
    captured.push(input as CapturedRequest);
    const build = responses[Math.min(index, responses.length - 1)];
    index += 1;
    return build();
  };
}

function clearUpstreamRequester(): void {
  delete (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester;
}

function textResponse(body: string, status = 200, contentType = "application/json"): Response {
  return new Response(body, { status, headers: { "Content-Type": contentType } });
}

function byteStream(totalBytes: number, chunkSize = 64 * 1024): ReadableStream<Uint8Array> {
  let sent = 0;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent >= totalBytes) {
        controller.close();
        return;
      }
      const size = Math.min(chunkSize, totalBytes - sent);
      controller.enqueue(new Uint8Array(size));
      sent += size;
    },
  });
}

function buildRequest(
  headers: Record<string, string>,
  body?: string,
  method: "POST" | "GET" | "DELETE" = "POST",
): Request {
  return new Request("http://localhost/api/mcp/forward", {
    method,
    headers,
    ...(method === "POST" ? { body: body ?? "" } : {}),
  });
}

const PUBLIC_TARGET = "https://mcp.example.com/mcp";
const CREDENTIAL = "mcp-secret-token-abc123";
const BODY_SECRET = "top-secret-tool-argument";

/** Asserts that no console call in this run contains the credential or the request body: neither may ever be logged or persisted. */
function expectNoSecretInLogs(consoleSpies: Array<ReturnType<typeof vi.spyOn>>): void {
  for (const spy of consoleSpies) {
    for (const call of spy.mock.calls) {
      const serialized = call.map((arg: unknown) => {
        if (typeof arg === "string") return arg;
        try {
          return JSON.stringify(arg);
        } catch {
          return String(arg);
        }
      }).join(" ");
      expect(serialized).not.toContain(CREDENTIAL);
      expect(serialized).not.toContain(BODY_SECRET);
    }
  }
}

function spyOnConsole() {
  return (["log", "info", "warn", "error", "debug"] as const).map((level) =>
    vi.spyOn(console, level).mockImplementation(() => {}),
  );
}

describe("/api/mcp/forward", () => {
  beforeEach(() => {
    __resetRateLimitForTests();
    // Some cases only check the status code and never read the body; that stream would hold its concurrency slot until the timeout fires
    __resetMcpForwardConcurrencyForTests();
    captured.length = 0;
    mocks.resolve4.mockResolvedValue(["203.0.113.10"]);
    mocks.resolve6.mockRejectedValue(new Error("ENODATA"));
    mocks.lookup.mockResolvedValue([{ address: "203.0.113.10", family: 4 }]);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
    vi.unstubAllEnvs();
    clearUpstreamRequester();
    mocks.lookup.mockReset();
    mocks.resolve4.mockReset();
    mocks.resolve6.mockReset();
  });

  it("forwards a normal POST upstream and writes the response back unchanged", async () => {
    setUpstreamRequester(() => textResponse('{"jsonrpc":"2.0","id":1,"result":{}}'));
    const res = await POST(
      buildRequest(
        {
          "Content-Type": "application/json",
          "X-Mcp-Target-Url": PUBLIC_TARGET,
          "X-Mcp-Credential": CREDENTIAL,
          "X-Mcp-Headers": JSON.stringify({ "MCP-Protocol-Version": "2026-07-28" }),
        },
        '{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
      ),
    );
    expect(res.status).toBe(200);
    await expect(res.text()).resolves.toBe('{"jsonrpc":"2.0","id":1,"result":{}}');
    expect(captured).toHaveLength(1);
    expect(captured[0].url.toString()).toBe(PUBLIC_TARGET);
    expect(captured[0].method).toBe("POST");
    expect(captured[0].body).toBe('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
    expect(captured[0].headers.Authorization).toBe(`Bearer ${CREDENTIAL}`);
    expect(captured[0].headers["mcp-protocol-version"]).toBe("2026-07-28");
    expect(captured[0].headers.Accept).toBe("application/json, text/event-stream");
    // Only the headers MCP needs are sent: caller headers such as cookie never make it into the outbound set,
    // and host is derived from the target URL by the upstream request itself, never taken from the caller.
    expect(Object.keys(captured[0].headers).sort()).toEqual([
      "Accept",
      "Authorization",
      "Content-Type",
      "mcp-protocol-version",
    ]);
  });

  it("OAuth discovery requests (GET) and token requests (form-encoded POST) both go through this route", async () => {
    setUpstreamRequesterOnce([
      () => textResponse('{"resource":"https://mcp.example.com/mcp"}'),
      () => textResponse('{"access_token":"x"}'),
    ]);

    const discovery = await GET(
      buildRequest(
        {
          "X-Mcp-Target-Url": "https://mcp.example.com/.well-known/oauth-protected-resource",
          "X-Mcp-Method": "GET",
        },
        undefined,
        "GET",
      ),
    );
    expect(discovery.status).toBe(200);
    expect(captured[0].method).toBe("GET");
    expect(captured[0].url.pathname).toBe("/.well-known/oauth-protected-resource");
    await expect(discovery.text()).resolves.toContain("resource");

    const token = await POST(
      buildRequest({
        "X-Mcp-Target-Url": "https://auth.example.com/token",
        "X-Mcp-Headers": JSON.stringify({ "Content-Type": "application/x-www-form-urlencoded" }),
      }, "grant_type=authorization_code&code=ac-1&code_verifier=cv-1"),
    );
    expect(token.status).toBe(200);
    expect(captured[1].headers["Content-Type"]).toBe("application/x-www-form-urlencoded");
    expect(captured[1].body).toContain("grant_type=authorization_code");
  });

  it("allows session termination (DELETE + mcp-session-id) and rejects unknown methods", async () => {
    setUpstreamRequester(() => new Response(null, { status: 204 }));
    const ok = await DELETE(
      buildRequest(
        { "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Headers": JSON.stringify({ "MCP-Session-Id": "session-7f3a" }) },
        undefined,
        "DELETE",
      ),
    );
    expect(ok.status).toBe(204);
    expect(ok.body).toBeNull();
    expect(captured[0].method).toBe("DELETE");
    expect(captured[0].headers["mcp-session-id"]).toBe("session-7f3a");
    // Methods without a request body carry no Content-Type
    expect(captured[0].headers["Content-Type"]).toBeUndefined();

    const rejected = await POST(
      buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Method": "PATCH" }),
    );
    expect(rejected.status).toBe(400);
  });

  it("narrowing: DELETE must carry a session id, a form POST must be a token request, GET is only for discovery and SSE", async () => {
    setUpstreamRequester(() => {
      throw new Error("upstream must not be reached");
    });
    const expectNotAllowed = async (res: Response, label: string) => {
      expect(res.status, label).toBe(400);
      expect(((await res.json()) as { code: string }).code, label).toBe("mcp_request_not_allowed");
    };

    await expectNotAllowed(
      await DELETE(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, undefined, "DELETE")),
      "DELETE without session",
    );
    await expectNotAllowed(
      await DELETE(
        buildRequest(
          { "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Headers": JSON.stringify({ "MCP-Session-Id": "" }) },
          undefined,
          "DELETE",
        ),
      ),
      "DELETE with empty session",
    );
    // Turning the POST into a DELETE via X-Mcp-Method does not get around it either
    await expectNotAllowed(
      await POST(buildRequest({ "X-Mcp-Target-Url": "https://victim.example.com/api/items/1", "X-Mcp-Method": "DELETE" })),
      "DELETE via method override",
    );

    const form = { "X-Mcp-Headers": JSON.stringify({ "Content-Type": "application/x-www-form-urlencoded" }) };
    for (const body of ["", "username=admin&password=guess", "grant_type=", "{\"grant_type\":\"x\"}"]) {
      await expectNotAllowed(
        await POST(buildRequest({ "X-Mcp-Target-Url": "https://victim.example.com/login", ...form }, body)),
        `form body ${body}`,
      );
    }

    for (const target of [
      PUBLIC_TARGET,
      "https://victim.example.com/",
      "https://victim.example.com/admin?debug=1",
      "https://victim.example.com/x.well-known/y",
      "https://victim.example.com/?path=/.well-known/x",
    ]) {
      await expectNotAllowed(
        await GET(buildRequest({ "X-Mcp-Target-Url": target }, undefined, "GET")),
        `GET ${target}`,
      );
    }
    // Merely declaring that an event stream is also accepted does not make it an SSE request
    await expectNotAllowed(
      await GET(
        buildRequest(
          { "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Headers": JSON.stringify({ Accept: "text/html, text/event-stream" }) },
          undefined,
          "GET",
        ),
      ),
      "GET with mixed Accept",
    );
    expect(captured).toHaveLength(0);
    expect(forwardSlotsInUse("unknown")).toBe(0);
  });

  it("the two GET shapes that are allowed: well-known discovery (both path layouts) and SSE", async () => {
    setUpstreamRequester(() => textResponse('{"issuer":"https://auth.example.com/tenant1"}'));
    for (const target of [
      "https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp",
      "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
      "https://auth.example.com/.well-known/openid-configuration/tenant1",
      "https://auth.example.com/tenant1/.well-known/openid-configuration",
    ]) {
      const res = await GET(buildRequest({ "X-Mcp-Target-Url": target }, undefined, "GET"));
      expect(res.status, target).toBe(200);
      await res.text();
    }
    expect(captured).toHaveLength(4);
    expect(captured[0].body).toBeUndefined();
    expect(captured[0].headers["Content-Type"]).toBeUndefined();

    const sseHeaders = {
      "X-Mcp-Target-Url": PUBLIC_TARGET,
      "X-Mcp-Headers": JSON.stringify({ Accept: "text/event-stream", "MCP-Session-Id": "session-7f3a" }),
    };
    setUpstreamRequester(() => textResponse("data: {}\n\n", 200, "text/event-stream; charset=utf-8"));
    const sse = await GET(buildRequest(sseHeaders, undefined, "GET"));
    expect(sse.status).toBe(200);
    await expect(sse.text()).resolves.toBe("data: {}\n\n");
    expect(captured[4].headers.Accept).toBe("text/event-stream");

    // Upstream answered 2xx but not with an event stream: the body is not handed back
    setUpstreamRequester(() => textResponse("<html>secret page</html>", 200, "text/html"));
    const notSse = await GET(buildRequest(sseHeaders, undefined, "GET"));
    expect(notSse.status).toBe(502);
    const notSseText = await notSse.text();
    expect(notSseText).toContain("mcp_unexpected_content_type");
    expect(notSseText).not.toContain("secret page");

    // Non-2xx is handed back as usual: modern servers answer GET with 405 and the client relies on it
    setUpstreamRequester(() => textResponse('{"error":"method not allowed"}', 405));
    const notAllowed = await GET(buildRequest(sseHeaders, undefined, "GET"));
    expect(notAllowed.status).toBe(405);
    await notAllowed.text();
    expect(forwardSlotsInUse("unknown")).toBe(0);
  });

  it("negative: private-network and cloud-metadata addresses are rejected (reuses assertUrlNotSsrf)", async () => {
    setUpstreamRequester(() => {
      throw new Error("upstream must not be reached");
    });
    for (const target of [
      "https://10.0.0.1/mcp",
      "https://192.168.1.10/mcp",
      "https://169.254.169.254/latest/meta-data",
      "https://[::1]/mcp",
    ]) {
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": target }));
      expect(res.status).toBe(403);
      const body = (await res.json()) as { code: string };
      expect(body.code).toBe("endpoint_forbidden");
    }
    expect(captured).toHaveLength(0);
  });

  it("negative: loopback addresses are rejected in production too (the local dev allowance only exists outside production)", async () => {
    vi.stubEnv("NODE_ENV", "production");
    setUpstreamRequester(() => {
      throw new Error("upstream must not be reached");
    });
    const res = await POST(buildRequest({ "X-Mcp-Target-Url": "https://127.0.0.1:8443/mcp" }));
    expect(res.status).toBe(403);
    expect(captured).toHaveLength(0);
  });

  it("negative: anything other than https is rejected, including local dev http", async () => {
    setUpstreamRequester(() => {
      throw new Error("upstream must not be reached");
    });
    for (const target of ["http://mcp.example.com/mcp", "http://localhost:3000/mcp", "ftp://mcp.example.com/mcp"]) {
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": target }));
      expect(res.status).toBe(403);
    }
    expect(captured).toHaveLength(0);
  });

  it("negative: ports outside the allowlist are rejected", async () => {
    setUpstreamRequester(() => {
      throw new Error("upstream must not be reached");
    });
    const res = await POST(buildRequest({ "X-Mcp-Target-Url": "https://mcp.example.com:9999/mcp" }));
    expect(res.status).toBe(403);
    expect(captured).toHaveLength(0);
    // Ports on the allowlist still pass, which proves the rejection above comes from the port allowlist itself
    setUpstreamRequester(() => textResponse("{}"));
    const allowed = await POST(buildRequest({ "X-Mcp-Target-Url": "https://mcp.example.com:8443/mcp" }));
    expect(allowed.status).toBe(200);
  });

  it("negative: an oversized response is cut off", async () => {
    setUpstreamRequester(
      () => new Response(byteStream(9 * 1024 * 1024), { status: 200, headers: { "Content-Type": "application/json" } }),
    );
    const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }));
    expect(res.status).toBe(200);
    await expect(res.text()).rejects.toThrow(/exceeded the 8MB limit/);
  });

  it("negative: forbidden headers are rejected rather than silently dropped", async () => {
    setUpstreamRequester(() => {
      throw new Error("upstream must not be reached");
    });
    for (const raw of [
      JSON.stringify({ cookie: "session=abc" }),
      JSON.stringify({ host: "attacker.example.com" }),
      JSON.stringify({ "X-Mcp-Target-Url": "https://evil.example.com" }),
      JSON.stringify({ "MCP-Protocol-Version": "2026-07-28", cookie: "a=b" }),
    ]) {
      const res = await POST(
        buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Headers": raw }),
      );
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: string };
      expect(body.error).toMatch(/not allowed|Invalid/);
    }
    expect(captured).toHaveLength(0);
  });

  it("forwards the headers the modern protocol requires: Mcp-Method / Mcp-Name / Mcp-Param-*", async () => {
    setUpstreamRequester(() => textResponse('{"jsonrpc":"2.0","id":2,"result":{}}'));
    const res = await POST(
      buildRequest(
        {
          "X-Mcp-Target-Url": PUBLIC_TARGET,
          "X-Mcp-Headers": JSON.stringify({
            "MCP-Protocol-Version": "2026-07-28",
            "Mcp-Method": "tools/call",
            "Mcp-Name": "search_documents",
            "Mcp-Param-Region": "eu-west-1",
            "Mcp-Param-Tenant": "=?base64?5Lit5paH?=",
            Accept: "application/json",
          }),
        },
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_documents"}}',
      ),
    );
    expect(res.status).toBe(200);
    expect(captured[0].headers["mcp-method"]).toBe("tools/call");
    expect(captured[0].headers["mcp-name"]).toBe("search_documents");
    expect(captured[0].headers["mcp-param-region"]).toBe("eu-west-1");
    // Header values are case-sensitive; the base64 wrapping passes through unchanged
    expect(captured[0].headers["mcp-param-tenant"]).toBe("=?base64?5Lit5paH?=");
    // The caller's Accept replaces the default instead of appearing next to it
    expect(captured[0].headers.Accept).toBe("application/json");
    expect(Object.keys(captured[0].headers).filter((key) => key.toLowerCase() === "accept")).toEqual(["Accept"]);
  });

  it("negative: Mcp-Param-* header names, their count, and the value of every outbound header are constrained", async () => {
    setUpstreamRequester(() => {
      throw new Error("upstream must not be reached");
    });
    const tooMany = Object.fromEntries(
      Array.from({ length: 17 }, (_, index) => [`Mcp-Param-P${index}`, "v"]),
    );
    for (const extra of [
      { "Mcp-Param-": "v" },
      { "Mcp-Param-Bad Name": "v" },
      { "Mcp-Param-Bad:Name": "v" },
      { [`Mcp-Param-${"n".repeat(65)}`]: "v" },
      tooMany,
      { "Mcp-Name": "line1\r\nX-Injected: 1" },
      { "Mcp-Name": "line1\nline2" },
      { "Mcp-Param-Region": "nul\u0000byte" },
      { "Mcp-Name": "エンコードなし" },
      { "Mcp-Param-Region": "v".repeat(2049) },
      { "Mcp-Method": 42 },
      { "Mcp-Method": "tools/list", "mcp-method": "tools/call" },
    ]) {
      const res = await POST(
        buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Headers": encodeURIComponent(JSON.stringify(extra)) }),
      );
      expect(res.status, JSON.stringify(extra).slice(0, 80)).toBe(400);
    }
    // Boundary of the count limit: exactly 16 pass
    setUpstreamRequester(() => textResponse("{}"));
    const sixteen = Object.fromEntries(
      Array.from({ length: 16 }, (_, index) => [`Mcp-Param-P${index}`, "v"]),
    );
    const ok = await POST(
      buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Headers": JSON.stringify(sixteen) }),
    );
    expect(ok.status).toBe(200);
    expect(captured).toHaveLength(1);
  });

  it("negative: a caller-supplied authorization header is explicitly rejected; credentials may only travel in X-Mcp-Credential", async () => {
    setUpstreamRequester(() => {
      throw new Error("upstream must not be reached");
    });
    const res = await POST(
      buildRequest({
        "X-Mcp-Target-Url": PUBLIC_TARGET,
        "X-Mcp-Credential": CREDENTIAL,
        "X-Mcp-Headers": JSON.stringify({ Authorization: "Bearer caller-supplied" }),
      }),
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/authorization/);
    expect(body.error).toMatch(/X-Mcp-Credential/);
    expect(body.error).not.toContain("caller-supplied");
    expect(captured).toHaveLength(0);
  });

  it("hands the upstream MCP-Session-Id and WWW-Authenticate back to the browser under our own header names", async () => {
    const challenge =
      'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="files:read"';
    setUpstreamRequesterOnce([
      () =>
        new Response('{"jsonrpc":"2.0","id":1,"result":{}}', {
          status: 200,
          headers: {
            "Content-Type": "application/json",
            "Mcp-Session-Id": "session-7f3a",
            "Set-Cookie": "upstream=1; Path=/",
            "Access-Control-Allow-Origin": "*",
            "X-Upstream-Internal": "leak",
          },
        }),
      () =>
        new Response('{"error":"unauthorized"}', {
          status: 401,
          headers: { "Content-Type": "application/json", "WWW-Authenticate": challenge },
        }),
      () =>
        new Response("{}", {
          status: 403,
          headers: {
            "Content-Type": "application/json",
            "WWW-Authenticate": 'Bearer error="insufficient_scope"',
          },
        }),
    ]);

    const initialized = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
    expect(initialized.status).toBe(200);
    expect(initialized.headers.get("X-Mcp-Session-Id")).toBe("session-7f3a");
    expect(initialized.headers.get("X-Mcp-WWW-Authenticate")).toBeNull();
    // No other upstream response header is passed through
    expect(initialized.headers.get("Set-Cookie")).toBeNull();
    expect(initialized.headers.get("Access-Control-Allow-Origin")).toBeNull();
    expect(initialized.headers.get("X-Upstream-Internal")).toBeNull();
    expect(initialized.headers.get("Mcp-Session-Id")).toBeNull();

    const unauthorized = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
    expect(unauthorized.status).toBe(401);
    expect(unauthorized.headers.get("X-Mcp-WWW-Authenticate")).toBe(challenge);
    // The original names are avoided: browsers have built-in handling for them
    expect(unauthorized.headers.get("WWW-Authenticate")).toBeNull();

    const forbidden = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
    expect(forbidden.status).toBe(403);
    expect(forbidden.headers.get("X-Mcp-WWW-Authenticate")).toBe('Bearer error="insufficient_scope"');
  });

  it("negative: overlong upstream response headers, or ones with control characters, are not handed back", async () => {
    setUpstreamRequesterOnce([
      () => {
        const response = new Response("{}", { status: 401, headers: { "Content-Type": "application/json" } });
        // The Headers constructor rejects control characters, so the return value of get is patched to simulate a misbehaving upstream
        const original = response.headers.get.bind(response.headers);
        response.headers.get = (name: string) => {
          if (name.toLowerCase() === "mcp-session-id") return "s".repeat(1025);
          if (name.toLowerCase() === "www-authenticate") return "Bearer realm=\"a\"\r\nSet-Cookie: x=1";
          return original(name);
        };
        return response;
      },
      () =>
        new Response("{}", {
          status: 401,
          headers: {
            "Content-Type": "application/json",
            "Mcp-Session-Id": "s".repeat(1024),
            "WWW-Authenticate": `Bearer realm="${"r".repeat(4096)}"`,
          },
        }),
    ]);
    const hostile = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
    expect(hostile.headers.get("X-Mcp-Session-Id")).toBeNull();
    expect(hostile.headers.get("X-Mcp-WWW-Authenticate")).toBeNull();
    expect(hostile.headers.get("Set-Cookie")).toBeNull();

    const boundary = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
    // A session id exactly at the limit passes; a challenge over the limit is dropped entirely
    expect(boundary.headers.get("X-Mcp-Session-Id")).toBe("s".repeat(1024));
    expect(boundary.headers.get("X-Mcp-WWW-Authenticate")).toBeNull();
  });

  it("negative: redirects are only followed same-origin and up to a hop limit", async () => {
    let hop = 0;
    (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester = async () => {
      hop += 1;
      captured.push({ url: new URL(PUBLIC_TARGET) } as CapturedRequest);
      return new Response(null, {
        status: 302,
        headers: { Location: "https://evil.example.com/mcp" },
      });
    };
    const crossOrigin = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }));
    expect(crossOrigin.status).toBe(502);
    const crossOriginBody = (await crossOrigin.json()) as { code: string };
    expect(crossOriginBody.code).toBe("upstream_redirect_blocked");

    hop = 0;
    (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester = async () => {
      hop += 1;
      return new Response(null, { status: 307, headers: { Location: PUBLIC_TARGET } });
    };
    const tooMany = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }));
    expect(tooMany.status).toBe(502);
    expect(hop).toBe(6);
  });

  it("negative: 301 / 302 / 303, which would turn POST into GET, are not followed and upstream is hit only once", async () => {
    for (const status of [301, 302, 303]) {
      captured.length = 0;
      setUpstreamRequesterOnce([
        () => new Response(null, { status, headers: { Location: "https://mcp.example.com/elsewhere" } }),
        () => textResponse('{"leaked":"followed"}'),
      ]);
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Credential": CREDENTIAL }, '{"jsonrpc":"2.0"}'));
      expect(res.status, String(status)).toBe(502);
      expect(((await res.json()) as { code: string }).code, String(status)).toBe("upstream_redirect_blocked");
      // No second request: nothing is resent as GET, and no credential travels to the new address.
      expect(captured, String(status)).toHaveLength(1);
      expect(captured[0].method).toBe("POST");
      expect(forwardSlotsInUse("unknown")).toBe(0);
    }

    // The production forward transport sees the same outcome as the direct path: redirect_rejected.
    setUpstreamRequester(() => new Response(null, { status: 302, headers: { Location: "https://mcp.example.com/elsewhere" } }));
    const transport = createForwardMcpTransport({
      fetch: async (url, init) => {
        const response = await POST(new Request(`http://localhost${url}`, { method: init.method, headers: init.headers, body: init.body }));
        return { status: response.status, headers: response.headers, body: response.body };
      },
    });
    const error = await transport
      .send({ url: PUBLIC_TARGET, method: "POST", headers: { "content-type": "application/json" }, body: "{}", redirect: "same-origin" })
      .catch((e: unknown) => e);
    expect((error as McpTransportError).kind).toBe("redirect_rejected");
  });

  it("every response carries X-Content-Type-Options: nosniff (upstream bodies and the route's own error bodies)", async () => {
    setUpstreamRequester(() => textResponse("<html><script>alert(1)</script></html>", 200, "application/json"));
    const forwarded = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
    expect(forwarded.headers.get("X-Content-Type-Options")).toBe("nosniff");
    await forwarded.text();
    const rejected = await POST(buildRequest({}));
    expect(rejected.status).toBe(400);
    expect(rejected.headers.get("X-Content-Type-Options")).toBe("nosniff");
  });

  describe("no-follow redirect mode", () => {
    const sameOriginRedirect = (status: number) => () =>
      new Response(null, { status, headers: { Location: "https://mcp.example.com/elsewhere" } });

    it("negative: with X-Mcp-Redirect: never even a same-origin https 3xx is not followed, upstream is hit only once and Location is not handed back", async () => {
      for (const status of [301, 302, 303, 307, 308]) {
        captured.length = 0;
        setUpstreamRequester(sameOriginRedirect(status));
        const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Redirect": "never" }, "{}"));
        expect(res.status, String(status)).toBe(502);
        expect(res.headers.get("X-Oriveo-Error-Source")).toBe("oriveo");
        expect(res.headers.get("Location")).toBeNull();
        expect(((await res.json()) as { code: string }).code).toBe("upstream_redirect_blocked");
        expect(captured, String(status)).toHaveLength(1);
      }
    });

    it("negative: token requests are not followed even without that header (the body holds the authorization code and verifier)", async () => {
      setUpstreamRequester(sameOriginRedirect(307));
      const res = await POST(
        buildRequest({
          "X-Mcp-Target-Url": "https://auth.example.com/token",
          "X-Mcp-Headers": JSON.stringify({ "Content-Type": "application/x-www-form-urlencoded" }),
          // The caller claims same-origin may be followed: that has no effect on token requests
          "X-Mcp-Redirect": "same-origin",
        }, "grant_type=authorization_code&code=ac-1&code_verifier=cv-1"),
      );
      expect(res.status).toBe(502);
      expect(((await res.json()) as { code: string }).code).toBe("upstream_redirect_blocked");
      expect(captured).toHaveLength(1);
      expect(captured[0].body).toContain("code_verifier=cv-1");
    });

    it("discovery requests (GET .well-known) through the production forward transport: same-origin redirects are followed", async () => {
      setUpstreamRequesterOnce([
        () => new Response(null, { status: 302, headers: { Location: "https://mcp.example.com/.well-known/oauth-protected-resource/mcp" } }),
        () => textResponse('{"resource":"https://mcp.example.com/mcp"}'),
      ]);
      // The headers come from the production forward transport: same-origin requests carry no X-Mcp-Redirect: never.
      let sentRedirectHeader: string | null | undefined;
      const transport = createForwardMcpTransport({
        fetch: async (url, init) => {
          sentRedirectHeader = new Headers(init.headers).get("X-Mcp-Redirect");
          const response = await POST(new Request(`http://localhost${url}`, { method: init.method, headers: init.headers, body: init.body }));
          return { status: response.status, headers: response.headers, body: response.body };
        },
      });
      const res = await transport.send({
        url: "https://mcp.example.com/.well-known/oauth-protected-resource",
        method: "GET",
        headers: { accept: "application/json" },
        redirect: "same-origin",
      });
      expect(res.status).toBe(200);
      expect(sentRedirectHeader).not.toBe("never");
      expect(captured).toHaveLength(2);
      expect(captured[1].url.pathname).toBe("/.well-known/oauth-protected-resource/mcp");
    });

    it("negative: an unrecognised value is a 400 and no upstream request is sent", async () => {
      setUpstreamRequester(() => textResponse("{}"));
      for (const value of ["follow", "manual", "", "never, same-origin"]) {
        const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Redirect": value }, "{}"));
        expect(res.status, value).toBe(400);
      }
      expect(captured).toHaveLength(0);
    });

    it("MCP requests without the header, or with same-origin, are still followed under the same-origin rule", async () => {
      setUpstreamRequesterOnce([sameOriginRedirect(307), () => textResponse('{"ok":true}')]);
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Redirect": "same-origin" }, "{}"));
      expect(res.status).toBe(200);
      expect(captured).toHaveLength(2);
      expect(captured[1].url.pathname).toBe("/elsewhere");
      await res.text();
    });

    it("forward transport of the core module: a redirect never request is not followed once it reaches the route and ends as redirect_rejected", async () => {
      setUpstreamRequester(sameOriginRedirect(307));
      // Production forward transport → production route: the header is produced by the transport itself, not assembled by the test.
      const transport = createForwardMcpTransport({
        fetch: async (url, init) => {
          const response = await POST(new Request(`http://localhost${url}`, { method: init.method, headers: init.headers, body: init.body }));
          return { status: response.status, headers: response.headers, body: response.body };
        },
      });
      const error = await transport.send({
        url: "https://auth.example.com/register",
        method: "POST",
        headers: { accept: "application/json", "content-type": "application/json" },
        body: '{"client_name":"Oriveo"}',
        redirect: "never",
      }).catch((e: unknown) => e);
      expect(error).toBeInstanceOf(McpTransportError);
      expect((error as McpTransportError).kind).toBe("redirect_rejected");
      expect(captured).toHaveLength(1);

      // Same transport: a same-origin request is followed as usual
      captured.length = 0;
      setUpstreamRequesterOnce([sameOriginRedirect(307), () => textResponse('{"ok":true}')]);
      const followed = await transport.send({ url: PUBLIC_TARGET, method: "POST", headers: { "content-type": "application/json" }, body: "{}", redirect: "same-origin" });
      expect(followed.status).toBe(200);
      expect(captured).toHaveLength(2);
    });
  });

  it("credentials and request bodies never reach the logs, and error responses do not echo them either", async () => {
    const consoleSpies = spyOnConsole();
    setUpstreamRequester(() => textResponse('{"result":{"content":[{"type":"text","text":"ok"}]}}'));

    const ok = await POST(
      buildRequest(
        {
          "X-Mcp-Target-Url": `https://mcp.example.com/mcp?access_token=${CREDENTIAL}`,
          "X-Mcp-Credential": CREDENTIAL,
        },
        `{"jsonrpc":"2.0","method":"tools/call","params":{"secretPayload":"${BODY_SECRET}"}}`,
      ),
    );
    expect(ok.status).toBe(200);
    // The target address in the echoed response header is already redacted
    expect(ok.headers.get("X-Mcp-Target-Url") ?? "").not.toContain(CREDENTIAL);

    // The upstream failure path must not put the credential into the error message either
    (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester = async () => {
      throw new Error("connect ECONNREFUSED");
    };
    const failed = await POST(
      buildRequest(
        {
          "X-Mcp-Target-Url": `https://mcp.example.com/mcp?access_token=${CREDENTIAL}`,
          "X-Mcp-Credential": CREDENTIAL,
        },
        BODY_SECRET,
      ),
    );
    expect(failed.status).toBe(502);
    const failedText = await failed.text();
    expect(failedText).not.toContain(CREDENTIAL);
    expect(failedText).not.toContain(BODY_SECRET);

    // Paths rejected by policy do not echo them either
    const blocked = await POST(
      buildRequest({
        "X-Mcp-Target-Url": `https://10.0.0.1/mcp?access_token=${CREDENTIAL}`,
        "X-Mcp-Credential": CREDENTIAL,
      }, BODY_SECRET),
    );
    expect(blocked.status).toBe(403);
    const blockedText = await blocked.text();
    expect(blockedText).not.toContain(CREDENTIAL);
    expect(blockedText).not.toContain(BODY_SECRET);

    expectNoSecretInLogs(consoleSpies);
  });

  it("the three protective cut-off errors the route actually throws are all recognised as expected noise by the Sentry filter", async () => {
    // The message text is an implicit contract between the filter and the route: the filter is fed the errors the route
    // really throws, so this goes red if either side changes the wording (instead of proving the filter with strings the test wrote itself).
    const thrown: Error[] = [];
    const readToError = async (res: Response) => {
      try {
        await res.text();
      } catch (error) {
        thrown.push(error as Error);
      }
    };
    const stalled = () =>
      new Response(new ReadableStream<Uint8Array>({ start() {} }), {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      });

    // (1) Response over the size limit
    setUpstreamRequester(
      () => new Response(byteStream(9 * 1024 * 1024), { status: 200, headers: { "Content-Type": "application/json" } }),
    );
    await readToError(await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET })));

    // (2) Idle timeout: upstream never sends a single byte
    vi.useFakeTimers();
    setUpstreamRequester(stalled);
    const idle = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }));
    const idleRead = readToError(idle);
    await vi.advanceTimersByTimeAsync(90_000);
    await idleRead;

    // (3) Total duration cap: upstream drips one byte every 30 seconds and is never idle
    let drip: ReturnType<typeof setInterval> | undefined;
    setUpstreamRequester(
      () =>
        new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              drip = setInterval(() => {
                try {
                  controller.enqueue(new Uint8Array(1));
                } catch {
                  // The route has already cut the stream
                }
              }, 30_000);
            },
          }),
          { status: 200, headers: { "Content-Type": "text/event-stream" } },
        ),
    );
    const total = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }));
    const totalRead = readToError(total);
    await vi.advanceTimersByTimeAsync(600_000);
    await totalRead;
    if (drip) clearInterval(drip);
    vi.useRealTimers();

    expect(thrown.map((error) => error.message)).toEqual([
      expect.stringMatching(/exceeded the 8MB limit/),
      expect.stringMatching(/idle timeout/),
      expect.stringMatching(/exceeded maximum duration/),
    ]);
    for (const error of thrown) {
      const event = {
        exception: { values: [{ type: "Error", value: "failed to pipe response" }, { type: "Error", value: error.message }] },
      };
      expect(isIgnorableMcpProtectiveAbort(event as never), error.message).toBe(true);
    }
  });

  describe("SSRF negatives (the guard itself is not mocked, only the DNS results are replaced)", () => {
    const mustNotReachUpstream = () =>
      setUpstreamRequester(() => {
        throw new Error("upstream must not be reached");
      });

    async function expectForbidden(target: string) {
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": target }, "{}"));
      expect(res.status, target).toBe(403);
      expect(((await res.json()) as { code: string }).code, target).toBe("endpoint_forbidden");
    }

    it("a hostname resolving to a private / loopback / metadata address is rejected, and so is a mixed public and private result", async () => {
      mustNotReachUpstream();
      for (const addresses of [
        ["10.0.0.5"],
        ["127.0.0.1"],
        ["169.254.169.254"],
        ["172.16.0.9"],
        ["192.168.1.1"],
        ["0.0.0.0"],
        // The first one is public with a private one hidden behind it: a single hit is enough to reject
        ["203.0.113.10", "10.0.0.5"],
      ]) {
        mocks.resolve4.mockResolvedValue(addresses);
        await expectForbidden("https://rebind.example.com/mcp");
      }
      expect(captured).toHaveLength(0);
    });

    it("a hostname whose AAAA record points at an IPv4-mapped / ULA / link-local address is rejected", async () => {
      mustNotReachUpstream();
      for (const addresses of [["::ffff:169.254.169.254"], ["::ffff:a00:1"], ["fd00::1"], ["fe80::1"], ["::1"]]) {
        mocks.resolve4.mockResolvedValue(["203.0.113.10"]);
        mocks.resolve6.mockResolvedValue(addresses);
        await expectForbidden("https://v6rebind.example.com/mcp");
      }
      expect(captured).toHaveLength(0);
    });

    it("IPv4-mapped IPv6 literals and decimal / octal / hex / shortened IPv4 literals are rejected", async () => {
      mustNotReachUpstream();
      vi.stubEnv("NODE_ENV", "production");
      for (const target of [
        "https://[::ffff:10.0.0.1]/mcp",
        "https://[::ffff:127.0.0.1]/mcp",
        "https://[::ffff:7f00:1]/mcp",
        "https://[::ffff:169.254.169.254]/latest/meta-data",
        "https://[0:0:0:0:0:ffff:c0a8:101]/mcp",
        "https://2130706433/mcp", // 127.0.0.1
        "https://167772161/mcp", // 10.0.0.1
        "https://0177.0.0.1/mcp", // 127.0.0.1
        "https://0x7f.0.0.1/mcp",
        "https://0x7f000001/mcp",
        "https://127.1/mcp",
        "https://0/mcp",
      ]) {
        await expectForbidden(target);
      }
      expect(captured).toHaveLength(0);
      // DNS was never queried: all of these are stopped at the literal stage
      expect(mocks.resolve4).not.toHaveBeenCalled();
    });

    it("the trailing-dot form localhost. is not treated as an allowed dev host and is rejected based on what it resolves to", async () => {
      mustNotReachUpstream();
      mocks.resolve4.mockImplementation(async (hostname: string) =>
        hostname.replace(/\.$/, "") === "localhost" ? ["127.0.0.1"] : ["203.0.113.10"],
      );
      await expectForbidden("https://localhost./mcp");
      await expectForbidden("https://LOCALHOST./mcp");
      expect(captured).toHaveLength(0);
    });

    it("a DNS resolution failure is treated as a rejection (fail-closed)", async () => {
      mustNotReachUpstream();
      mocks.resolve4.mockRejectedValue(new Error("ENOTFOUND"));
      mocks.resolve6.mockRejectedValue(new Error("ENOTFOUND"));
      mocks.lookup.mockRejectedValue(new Error("ENOTFOUND"));
      await expectForbidden("https://nxdomain.example.com/mcp");
      expect(captured).toHaveLength(0);
    });

    it("re-resolves after a redirect: when the same host resolves to a private address the second time it is rejected and no second request is sent", async () => {
      setUpstreamRequester(() => new Response(null, { status: 307, headers: { Location: "/mcp/v2" } }));
      mocks.resolve4.mockResolvedValueOnce(["203.0.113.10"]).mockResolvedValue(["10.0.0.5"]);
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Credential": CREDENTIAL }, "{}"));
      expect(res.status).toBe(403);
      const body = (await res.json()) as { code: string; error: string };
      expect(body.code).toBe("endpoint_forbidden");
      expect(body.error).toMatch(/Redirect target/);
      expect(captured).toHaveLength(1);
      expect(forwardSlotsInUse("unknown")).toBe(0);
    });

    it("re-pins after a redirect: the second hop uses the freshly resolved address and 307 keeps the method and body", async () => {
      setUpstreamRequesterOnce([
        () => new Response(null, { status: 307, headers: { Location: "/mcp/v2?x=1" } }),
        () => textResponse("{}"),
      ]);
      mocks.resolve4.mockResolvedValueOnce(["203.0.113.10"]).mockResolvedValue(["203.0.113.20"]);
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Credential": CREDENTIAL }, '{"a":1}'));
      expect(res.status).toBe(200);
      await res.text();
      expect(captured).toHaveLength(2);
      expect(captured[0].address.address).toBe("203.0.113.10");
      expect(captured[1].address.address).toBe("203.0.113.20");
      expect(captured[1].url.toString()).toBe("https://mcp.example.com/mcp/v2?x=1");
      expect(captured[1].method).toBe("POST");
      expect(captured[1].body).toBe('{"a":1}');
      // Only a same-origin redirect travels with the credential
      expect(captured[1].headers.Authorization).toBe(`Bearer ${CREDENTIAL}`);
    });

    it("same host going from https to http, to a port off the allowlist, or to an address with userinfo: none is followed and the credential does not leave", async () => {
      for (const location of [
        "http://mcp.example.com/mcp",
        "https://mcp.example.com:9999/mcp",
        "https://mcp.example.com:8443/mcp",
        "https://user:pw@mcp.example.com/mcp",
        "https://mcp.example.com.evil.example/mcp",
        "//evil.example.com/mcp",
      ]) {
        captured.length = 0;
        setUpstreamRequester(() => new Response(null, { status: 302, headers: { Location: location } }));
        const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Credential": CREDENTIAL }, "{}"));
        expect(res.status, location).toBe(502);
        expect(((await res.json()) as { code: string }).code, location).toBe("upstream_redirect_blocked");
        expect(captured, location).toHaveLength(1);
      }
    });
  });

  describe("request body limit", () => {
    const LIMIT = 256 * 1024;

    it("exactly at the limit passes, one byte over is a 413", async () => {
      setUpstreamRequester(() => textResponse("{}"));
      const atLimit = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "a".repeat(LIMIT)));
      expect(atLimit.status).toBe(200);
      await atLimit.text();
      expect(captured[0].body).toHaveLength(LIMIT);

      const over = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "a".repeat(LIMIT + 1)));
      expect(over.status).toBe(413);
      expect(((await over.json()) as { code: string }).code).toBe("mcp_request_too_large");
      expect(captured).toHaveLength(1);
      expect(forwardSlotsInUse("unknown")).toBe(0);
    });

    it("the limit is counted in bytes, not characters", async () => {
      setUpstreamRequester(() => textResponse("{}"));
      // Each kana is 3 bytes: the character count is far below the limit while the byte count exceeds it
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "あ".repeat(LIMIT / 3 + 1)));
      expect(res.status).toBe(413);
      expect(captured).toHaveLength(0);
    });

    it("streamed request body without Content-Length: reading stops once the limit is exceeded instead of draining the whole body", async () => {
      setUpstreamRequester(() => {
        throw new Error("upstream must not be reached");
      });
      const chunk = new Uint8Array(64 * 1024);
      let pulled = 0;
      let cancelled = false;
      const endless = new ReadableStream<Uint8Array>({
        pull(controller) {
          pulled += 1;
          controller.enqueue(chunk);
        },
        cancel() {
          cancelled = true;
        },
      });
      const request = new Request("http://localhost/api/mcp/forward", {
        method: "POST",
        headers: { "X-Mcp-Target-Url": PUBLIC_TARGET },
        body: endless,
        duplex: "half",
      } as RequestInit);
      const res = await POST(request);
      expect(res.status).toBe(413);
      expect(cancelled).toBe(true);
      // 256 KB limit / 64 KB per chunk: reading should stop at the 5th chunk (with a little slack for the stream's internal read-ahead)
      expect(pulled).toBeLessThanOrEqual(8);
      expect(captured).toHaveLength(0);
    });

    it("rejects outright when the declared Content-Length is over the limit", async () => {
      setUpstreamRequester(() => {
        throw new Error("upstream must not be reached");
      });
      const res = await POST(
        buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "Content-Length": String(LIMIT + 1) }, "{}"),
      );
      expect(res.status).toBe(413);
      expect(captured).toHaveLength(0);
    });
  });

  describe("client disconnects and stream teardown", () => {
    function stalledSse(): Response {
      return new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("data: first\n\n"));
          },
        }),
        { status: 200, headers: { "Content-Type": "text/event-stream" } },
      );
    }

    it("client disconnects while waiting for upstream response headers: the upstream request is aborted", async () => {
      let upstreamSignal: AbortSignal | undefined;
      (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester = (input) => {
        upstreamSignal = (input as CapturedRequest).signal;
        return new Promise<Response>((_resolve, reject) => {
          upstreamSignal!.addEventListener("abort", () => reject(new Error("MCP upstream request aborted")));
        });
      };
      const client = new AbortController();
      const pending = POST(
        new Request("http://localhost/api/mcp/forward", {
          method: "POST",
          headers: { "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Credential": CREDENTIAL },
          body: "{}",
          signal: client.signal,
        }),
      );
      await expect.poll(() => upstreamSignal !== undefined).toBe(true);
      expect(upstreamSignal!.aborted).toBe(false);
      client.abort();
      const res = await pending;
      expect(upstreamSignal!.aborted).toBe(true);
      expect(res.status).toBe(499);
      expect(await res.text()).not.toContain(CREDENTIAL);
      expect(forwardSlotsInUse("unknown")).toBe(0);
    });

    it("downstream cancels during a streamed response: upstream is aborted, both timers are cleared and the concurrency slot is returned", async () => {
      vi.useFakeTimers();
      setUpstreamRequester(stalledSse);
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
      const reader = res.body!.getReader();
      expect(new TextDecoder().decode((await reader.read()).value)).toBe("data: first\n\n");
      expect(captured[0].signal.aborted).toBe(false);
      expect(forwardSlotsInUse("unknown")).toBe(1);
      expect(vi.getTimerCount()).toBe(2);

      await reader.cancel();
      expect(captured[0].signal.aborted).toBe(true);
      expect(forwardSlotsInUse("unknown")).toBe(0);
      expect(vi.getTimerCount()).toBe(0);
    });

    it("request.signal aborts during a streamed response (client disconnect): upstream is aborted", async () => {
      setUpstreamRequester(stalledSse);
      const client = new AbortController();
      const res = await POST(
        new Request("http://localhost/api/mcp/forward", {
          method: "POST",
          headers: { "X-Mcp-Target-Url": PUBLIC_TARGET },
          body: "{}",
          signal: client.signal,
        }),
      );
      const reader = res.body!.getReader();
      await reader.read();
      client.abort();
      expect(captured[0].signal.aborted).toBe(true);
      await reader.cancel();
      expect(forwardSlotsInUse("unknown")).toBe(0);
    });

    it("read to completion: timers cleared, slot returned, and a later client disconnect does not abort the already finished upstream", async () => {
      vi.useFakeTimers();
      setUpstreamRequester(() => textResponse('{"ok":true}'));
      const client = new AbortController();
      const res = await POST(
        new Request("http://localhost/api/mcp/forward", {
          method: "POST",
          headers: { "X-Mcp-Target-Url": PUBLIC_TARGET },
          body: "{}",
          signal: client.signal,
        }),
      );
      await expect(res.text()).resolves.toBe('{"ok":true}');
      expect(vi.getTimerCount()).toBe(0);
      expect(forwardSlotsInUse("unknown")).toBe(0);
      client.abort();
      expect(captured[0].signal.aborted).toBe(false);
    });

    it("idle timeout and total duration timeout: upstream is aborted and the slot is returned", async () => {
      vi.useFakeTimers();
      setUpstreamRequester(stalledSse);
      const idle = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
      const idleReader = idle.body!.getReader();
      await idleReader.read();
      const idleNext = idleReader.read().catch((error: Error) => error);
      await vi.advanceTimersByTimeAsync(MCP_FORWARD_UPSTREAM_TIMEOUT_SECONDS * 1000 - 1);
      expect(captured[0].signal.aborted).toBe(false);
      await vi.advanceTimersByTimeAsync(1);
      expect(((await idleNext) as Error).message).toMatch(/^MCP stream idle timeout/);
      expect(captured[0].signal.aborted).toBe(true);
      expect(forwardSlotsInUse("unknown")).toBe(0);
      expect(vi.getTimerCount()).toBe(0);
    });

    it("upstream fails mid-read: the error propagates to the reader and the slot is returned", async () => {
      setUpstreamRequester(
        () =>
          new Response(
            new ReadableStream<Uint8Array>({
              pull(controller) {
                controller.error(new Error("aborted"));
              },
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          ),
      );
      const res = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
      await expect(res.text()).rejects.toThrow("aborted");
      expect(forwardSlotsInUse("unknown")).toBe(0);
    });
  });

  describe("timeouts versus callTimeoutSeconds (the transport-level timeout is strictly greater than the call timeout)", () => {
    /** Upstream never answers with response headers until it is aborted. Records who aborted it and at which millisecond. */
    function stallUpstream() {
      const state: { signal?: AbortSignal; abortedAt: number | null } = { abortedAt: null };
      (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester = (input) => {
        const signal = (input as CapturedRequest).signal;
        state.signal = signal;
        return new Promise<Response>((_resolve, reject) => {
          signal.addEventListener("abort", () => {
            state.abortedAt = Date.now();
            reject(new Error("MCP upstream request aborted"));
          });
        });
      };
      return state;
    }

    /** Production forward transport → production route. `signal` is wired to the route's request.signal the way a browser fetch would. */
    function forwardTransportThroughRoute() {
      return createForwardMcpTransport({
        fetch: async (url, init) => {
          const response = await POST(new Request(`http://localhost${url}`, { method: init.method, headers: init.headers, body: init.body, signal: init.signal }));
          return { status: response.status, headers: response.headers, body: response.body };
        },
      });
    }

    it("the route's response-header deadline = the call timeout ceiling + a margin; when it expires the answer is mcp_upstream_timeout", async () => {
      vi.useFakeTimers();
      const upstream = stallUpstream();
      const pending = POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
      await vi.advanceTimersByTimeAsync(MCP_FORWARD_MAX_CALL_TIMEOUT_SECONDS * 1000);
      // The call timeout ceiling has passed and the route is still waiting: it never declares a timeout before the client does.
      expect(upstream.signal?.aborted).toBe(false);
      await vi.advanceTimersByTimeAsync((MCP_FORWARD_UPSTREAM_TIMEOUT_SECONDS - MCP_FORWARD_MAX_CALL_TIMEOUT_SECONDS) * 1000);
      const res = await pending;
      expect(res.status).toBe(502);
      expect(((await res.json()) as { code: string }).code).toBe("mcp_upstream_timeout");
      expect(MCP_FORWARD_UPSTREAM_TIMEOUT_SECONDS).toBeGreaterThan(MCP_FORWARD_MAX_CALL_TIMEOUT_SECONDS);
    });

    it("every callTimeoutSeconds tier in the runtime config (including the default 60 and the cap 600): the client's call timeout always fires first, not the route", async () => {
      for (const configured of [5, 30, 50, 60, 120, 600]) {
        vi.useFakeTimers({ now: 0 });
        __resetRateLimitForTests();
        __resetMcpForwardConcurrencyForTests();
        const upstream = stallUpstream();
        const client = new McpClient({
          endpoint: PUBLIC_TARGET,
          transport: forwardTransportThroughRoute(),
          runtimeConfig: { ...MCP_RUNTIME_CONFIG_FALLBACK, callTimeoutSeconds: configured },
        });
        const outcome = client.connect();
        const effective = Math.min(configured, MCP_FORWARD_MAX_CALL_TIMEOUT_SECONDS) * 1000;
        await vi.advanceTimersByTimeAsync(effective - 1);
        expect(upstream.abortedAt, `callTimeoutSeconds=${configured}`).toBeNull();
        await vi.advanceTimersByTimeAsync(1);
        const settled = await outcome;
        expect(settled.kind, `callTimeoutSeconds=${configured}`).toBe("failed");
        const error = settled.kind === "failed" ? settled.error : null;
        expect(error).toBeInstanceOf(McpClientError);
        expect(error?.code).toBe("timeout");
        // Upstream was aborted at the moment of the call timeout because the client disconnected; the route's own deadline had not been reached yet.
        expect(upstream.abortedAt).toBe(effective);
        expect(effective).toBeLessThan(MCP_FORWARD_UPSTREAM_TIMEOUT_SECONDS * 1000);
        vi.useRealTimers();
      }
    });
  });

  describe("per-IP concurrency limit", () => {
    it("concurrent forwards from one IP get 429 once the limit is reached and recover when one finishes; other IPs are unaffected", async () => {
      const controllers: Array<ReadableStreamDefaultController<Uint8Array>> = [];
      setUpstreamRequester(
        () =>
          new Response(
            new ReadableStream<Uint8Array>({
              start(controller) {
                controllers.push(controller);
              },
            }),
            { status: 200, headers: { "Content-Type": "text/event-stream" } },
          ),
      );
      const ipA = { "X-Mcp-Target-Url": PUBLIC_TARGET, "x-forwarded-for": "198.51.100.7" };
      const open: Response[] = [];
      for (let i = 0; i < MAX_CONCURRENT_FORWARDS_PER_IP; i++) {
        const res = await POST(buildRequest(ipA, "{}"));
        expect(res.status).toBe(200);
        open.push(res);
      }
      expect(MAX_CONCURRENT_FORWARDS_PER_IP).toBe(8);
      expect(forwardSlotsInUse("198.51.100.7")).toBe(8);

      const rejected = await POST(buildRequest(ipA, "{}"));
      expect(rejected.status).toBe(429);
      expect(((await rejected.json()) as { code: string }).code).toBe("mcp_too_many_concurrent_requests");
      expect(captured).toHaveLength(8);

      // Other IPs have their own slots
      const other = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "x-forwarded-for": "198.51.100.8" }, "{}"));
      expect(other.status).toBe(200);
      await other.body!.cancel();

      // Once one is read to the end (upstream finished normally) a slot frees up
      controllers[0].close();
      await open[0].text();
      expect(forwardSlotsInUse("198.51.100.7")).toBe(7);
      const admitted = await POST(buildRequest(ipA, "{}"));
      expect(admitted.status).toBe(200);

      await admitted.body!.cancel();
      for (const res of open.slice(1)) await res.body!.cancel();
      expect(forwardSlotsInUse("198.51.100.7")).toBe(0);
    });

    it("rejected or early-failing requests do not take a slot", async () => {
      setUpstreamRequester(() => {
        throw new Error("connect ECONNREFUSED");
      });
      const headers = { "x-forwarded-for": "198.51.100.9" };
      for (let i = 0; i < 20; i++) {
        const failed = await POST(buildRequest({ ...headers, "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
        expect(failed.status).toBe(502);
        const blocked = await POST(buildRequest({ ...headers, "X-Mcp-Target-Url": "https://10.0.0.1/mcp" }, "{}"));
        expect(blocked.status).toBe(403);
      }
      expect(forwardSlotsInUse("198.51.100.9")).toBe(0);
    });
  });

  it("secrets in the path, userinfo and the query string are redacted in the echoed header and in error bodies", async () => {
    const pathSecret = "sk1234567890abcdefghij";
    const target = `https://mcp.example.com/${pathSecret}/mcp?access_token=${CREDENTIAL}&plain=${BODY_SECRET}`;
    setUpstreamRequester(() => textResponse("{}"));
    const ok = await POST(buildRequest({ "X-Mcp-Target-Url": target }, "{}"));
    expect(ok.status).toBe(200);
    expect(ok.headers.get("X-Mcp-Target-Url")).toBe("https://mcp.example.com/***/mcp?***");
    await ok.text();
    // Upstream still receives the full address
    expect(captured[0].url.toString()).toBe(target);

    (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester = async () => {
      throw new Error("connect ECONNREFUSED");
    };
    const failed = await POST(buildRequest({ "X-Mcp-Target-Url": target }, "{}"));
    expect(failed.status).toBe(502);
    const failedText = await failed.text();
    expect(failedText).toContain("[upstream: https://mcp.example.com/***/mcp?***]");
    expect(failedText).not.toContain(pathSecret);
    expect(failedText).not.toContain(CREDENTIAL);
    expect(failedText).not.toContain(BODY_SECRET);

    // Redirect to a same-origin address with a secret in the path: the echoed value is the final address, redacted as well
    setUpstreamRequesterOnce([
      () => new Response(null, { status: 307, headers: { Location: `/${pathSecret}/v2?token=abc` } }),
      () => textResponse("{}"),
    ]);
    const redirected = await POST(buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET }, "{}"));
    expect(redirected.headers.get("X-Mcp-Target-Url")).toBe("https://mcp.example.com/***/v2?***");
    await redirected.text();

    // A target address with userinfo is rejected outright and the error body does not echo it
    const userinfo = await POST(buildRequest({ "X-Mcp-Target-Url": "https://user:hunter2@mcp.example.com/mcp" }, "{}"));
    expect(userinfo.status).toBe(400);
    expect(await userinfo.text()).not.toContain("hunter2");
  });

  it("negative: an overlong credential is rejected and the error body does not echo it", async () => {
    setUpstreamRequester(() => {
      throw new Error("upstream must not be reached");
    });
    const res = await POST(
      buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Credential": "t".repeat(8193) }, "{}"),
    );
    expect(res.status).toBe(400);
    expect(await res.text()).not.toContain("tttt");
    expect(captured).toHaveLength(0);

    setUpstreamRequester(() => textResponse("{}"));
    const atLimit = await POST(
      buildRequest({ "X-Mcp-Target-Url": PUBLIC_TARGET, "X-Mcp-Credential": "t".repeat(8192) }, "{}"),
    );
    expect(atLimit.status).toBe(200);
  });

  it("returns 400 when the target address is missing", async () => {
    const res = await POST(buildRequest({ "Content-Type": "application/json" }));
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/Missing X-Mcp-Target-Url/);
  });

  it("returns 429 once the rate limit quota is exceeded (guards against open-proxy abuse)", async () => {
    const headers = { "Content-Type": "application/json", "x-forwarded-for": "198.51.100.91" };
    for (let i = 0; i < 60; i++) {
      expect((await POST(buildRequest(headers))).status).toBe(400);
    }
    expect((await POST(buildRequest(headers))).status).toBe(429);
  });
});

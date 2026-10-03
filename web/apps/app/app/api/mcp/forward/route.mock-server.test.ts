// @vitest-environment node
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetRateLimitForTests } from "../../chat/stream/rate-limit";
import { __resetMcpForwardConcurrencyForTests, forwardSlotsInUse } from "./concurrency";
import { DELETE, GET, POST } from "./route";
import { requestUpstreamWithPinnedAddress, type UpstreamRequestInput } from "./upstream-request";

/**
 * Forward route × the shared mock server (`shared/test-fixtures/mcp/mock-server.mjs`, used by all clients).
 *
 * This answers what unit tests cannot: whether a server that validates request headers the way the
 * MCP specification requires accepts the requests the route really sends, and whether the session id
 * and authorization challenge it answers with reach the browser.
 *
 * Upstream requests are sent by the **production requester**; only the destination is swapped: the
 * route sees a public https address (and runs the full SSRF guard), and at the moment of sending the
 * request is pointed at the mock server on the loopback address (which only speaks http).
 */

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

type MockModule = {
  createMockServer: (args: Record<string, unknown>) => Server;
  parseArgs: (argv: string[]) => Record<string, unknown>;
};
type TestGlobal = typeof globalThis & {
  __oriveoMcpForwardUpstreamRequester?: (input: UpstreamRequestInput) => Promise<Response>;
};

const TOKEN = "mcp_test_token_for_forward";
const PUBLIC_ORIGIN = "https://mcp.example.com";
const MODERN_META = {
  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
  "io.modelcontextprotocol/clientInfo": { name: "Oriveo", version: "1.0.0" },
  "io.modelcontextprotocol/clientCapabilities": {},
};

const servers: Server[] = [];
let mockModule: MockModule;

async function startMock(...flags: string[]): Promise<number> {
  const server = mockModule.createMockServer(mockModule.parseArgs(["node", "mock-server.mjs", ...flags]));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  servers.push(server);
  return (server.address() as AddressInfo).port;
}

/** Points the route's upstream requests at the local mock server and hands everything else to the production requester unchanged. */
function routeUpstreamTo(port: number): void {
  (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester = (input) => {
    const rewritten = new URL(`${input.url.pathname}${input.url.search}`, `http://127.0.0.1:${port}`);
    return requestUpstreamWithPinnedAddress(
      { ...input, url: rewritten, address: { address: "127.0.0.1", family: 4 } },
      { pinAddress: true },
    );
  };
}

function forward(
  handler: (request: Request) => Promise<Response>,
  init: { path?: string; method?: string; headers?: Record<string, string>; credential?: string; body?: unknown },
): Promise<Response> {
  const method = init.method ?? "POST";
  const headers: Record<string, string> = { "X-Mcp-Target-Url": `${PUBLIC_ORIGIN}${init.path ?? "/mcp"}` };
  if (init.headers) headers["X-Mcp-Headers"] = JSON.stringify(init.headers);
  if (init.credential) headers["X-Mcp-Credential"] = init.credential;
  return handler(
    new Request("http://localhost/api/mcp/forward", {
      method,
      headers,
      ...(method === "POST" ? { body: JSON.stringify(init.body ?? {}) } : {}),
    }),
  );
}

function toolsCall(id: number) {
  return {
    jsonrpc: "2.0",
    id,
    method: "tools/call",
    params: { name: "get_weather", arguments: { city: "Berlin" }, _meta: MODERN_META },
  };
}

beforeAll(async () => {
  // The fixture is an .mjs under the repository root (shared by all clients, no type declarations);
  // import it from a path computed at run time and take the types from MockModule above.
  const fixture = pathToFileURL(
    resolve(__dirname, "../../../../../../../shared/test-fixtures/mcp/mock-server.mjs"),
  ).href;
  mockModule = (await import(/* @vite-ignore */ fixture)) as MockModule;
});

afterAll(async () => {
  for (const server of servers) {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

beforeEach(() => {
  __resetRateLimitForTests();
  __resetMcpForwardConcurrencyForTests();
  mocks.resolve4.mockResolvedValue(["203.0.113.10"]);
  mocks.resolve6.mockRejectedValue(new Error("ENODATA"));
  mocks.lookup.mockResolvedValue([{ address: "203.0.113.10", family: 4 }]);
});

afterEach(() => {
  delete (globalThis as TestGlobal).__oriveoMcpForwardUpstreamRequester;
  expect(forwardSlotsInUse("unknown")).toBe(0);
});

describe("forward route × mock MCP server", () => {
  it("modern protocol (2026-07-28): a tools/call carrying both Mcp-Method and Mcp-Name is accepted", async () => {
    routeUpstreamTo(await startMock("--mode=stateless"));
    const res = await forward(POST, {
      headers: { "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_weather" },
      body: toolsCall(1),
    });
    expect(res.status).toBe(200);
    const payload = (await res.json()) as { id: number; result?: { content: unknown[] }; error?: unknown };
    expect(payload.error).toBeUndefined();
    expect(payload.id).toBe(1);
    expect(Array.isArray(payload.result?.content)).toBe(true);
  });

  it("counter-check: the same request without those two headers gets 400 + -32020 from the mock server", async () => {
    routeUpstreamTo(await startMock("--mode=stateless"));
    const withoutMethod = await forward(POST, {
      headers: { "MCP-Protocol-Version": "2026-07-28" },
      body: toolsCall(2),
    });
    expect(withoutMethod.status).toBe(400);
    expect(((await withoutMethod.json()) as { error: { code: number } }).error.code).toBe(-32020);

    const withoutName = await forward(POST, {
      headers: { "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call" },
      body: toolsCall(3),
    });
    expect(withoutName.status).toBe(400);
    expect(((await withoutName.json()) as { error: { code: number } }).error.code).toBe(-32020);
  });

  it("an SSE reply of the modern protocol is streamed back unchanged", async () => {
    routeUpstreamTo(await startMock("--mode=stateless", "--sse"));
    const res = await forward(POST, {
      headers: { "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list" },
      body: { jsonrpc: "2.0", id: 4, method: "tools/list", params: { _meta: MODERN_META } },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toContain("text/event-stream");
    const text = await res.text();
    expect(text).toContain("data:");
    expect(text).toContain("get_weather");
  });

  it("legacy protocol (2025-11-25): the session id from initialize is handed back to the browser and is required to continue; termination via DELETE goes through", async () => {
    routeUpstreamTo(await startMock("--mode=session"));
    const initialized = await forward(POST, {
      body: {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "Oriveo", version: "1.0.0" } },
      },
    });
    expect(initialized.status).toBe(200);
    await initialized.text();
    const sessionId = initialized.headers.get("X-Mcp-Session-Id");
    expect(sessionId).toMatch(/^sess_[0-9a-f]{16}$/);

    const listed = await forward(POST, {
      headers: { "MCP-Protocol-Version": "2025-11-25", "MCP-Session-Id": sessionId! },
      body: { jsonrpc: "2.0", id: 2, method: "tools/list" },
    });
    expect(listed.status).toBe(200);
    expect(JSON.stringify(await listed.json())).toContain("get_weather");

    // Counter-check: without the session header the legacy server answers 400 (exactly what a user would hit if the response header were lost)
    const withoutSession = await forward(POST, {
      headers: { "MCP-Protocol-Version": "2025-11-25" },
      body: { jsonrpc: "2.0", id: 3, method: "tools/list" },
    });
    expect(withoutSession.status).toBe(400);
    await withoutSession.text();

    // A 202 with an empty body in reply to a notification does not hang
    const notified = await forward(POST, {
      headers: { "MCP-Protocol-Version": "2025-11-25", "MCP-Session-Id": sessionId! },
      body: { jsonrpc: "2.0", method: "notifications/initialized" },
    });
    expect(notified.status).toBe(202);
    await expect(notified.text()).resolves.toBe("");

    const terminated = await forward(DELETE, { method: "DELETE", headers: { "MCP-Session-Id": sessionId! } });
    // The mock server answers DELETE with 405 (the specification allows it); what is checked is that the request reached upstream and the status came back unchanged
    expect(terminated.status).toBe(405);
    await terminated.text();
  });

  it("token required: without a credential the 401 authorization challenge is handed back to the browser, and with the credential the request passes", async () => {
    routeUpstreamTo(await startMock("--mode=token", `--token=${TOKEN}`));
    const request = {
      headers: { "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list" },
      body: { jsonrpc: "2.0", id: 1, method: "tools/list", params: { _meta: MODERN_META } },
    };
    const unauthorized = await forward(POST, request);
    expect(unauthorized.status).toBe(401);
    expect(unauthorized.headers.get("X-Mcp-WWW-Authenticate")).toBe('Bearer, scope="files:read files:write"');
    await unauthorized.text();

    const wrong = await forward(POST, { ...request, credential: "not-the-token" });
    expect(wrong.status).toBe(401);
    await wrong.text();

    const authorized = await forward(POST, { ...request, credential: TOKEN });
    expect(authorized.status).toBe(200);
    expect(JSON.stringify(await authorized.json())).toContain("get_weather");
  });

  it("OAuth: resource_metadata from the challenge is handed back and both well-known metadata documents can be fetched via GET", async () => {
    routeUpstreamTo(await startMock("--mode=oauth-cimd"));
    const unauthorized = await forward(POST, {
      headers: { "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list" },
      body: { jsonrpc: "2.0", id: 1, method: "tools/list", params: { _meta: MODERN_META } },
    });
    expect(unauthorized.status).toBe(401);
    expect(unauthorized.headers.get("X-Mcp-WWW-Authenticate")).toMatch(
      /^Bearer, resource_metadata="[^"]+\/\.well-known\/oauth-protected-resource", scope="files:read files:write"$/,
    );
    await unauthorized.text();

    const resource = await forward(GET, { method: "GET", path: "/.well-known/oauth-protected-resource" });
    expect(resource.status).toBe(200);
    expect(Object.keys((await resource.json()) as object)).toContain("authorization_servers");

    const authServer = await forward(GET, { method: "GET", path: "/.well-known/oauth-authorization-server" });
    expect(authServer.status).toBe(200);
    const metadata = (await authServer.json()) as Record<string, unknown>;
    expect(metadata.client_id_metadata_document_supported).toBe(true);
    expect(typeof metadata.token_endpoint).toBe("string");
  });
});

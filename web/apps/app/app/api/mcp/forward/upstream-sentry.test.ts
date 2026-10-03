// @vitest-environment node
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import https from "node:https";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import * as Sentry from "@sentry/nextjs";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { edgeSentryHooks, serverSentryHooks } from "../../../../lib/sentry/server-before-send";
import { requestUpstreamWithPinnedAddress } from "./upstream-request";

/**
 * The address of an upstream MCP server must not reach server-side Sentry.
 *
 * There are no hand-written breadcrumbs or spans here: the real `@sentry/nextjs` server SDK is
 * initialized with the production redaction hooks (`serverSentryHooks`, the object
 * `sentry.server.config.ts` spreads), real requests go to a real https server on local loopback,
 * and the assertions are made on the envelopes the SDK actually hands to the transport.
 *
 * Each of the two layers is tested on its own:
 * - the production requester sends its request in a "no tracing" context, so the SDK records no
 *   breadcrumb, opens no span and adds no tracing headers to the upstream request;
 * - should that layer ever fail and the SDK record breadcrumbs and spans as usual (reproduced here
 *   with a bare `https.request` that bypasses the requester), the redaction hooks still mask every
 *   address of this origin and remove the fields that hold the hostname / path / query string
 *   separately.
 */

vi.unmock("@sentry/nextjs");

const HOSTNAME = "mcp-secret-host.test.example";
// Hostname used only by the control case: it never goes through the production requester, so it is
// never registered.
const CONTROL_HOSTNAME = "never-forwarded.test.example";
const PATH_SECRET = "sk-path-0123456789abcdef";
const QUERY_SECRET = "qs-0123456789abcdef";
const TARGET_PATH = `/hooks/${PATH_SECRET}/mcp?session=${QUERY_SECRET}&api_key=${QUERY_SECRET}`;

let server: https.Server;
let port: number;
let ca: string;
let certDir: string;
const upstreamSaw: Array<Record<string, string | string[] | undefined>> = [];
const envelopes: unknown[] = [];

function target(hostname: string = HOSTNAME): URL {
  return new URL(`https://${hostname}:${port}${TARGET_PATH}`);
}

/** One upstream request sent by the production requester (connection pinned to local loopback). */
async function forwarded(): Promise<number> {
  const response = await requestUpstreamWithPinnedAddress(
    {
      url: target(),
      method: "POST",
      headers: { Accept: "application/json" },
      body: "{}",
      signal: new AbortController().signal,
      address: { address: "127.0.0.1", family: 4 },
    },
    { pinAddress: true, ca },
  );
  await response.text();
  return response.status;
}

/** Everything the SDK has handed to the transport so far. */
async function shipped(): Promise<string> {
  await Sentry.flush(2000);
  return JSON.stringify(envelopes);
}

function expectNoTargetLeak(payload: string): void {
  expect(payload).not.toContain(HOSTNAME);
  expect(payload).not.toContain(PATH_SECRET);
  expect(payload).not.toContain(QUERY_SECRET);
}

/**
 * A request of the same shape that bypasses the production requester: the SDK's http integration
 * records a breadcrumb and opens a span for it as usual.
 */
function rawRequest(hostname: string = HOSTNAME): Promise<number> {
  const url = target(hostname);
  return new Promise<number>((resolvePromise, reject) => {
    const request = https.request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port,
        path: `${url.pathname}${url.search}`,
        method: "POST",
        headers: { Host: url.host, Accept: "application/json" },
        servername: url.hostname,
        ca,
        lookup: (_hostname, options, callback) => {
          if (typeof options === "object" && options?.all) {
            (callback as unknown as (error: null, addresses: Array<{ address: string; family: number }>) => void)(null, [{ address: "127.0.0.1", family: 4 }]);
            return;
          }
          callback(null, "127.0.0.1", 4);
        },
      },
      (response) => {
        response.resume();
        response.once("end", () => resolvePromise(response.statusCode ?? 0));
      },
    );
    request.once("error", reject);
    request.end("{}");
  });
}

type Hooks = Partial<typeof serverSentryHooks | typeof edgeSentryHooks>;
type InitOptions = NonNullable<Parameters<typeof Sentry.init>[0]>;

/**
 * The SDK can be initialized only once per process (a second `init` call in `@sentry/nextjs` returns
 * immediately), so each of the four hook slots holds a forwarder that delegates to the set of
 * production hooks chosen by the current test case; with none chosen (the control case) events pass
 * through untouched.
 */
let activeHooks: Hooks = {};

function useHooks(hooks: Hooks): void {
  activeHooks = hooks;
}

function initSentryOnce(): void {
  const options: InitOptions = {
    dsn: "https://public@o0.ingest.invalid/1",
    tracesSampleRate: 1,
    transport: () => ({
      send: async (envelope: unknown) => {
        envelopes.push(envelope);
        return {};
      },
      flush: async () => true,
    }),
    beforeSend: (event, hint) => (activeHooks.beforeSend ? activeHooks.beforeSend(event, hint) : event),
    beforeSendTransaction: (event) => (activeHooks.beforeSendTransaction ? activeHooks.beforeSendTransaction(event) : event),
    beforeSendSpan: (span) => (activeHooks.beforeSendSpan ? activeHooks.beforeSendSpan(span) : span),
    beforeBreadcrumb: (breadcrumb) => (activeHooks.beforeBreadcrumb ? activeHooks.beforeBreadcrumb(breadcrumb) : breadcrumb),
  };
  Sentry.init(options);
}

beforeAll(async () => {
  certDir = mkdtempSync(join(tmpdir(), "oriveo-mcp-forward-sentry-"));
  const keyPath = join(certDir, "key.pem");
  const certPath = join(certDir, "cert.pem");
  execFileSync(
    "openssl",
    [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", keyPath, "-out", certPath, "-days", "2",
      "-subj", `/CN=${HOSTNAME}`,
      "-addext", `subjectAltName=DNS:${HOSTNAME},DNS:${CONTROL_HOSTNAME}`,
    ],
    { stdio: "ignore" },
  );
  ca = readFileSync(certPath, "utf8");
  server = https.createServer({ key: readFileSync(keyPath), cert: ca }, (req, res) => {
    req.resume();
    req.on("end", () => {
      upstreamSaw.push(req.headers);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end('{"jsonrpc":"2.0","id":1,"result":{}}');
    });
  });
  await new Promise<void>((resolvePromise) => server.listen(0, "127.0.0.1", resolvePromise));
  port = (server.address() as AddressInfo).port;
  initSentryOnce();
});

afterAll(async () => {
  await Sentry.close(2000);
  server.closeAllConnections();
  await new Promise<void>((resolvePromise) => server.close(() => resolvePromise()));
  rmSync(certDir, { recursive: true, force: true });
});

beforeEach(async () => {
  await Sentry.flush(2000);
  // Breadcrumbs live on the scope; unless cleared, those of the previous case are sent along with
  // the events of the next one.
  Sentry.getGlobalScope().clear();
  Sentry.getIsolationScope().clear();
  Sentry.getCurrentScope().clear();
  envelopes.length = 0;
  upstreamSaw.length = 0;
});

describe("control: without the redaction hooks the SDK really does record the upstream address", () => {
  it("bare https request: breadcrumb and span carry hostname, path and query string, and the upstream receives tracing headers", async () => {
    useHooks({});
    await Sentry.startSpan({ name: "POST /api/mcp/forward", forceTransaction: true }, async () => {
      expect(await rawRequest(CONTROL_HOSTNAME)).toBe(200);
      Sentry.captureMessage("after raw upstream request");
    });
    const payload = await shipped();
    // This control guards the premise of the cases below: the SDK's http integration is active in
    // this test environment.
    expect(payload).toContain('"category":"http"');
    expect(payload).toContain('"op":"http.client"');
    expect(payload).toContain(CONTROL_HOSTNAME);
    expect(payload).toContain(PATH_SECRET);
    expect(payload).toContain(QUERY_SECRET);
    expect(upstreamSaw[0]).toHaveProperty("sentry-trace");
  });
});

describe("production requester: the upstream request is not traced by the SDK", () => {
  it("records no breadcrumb, opens no span, adds no tracing headers upstream; everything else in the same transaction is still reported", async () => {
    useHooks(serverSentryHooks);
    await Sentry.startSpan({ name: "POST /api/mcp/forward", forceTransaction: true }, async () => {
      expect(await forwarded()).toBe(200);
      Sentry.captureMessage("after forwarded upstream request");
    });
    const payload = await shipped();
    // The event and the transaction were both sent (the SDK as a whole did not go silent).
    expect(payload).toContain("after forwarded upstream request");
    expect(payload).toContain("POST /api/mcp/forward");
    expect(payload).not.toContain('"category":"http"');
    expect(payload).not.toContain('"op":"http.client"');
    expectNoTargetLeak(payload);
    expect(upstreamSaw).toHaveLength(1);
    expect(upstreamSaw[0]).not.toHaveProperty("sentry-trace");
    expect(upstreamSaw[0]).not.toHaveProperty("baggage");
  });
});

describe("second layer: when the SDK records breadcrumbs and spans as usual, the redaction hooks mask the registered origin entirely", () => {
  for (const [runtime, hooks] of [["Node", serverSentryHooks], ["edge", edgeSentryHooks]] as const) {
    it(`${runtime} runtime hooks: the http breadcrumb and http.client span are present, but without hostname, path or query string`, async () => {
      useHooks(hooks);
      // The origin is registered by the production requester when it sends a request; the test does
      // not register it itself.
      expect(await forwarded()).toBe(200);
      upstreamSaw.length = 0;
      await Sentry.startSpan({ name: "POST /api/mcp/forward", forceTransaction: true }, async () => {
        expect(await rawRequest()).toBe(200);
        Sentry.captureMessage("after raw upstream request");
      });
      const payload = await shipped();
      expect(payload).toContain('"category":"http"');
      expect(payload).toContain('"op":"http.client"');
      expect(payload).toContain('"url":"https://<mcp-direct>"');
      expect(payload).toContain('"description":"POST https://<mcp-direct>"');
      expectNoTargetLeak(payload);
      // The peer IP and port also say "where the connection went".
      expect(payload).not.toContain("network.peer.address");
      expect(payload).not.toContain("net.peer.ip");
      expect(payload).not.toContain(String(port));
    });
  }
});

describe("the config files of both runtimes use exactly these hooks", () => {
  const appRoot = resolve(__dirname, "../../../..");
  it("sentry.server.config.ts spreads serverSentryHooks, sentry.edge.config.ts spreads edgeSentryHooks", () => {
    expect(readFileSync(resolve(appRoot, "sentry.server.config.ts"), "utf8")).toContain("...serverSentryHooks,");
    expect(readFileSync(resolve(appRoot, "sentry.edge.config.ts"), "utf8")).toContain("...edgeSentryHooks,");
    expect(Object.keys(serverSentryHooks).sort()).toEqual(["beforeBreadcrumb", "beforeSend", "beforeSendSpan", "beforeSendTransaction"]);
    expect(Object.keys(edgeSentryHooks).sort()).toEqual(["beforeBreadcrumb", "beforeSend", "beforeSendSpan", "beforeSendTransaction"]);
  });
});

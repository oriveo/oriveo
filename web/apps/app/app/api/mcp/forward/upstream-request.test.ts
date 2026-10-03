// @vitest-environment node
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import https from "node:https";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TLSSocket } from "node:tls";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { requestUpstreamWithPinnedAddress, toFetchResponse } from "./upstream-request";

/**
 * Direct coverage of the production requester: requests go to a real https server on local loopback.
 *
 * The certificate is signed with openssl when the test starts (SAN = mcp.test.example) and is
 * trusted only inside this file (the `ca` option). The hostname `mcp.test.example` does not exist in
 * DNS (`.example` is a reserved TLD), so the very fact that a request reaches this loopback server
 * proves the connection used the pinned address rather than a resolution result.
 */

const HOSTNAME = "mcp.test.example";

interface Seen {
  method: string;
  url: string;
  headers: Record<string, string | string[] | undefined>;
  body: string;
  servername: string | false | null | undefined;
}

let server: https.Server;
let port: number;
let ca: string;
let certDir: string;
const seen: Seen[] = [];
const openSockets = new Set<TLSSocket>();
let abortedByClient = 0;

function target(path: string): URL {
  return new URL(`https://${HOSTNAME}:${port}${path}`);
}

function send(path: string, init: { method?: "GET" | "POST" | "DELETE"; body?: string; signal?: AbortSignal; headers?: Record<string, string> } = {}) {
  return requestUpstreamWithPinnedAddress(
    {
      url: target(path),
      method: init.method ?? "POST",
      headers: init.headers ?? { Accept: "application/json" },
      body: init.body,
      signal: init.signal ?? new AbortController().signal,
      address: { address: "127.0.0.1", family: 4 },
    },
    { pinAddress: true, ca },
  );
}

beforeAll(async () => {
  certDir = mkdtempSync(join(tmpdir(), "oriveo-mcp-forward-cert-"));
  const keyPath = join(certDir, "key.pem");
  const certPath = join(certDir, "cert.pem");
  execFileSync(
    "openssl",
    [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", keyPath, "-out", certPath, "-days", "2",
      "-subj", `/CN=${HOSTNAME}`,
      "-addext", `subjectAltName=DNS:${HOSTNAME}`,
    ],
    { stdio: "ignore" },
  );
  ca = readFileSync(certPath, "utf8");

  server = https.createServer({ key: readFileSync(keyPath), cert: ca }, (req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      seen.push({
        method: req.method ?? "",
        url: req.url ?? "",
        headers: req.headers,
        body: Buffer.concat(chunks).toString("utf8"),
        servername: (req.socket as TLSSocket).servername,
      });
      const path = (req.url ?? "").split("?")[0];
      if (path === "/no-content") {
        res.writeHead(204, { "Mcp-Session-Id": "gone" }).end();
      } else if (path === "/reset-content") {
        res.writeHead(205).end();
      } else if (path === "/not-modified") {
        res.writeHead(304).end();
      } else if (path === "/redirect") {
        res.writeHead(307, { Location: "/mcp" }).end();
      } else if (path === "/unauthorized") {
        res.writeHead(401, {
          "Content-Type": "application/json",
          "WWW-Authenticate": ['Bearer realm="a"', 'Bearer error="invalid_token"'],
          "Set-Cookie": ["a=1", "b=2"],
        }).end('{"error":"unauthorized"}');
      } else if (path === "/stream") {
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        res.write("data: first\n\n");
        req.socket.once("close", () => {
          abortedByClient += 1;
        });
        // Deliberately left open: wait for the client to abort.
      } else if (path === "/hang") {
        req.socket.once("close", () => {
          abortedByClient += 1;
        });
        // Not even response headers are sent.
      } else if (path === "/drop") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.write('{"partial":');
        setTimeout(() => req.socket.destroy(), 20);
      } else {
        res.writeHead(200, { "Content-Type": "application/json", "Mcp-Session-Id": "session-1" });
        res.end('{"jsonrpc":"2.0","id":1,"result":{}}');
      }
    });
  });
  server.on("secureConnection", (socket) => {
    openSockets.add(socket);
    socket.once("close", () => openSockets.delete(socket));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  port = (server.address() as AddressInfo).port;
});

afterAll(async () => {
  for (const socket of openSockets) socket.destroy();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  rmSync(certDir, { recursive: true, force: true });
});

beforeEach(() => {
  seen.length = 0;
  abortedByClient = 0;
});

describe("requestUpstreamWithPinnedAddress (real https loopback server)", () => {
  it("pins to the given address while Host and SNI keep the original hostname, and the body carries Content-Length", async () => {
    const body = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}';
    const res = await send("/mcp?x=1", {
      body,
      headers: { Accept: "application/json, text/event-stream", "Content-Type": "application/json", "mcp-method": "tools/list" },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("mcp-session-id")).toBe("session-1");
    await expect(res.text()).resolves.toBe('{"jsonrpc":"2.0","id":1,"result":{}}');

    expect(seen).toHaveLength(1);
    expect(seen[0].method).toBe("POST");
    expect(seen[0].url).toBe("/mcp?x=1");
    expect(seen[0].body).toBe(body);
    expect(seen[0].headers.host).toBe(`${HOSTNAME}:${port}`);
    expect(seen[0].servername).toBe(HOSTNAME);
    expect(seen[0].headers["mcp-method"]).toBe("tools/list");
    // A single end(body): fixed length rather than chunked.
    expect(seen[0].headers["content-length"]).toBe(String(Buffer.byteLength(body)));
    expect(seen[0].headers["transfer-encoding"]).toBeUndefined();
  });

  it("the pinned address decides where the connection goes: pinned to ::1, where the server is not listening, the same port is unreachable", async () => {
    // The server listens on 127.0.0.1 only. A different hostname is used so the socket the previous
    // case left in the connection pool is not reused.
    await expect(
      requestUpstreamWithPinnedAddress(
        {
          url: new URL(`https://v6.test.example:${port}/mcp`),
          method: "GET",
          headers: {},
          signal: new AbortController().signal,
          address: { address: "::1", family: 6 },
        },
        { pinAddress: true, ca },
      ),
    ).rejects.toThrow();
    expect(seen).toHaveLength(0);
  });

  it("certificate validation uses the original hostname: a matching pinned address with a mismatching hostname is rejected", async () => {
    await expect(
      requestUpstreamWithPinnedAddress(
        {
          url: new URL(`https://other.test.example:${port}/mcp`),
          method: "GET",
          headers: {},
          signal: new AbortController().signal,
          address: { address: "127.0.0.1", family: 4 },
        },
        { pinAddress: true, ca },
      ),
    ).rejects.toThrow(/altnames|certificate/i);
    // Without ca (the production shape) the self-signed certificate is not trusted.
    await expect(
      requestUpstreamWithPinnedAddress(
        {
          url: target("/mcp"),
          method: "GET",
          headers: {},
          signal: new AbortController().signal,
          address: { address: "127.0.0.1", family: 4 },
        },
        { pinAddress: true },
      ),
    ).rejects.toThrow(/self[- ]signed|certificate/i);
    expect(seen).toHaveLength(0);
  });

  it("204 / 205 / 304: settles immediately as a null-body response, neither throwing nor hanging", async () => {
    for (const [path, status] of [["/no-content", 204], ["/reset-content", 205], ["/not-modified", 304]] as const) {
      const res = await send(path, { method: "DELETE" });
      expect(res.status).toBe(status);
      expect(res.body).toBeNull();
    }
    const noContent = await send("/no-content", { method: "DELETE" });
    expect(noContent.headers.get("mcp-session-id")).toBe("gone");
  });

  it("3xx is returned as is (the route decides whether to follow) and multi-value response headers are kept", async () => {
    const redirect = await send("/redirect");
    expect(redirect.status).toBe(307);
    expect(redirect.headers.get("location")).toBe("/mcp");
    await redirect.body?.cancel();

    const unauthorized = await send("/unauthorized");
    expect(unauthorized.status).toBe(401);
    expect(unauthorized.headers.get("www-authenticate")).toContain('Bearer realm="a"');
    expect(unauthorized.headers.get("www-authenticate")).toContain('error="invalid_token"');
    expect(unauthorized.headers.getSetCookie()).toEqual(["a=1", "b=2"]);
    await expect(unauthorized.text()).resolves.toBe('{"error":"unauthorized"}');
  });

  it("abort before response headers arrive: the Promise rejects and the server-side connection is closed", async () => {
    const controller = new AbortController();
    const pending = send("/hang", { signal: controller.signal });
    await expect.poll(() => seen.length).toBe(1);
    controller.abort();
    await expect(pending).rejects.toThrow("MCP upstream request aborted");
    await expect.poll(() => abortedByClient).toBe(1);
  });

  it("abort in the middle of a streaming response: the reader gets an error and the server-side connection is closed", async () => {
    const controller = new AbortController();
    const res = await send("/stream", { signal: controller.signal });
    const reader = res.body!.getReader();
    const first = await reader.read();
    expect(new TextDecoder().decode(first.value)).toBe("data: first\n\n");
    controller.abort();
    await expect(reader.read()).rejects.toThrow("MCP upstream request aborted");
    await expect.poll(() => abortedByClient).toBe(1);
  });

  it("signal already aborted before the call: no request is sent", async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(send("/mcp", { signal: controller.signal })).rejects.toThrow("MCP upstream request aborted");
    expect(seen).toHaveLength(0);
  });

  it("upstream disconnects midway: the reader gets an error instead of a silent truncation", async () => {
    const res = await send("/drop");
    expect(res.status).toBe(200);
    await expect(res.text()).rejects.toThrow();
  });

  it("connection refused: the Promise rejects", async () => {
    const closed = https.createServer();
    await new Promise<void>((resolve) => closed.listen(0, "127.0.0.1", resolve));
    const closedPort = (closed.address() as AddressInfo).port;
    await new Promise<void>((resolve) => closed.close(() => resolve()));
    await expect(
      requestUpstreamWithPinnedAddress(
        {
          url: new URL(`https://${HOSTNAME}:${closedPort}/mcp`),
          method: "GET",
          headers: {},
          signal: new AbortController().signal,
          address: { address: "127.0.0.1", family: 4 },
        },
        { pinAddress: true, ca },
      ),
    ).rejects.toThrow(/ECONNREFUSED/);
  });
});

describe("toFetchResponse (status code to Response)", () => {
  const body = () => new ReadableStream<Uint8Array>({ start: (controller) => controller.close() });

  it("null-body status codes do not open the response body", () => {
    for (const status of [204, 205, 304]) {
      let opened = false;
      const res = toFetchResponse(status, {}, () => {
        opened = true;
        return body();
      });
      expect(res.status).toBe(status);
      expect(res.body).toBeNull();
      expect(opened).toBe(false);
    }
  });

  it("all other 2xx-5xx statuses carry a response body", () => {
    for (const status of [200, 202, 301, 401, 404, 500, 599]) {
      const res = toFetchResponse(status, { "content-type": "application/json" }, body);
      expect(res.status).toBe(status);
      expect(res.body).not.toBeNull();
      expect(res.headers.get("content-type")).toBe("application/json");
    }
  });

  it("a status code Response cannot represent throws (the caller rejects) instead of hanging", () => {
    for (const status of [undefined, 0, 100, 199, 600, 999, 200.5, Number.NaN]) {
      expect(() => toFetchResponse(status, {}, body), String(status)).toThrow("unusable status code");
    }
  });

  it("a single invalid response header is dropped without taking down the whole response", () => {
    const res = toFetchResponse(
      200,
      { "content-type": "application/json", "bad header name": "x", "x-ok": ["a", "b"], "x-undefined": undefined },
      body,
    );
    expect(res.headers.get("content-type")).toBe("application/json");
    expect(res.headers.get("x-ok")).toBe("a, b");
    expect(res.headers.has("x-undefined")).toBe(false);
  });
});

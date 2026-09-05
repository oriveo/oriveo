import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Readable } from "node:stream";
import { GET, POST } from "./route";
import { __resetRateLimitForTests } from "../../chat/stream/rate-limit";

type HttpsRequestMock = (
  options: import("node:https").RequestOptions,
  callback: (response: unknown) => void,
) => unknown;

const mocks = vi.hoisted(() => ({
  lookup: vi.fn(),
  resolve4: vi.fn(),
  resolve6: vi.fn(),
  httpsRequest: vi.fn<HttpsRequestMock>(),
}));

vi.mock("node:dns/promises", () => ({
  default: { lookup: mocks.lookup, resolve4: mocks.resolve4, resolve6: mocks.resolve6 },
  lookup: mocks.lookup,
  resolve4: mocks.resolve4,
  resolve6: mocks.resolve6,
}));

vi.mock("node:https", () => ({
  default: { request: mocks.httpsRequest },
  request: mocks.httpsRequest,
}));

type TestGlobal = typeof globalThis & {
  __oriveoRelayForwardUpstreamRequester?: (input: unknown) => Promise<Response>;
};

function setRelayForwardUpstreamRequesterForTest(
  requester?: (input: unknown) => Promise<Response>,
): void {
  if (requester) {
    (globalThis as TestGlobal).__oriveoRelayForwardUpstreamRequester = requester;
  } else {
    delete (globalThis as TestGlobal).__oriveoRelayForwardUpstreamRequester;
  }
}

function buildRequest(
  headers: Record<string, string>,
  body: string = '{"hello":"world"}',
): Request {
  return new Request("http://localhost/api/relay/forward", {
    method: "POST",
    headers,
    body,
  });
}

describe("/api/relay/forward", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
    vi.unstubAllEnvs();
    setRelayForwardUpstreamRequesterForTest();
    mocks.lookup.mockReset();
    mocks.resolve4.mockReset();
    mocks.resolve6.mockReset();
    mocks.httpsRequest.mockReset();
  });

  beforeEach(() => {
    __resetRateLimitForTests();
    // resolve4 returns a single public IP by default; resolve6 rejects to simulate no IPv6 record
    mocks.resolve4.mockResolvedValue(["203.0.113.10"]);
    mocks.resolve6.mockRejectedValue(new Error("ENODATA"));
    // lookup is mocked as a fallback as well, for compatibility with older assertions
    mocks.lookup.mockResolvedValue([{ address: "203.0.113.10", family: 4 }]);
  });

  it("returns 429 when a relay endpoint exceeds its rate limit quota, preventing open-proxy abuse", async () => {
    const headers = { "Content-Type": "application/json", "x-forwarded-for": "198.51.100.77" };
    // Inside the quota (60 requests): the missing upstream url header returns 400 early, proving the request got past the rate limiter
    for (let i = 0; i < 60; i++) {
      expect((await POST(buildRequest(headers))).status).toBe(400);
    }
    // Request 61: the same IP trips the rate limit
    expect((await POST(buildRequest(headers))).status).toBe(429);
  });

  it("returns 400 when X-Relay-Upstream-URL is missing", async () => {
    const res = await POST(buildRequest({ "Content-Type": "application/json" }));
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/Missing X-Relay-Upstream-URL/);
  });

  it("returns 400 when the upstream URL is invalid", async () => {
    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "not-a-url",
      }),
    );
    expect(res.status).toBe(400);
  });

  it("returns 400 when the structured proxy config is missing", async () => {
    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
      }),
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/Missing X-Relay-Proxy-Config/);
  });

  it("returns 400 when the structured proxy config is invalid", async () => {
    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": "{not-json",
      }),
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/Invalid X-Relay-Proxy-Config/);
  });

  it("rejects schemes other than http and https", async () => {
    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "file:///etc/passwd",
      }),
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/Unsupported upstream scheme/);
  });

  it("rejects an http upstream in production", async () => {
    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "http://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": JSON.stringify({ transport: "openai_responses", authMode: "bearer" }),
      }),
    );
    expect(res.status).toBe(403);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe("endpoint_forbidden");
  });

  it("rejects private and metadata IPs to prevent SSRF", async () => {
    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://169.254.169.254/latest/meta-data",
        "X-Relay-Proxy-Config": JSON.stringify({ transport: "openai_responses", authMode: "bearer" }),
      }),
    );
    expect(res.status).toBe(403);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe("endpoint_forbidden");
  });

  it("rejects hostnames that resolve to private addresses to prevent DNS rebinding SSRF", async () => {
    mocks.resolve4.mockResolvedValueOnce(["10.0.0.5"]);
    mocks.resolve6.mockRejectedValueOnce(new Error("ENODATA"));
    mocks.lookup.mockResolvedValueOnce([{ address: "10.0.0.5", family: 4 }]);

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": JSON.stringify({ transport: "openai_responses", authMode: "bearer" }),
      }),
    );

    expect(res.status).toBe(403);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe("endpoint_forbidden");
  });

  it("rejects IPv4-mapped IPv6 results that resolve to private addresses", async () => {
    mocks.resolve4.mockRejectedValueOnce(new Error("ENODATA"));
    mocks.resolve6.mockResolvedValueOnce(["::ffff:127.0.0.1"]);
    mocks.lookup.mockResolvedValueOnce([{ address: "::ffff:127.0.0.1", family: 6 }]);

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": JSON.stringify({ transport: "openai_responses", authMode: "bearer" }),
      }),
    );

    expect(res.status).toBe(403);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe("endpoint_forbidden");
  });

  it.each(["fe90::1", "febf::1"])("rejects the whole fe80::/10 IPv6 link-local range: %s", async (address) => {
    mocks.resolve4.mockRejectedValueOnce(new Error("ENODATA"));
    mocks.resolve6.mockResolvedValueOnce([address]);
    mocks.lookup.mockResolvedValueOnce([{ address, family: 6 }]);

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": JSON.stringify({ transport: "openai_responses", authMode: "bearer" }),
      }),
    );

    expect(res.status).toBe(403);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe("endpoint_forbidden");
  });

  it("builds the Codex identity and custom UA and headers on the Node side from the structured config", async () => {
    const requestMock = vi.fn().mockResolvedValue(
      new Response("{}", {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    setRelayForwardUpstreamRequesterForTest(requestMock);

    const res = await POST(
      buildRequest(
        {
          "Content-Type": "application/json",
          "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
          "X-Relay-Proxy-Config": JSON.stringify({
            transport: "openai_responses",
            authMode: "bearer",
            apiKey: "sk-test",
            codexCompatIdentity: true,
            customUserAgent: "Oriveo Test UA",
            headers: [{ key: "Originator", value: "custom-origin" }],
          }),
        },
        '{"model":"gpt-5"}',
      ),
    );

    expect(res.status).toBe(200);
    const [{ url, method, headers, body, address }] = requestMock.mock.calls[0];
    expect(url.toString()).toBe("https://relay.example.com/v1/responses");
    expect(method).toBe("POST");
    expect(body).toBe('{"model":"gpt-5"}');
    expect(address.address).toBe("203.0.113.10");
    expect(headers.Authorization).toBe("Bearer sk-test");
    expect(headers["User-Agent"]).toBe("Oriveo Test UA");
    expect(headers.Originator).toBe("custom-origin");
    expect(headers.session_id).toBeTruthy();
    expect(headers["OpenAI-Beta"]).toBe("responses=experimental");
  });

  it("revalidates same-origin redirects hop by hop and follows them, with 307 preserving the POST body and credentials", async () => {
    const requestMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, {
        status: 307,
        headers: { Location: "/gateway/v1/responses" },
      }))
      .mockResolvedValueOnce(new Response("{}", {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }));
    setRelayForwardUpstreamRequesterForTest(requestMock);

    const res = await POST(buildRequest({
      "Content-Type": "application/json",
      "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
      "X-Relay-Proxy-Config": JSON.stringify({
        transport: "openai_responses",
        authMode: "bearer",
        apiKey: "sk-test",
      }),
    }, '{"model":"gpt-5"}'));

    expect(res.status).toBe(200);
    expect(requestMock).toHaveBeenCalledTimes(2);
    const first = requestMock.mock.calls[0][0];
    const second = requestMock.mock.calls[1][0];
    expect(first.url.toString()).toBe("https://relay.example.com/v1/responses");
    expect(second.url.toString()).toBe("https://relay.example.com/gateway/v1/responses");
    expect(second.method).toBe("POST");
    expect(second.body).toBe('{"model":"gpt-5"}');
    expect(second.headers.Authorization).toBe("Bearer sk-test");
    expect(res.headers.get("X-Relay-Upstream-URL")).toBe(
      "https://relay.example.com/gateway/v1/responses",
    );
    expect(mocks.resolve4).toHaveBeenCalledTimes(2);
  });

  it("blocks a cross-origin redirect immediately and never sends relay credentials to the second origin", async () => {
    const requestMock = vi.fn().mockResolvedValueOnce(new Response(null, {
      status: 302,
      headers: { Location: "https://attacker.example/v1/responses" },
    }));
    setRelayForwardUpstreamRequesterForTest(requestMock);

    const res = await POST(buildRequest({
      "Content-Type": "application/json",
      "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
      "X-Relay-Proxy-Config": JSON.stringify({
        transport: "openai_responses",
        authMode: "bearer",
        apiKey: "sk-test",
      }),
    }));

    expect(res.status).toBe(502);
    await expect(res.json()).resolves.toMatchObject({ code: "upstream_redirect_blocked" });
    expect(requestMock).toHaveBeenCalledTimes(1);
  });

  it("the production pinned lookup supports the Node all:true DNS callback shape", async () => {
    vi.stubEnv("NODE_ENV", "production");
    let pinnedAddresses: unknown;
    mocks.httpsRequest.mockImplementation((options, callback) => {
      expect(options.lookup).toBeTypeOf("function");
      options.lookup!("relay.example.com", { all: true }, (error: unknown, addresses: unknown) => {
        expect(error).toBeNull();
        pinnedAddresses = addresses;
      });

      const request = new Readable({ read() {} });
      Object.assign(request, {
        write: vi.fn(),
        destroy: vi.fn((_error?: Error) => request),
        end: () => {
        const response = Readable.from([Buffer.from("{}")]) as Readable & {
          statusCode: number;
          headers: Record<string, string>;
        };
        response.statusCode = 200;
        response.headers = { "content-type": "application/json" };
        callback(response);
        },
      });
      return request;
    });

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "openai_responses",
          authMode: "bearer",
          apiKey: "sk-test",
        }),
      }),
    );

    const text = await res.text();
    expect(res.status).toBe(200);
    expect(text).toBe("{}");
    expect(pinnedAddresses).toEqual([{ address: "203.0.113.10", family: 4 }]);
  });

  it("passes an upstream 4xx status and body through", async () => {
    setRelayForwardUpstreamRequesterForTest(vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: "quota" }), {
        status: 429,
        headers: { "Content-Type": "application/json" },
      }),
    ));

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/chat/completions",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "openai_chat_completions",
          authMode: "bearer",
          apiKey: "sk-test",
        }),
      }),
    );

    expect(res.status).toBe(429);
    expect(res.headers.get("X-Oriveo-Error-Source")).toBe("provider");
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe("quota");
  });

  it("returns 502 when the upstream fetch throws", async () => {
    setRelayForwardUpstreamRequesterForTest(vi.fn().mockRejectedValue(new Error("ECONNREFUSED")));

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/chat/completions",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "openai_chat_completions",
          authMode: "bearer",
          apiKey: "sk-test",
        }),
      }),
    );

    expect(res.status).toBe(502);
    expect(res.headers.get("X-Oriveo-Error-Source")).toBe("network");
    const body = (await res.json()) as { error: string; code: string };
    expect(body.error).toMatch(/ECONNREFUSED/);
    expect(body.code).toBe("relay_upstream_connection_failed");
  });

  it("returns a quietable timeout code when upstream response headers take more than 30 seconds", async () => {
    vi.useFakeTimers();
    setRelayForwardUpstreamRequesterForTest(vi.fn((rawInput: unknown) => new Promise<Response>((_, reject) => {
      const input = rawInput as { signal: AbortSignal };
      input.signal.addEventListener("abort", () => {
        reject(new Error("Relay upstream request aborted"));
      }, { once: true });
    })));

    const pending = POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/chat/completions",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "openai_chat_completions",
          authMode: "bearer",
          apiKey: "sk-test",
        }),
      }),
    );
    await vi.advanceTimersByTimeAsync(30_000);

    const res = await pending;
    expect(res.status).toBe(502);
    expect(res.headers.get("X-Oriveo-Error-Source")).toBe("network");
    await expect(res.json()).resolves.toMatchObject({
      code: "relay_upstream_timeout",
      error: expect.stringMatching(/request aborted/),
    });
  });

  it("does not abort when upstream response headers take more than 5 seconds but are still inside the first-packet protection window", async () => {
    vi.useFakeTimers();
    const requestMock = vi.fn((rawInput: unknown) => new Promise<Response>((resolve, reject) => {
      const input = rawInput as { signal: AbortSignal };
      const timer = setTimeout(() => {
        input.signal.removeEventListener("abort", onAbort);
        resolve(new Response("{}", {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }));
      }, 6_500);
      const onAbort = () => {
        clearTimeout(timer);
        reject(new Error("Relay upstream request aborted"));
      };
      input.signal.addEventListener("abort", onAbort, { once: true });
    }));
    setRelayForwardUpstreamRequesterForTest(requestMock);

    const pending = POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/messages",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "anthropic_messages",
          authMode: "x_api_key",
          apiKey: "sk-test",
        }),
      }),
    );
    await vi.advanceTimersByTimeAsync(6_500);

    const res = await pending;
    expect(res.status).toBe(200);
    await expect(res.text()).resolves.toBe("{}");
    vi.useRealTimers();
  });

  it("proxies the GET /models ping and generates Authorization on the Node side", async () => {
    const requestMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ data: [] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    setRelayForwardUpstreamRequesterForTest(requestMock);

    const res = await GET(
      buildRequest({
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/models",
        "X-Relay-Upstream-Method": "GET",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "openai_chat_completions",
          authMode: "bearer",
          apiKey: "sk-test",
        }),
      }),
    );

    expect(res.status).toBe(200);
    const [{ url, method, body, headers }] = requestMock.mock.calls[0];
    expect(url.toString()).toBe("https://relay.example.com/v1/models");
    expect(method).toBe("GET");
    expect(body).toBeUndefined();
    expect(headers.Authorization).toBe("Bearer sk-test");
  });

  it("aborts the upstream on idle timeout after 90 seconds without data on a streaming response", async () => {
    vi.useFakeTimers();
    const abortSpy = vi.fn();
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("data: {}\n\n"));
      },
      cancel: abortSpy,
    });
    setRelayForwardUpstreamRequesterForTest(vi.fn().mockResolvedValue(
      new Response(stream, {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      }),
    ));

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "openai_responses",
          authMode: "bearer",
          apiKey: "sk-test",
        }),
      }),
    );
    const reader = res.body!.getReader();
    await expect(reader.read()).resolves.toMatchObject({ done: false });
    const pendingRead = reader.read().catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(90_000);
    await expect(pendingRead).resolves.toMatchObject({
      message: expect.stringMatching(/idle timeout/),
    });
    vi.useRealTimers();
  });

  it("resets the idle timer while data keeps arriving, so the stream survives past 90 seconds", async () => {
    vi.useFakeTimers();
    let enqueue!: (chunk: Uint8Array) => void;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        enqueue = (chunk) => controller.enqueue(chunk);
        enqueue(new TextEncoder().encode("data: {}\n\n"));
      },
    });
    setRelayForwardUpstreamRequesterForTest(vi.fn().mockResolvedValue(
      new Response(stream, {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      }),
    ));

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "openai_responses",
          authMode: "bearer",
          apiKey: "sk-test",
        }),
      }),
    );
    const reader = res.body!.getReader();
    await expect(reader.read()).resolves.toMatchObject({ done: false });

    // Cross four 60s windows, feeding a chunk just before the 90s idle limit each time
    for (let i = 0; i < 4; i++) {
      await vi.advanceTimersByTimeAsync(60_000);
      enqueue(new TextEncoder().encode("data: keep-alive\n\n"));
      await expect(reader.read()).resolves.toMatchObject({ done: false });
    }
    vi.useRealTimers();
  });

  it("cuts the stream off on the total timeout past 600 seconds even while data keeps arriving", async () => {
    vi.useFakeTimers();
    let enqueue!: (chunk: Uint8Array) => void;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        enqueue = (chunk) => controller.enqueue(chunk);
        enqueue(new TextEncoder().encode("data: {}\n\n"));
      },
    });
    setRelayForwardUpstreamRequesterForTest(vi.fn().mockResolvedValue(
      new Response(stream, {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      }),
    ));

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "openai_responses",
          authMode: "bearer",
          apiKey: "sk-test",
        }),
      }),
    );
    const reader = res.body!.getReader();
    await expect(reader.read()).resolves.toMatchObject({ done: false });

    // Feed once every 60s, crossing the 10 minute (600s) total limit
    for (let i = 0; i < 9; i++) {
      await vi.advanceTimersByTimeAsync(60_000);
      enqueue(new TextEncoder().encode("data: keep-alive\n\n"));
      await expect(reader.read()).resolves.toMatchObject({ done: false });
    }

    const pendingRead = reader.read().catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(60_000);
    await expect(pendingRead).resolves.toMatchObject({
      message: expect.stringMatching(/exceeded maximum duration/),
    });
    vi.useRealTimers();
  });

  // Image generation traffic regression: a Responses image stream is preview frames plus the final
  // image, all base64, and one preview plus one final image already measures 9.83MB. A 10MB limit
  // would cut a normal generation off midway, which the client only sees as a network error, so
  // the limit is 64MB. This locks in that a 16MB-class stream passes through in full.
  it("passes an image-generation-sized stream (16MB) through in full without hitting the response body limit", async () => {
    const oneMB = new Uint8Array(1024 * 1024).fill(97);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        for (let i = 0; i < 16; i++) controller.enqueue(oneMB);
        controller.close();
      },
    });
    setRelayForwardUpstreamRequesterForTest(vi.fn().mockResolvedValue(
      new Response(stream, {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      }),
    ));

    const res = await POST(
      buildRequest({
        "Content-Type": "application/json",
        "X-Relay-Upstream-URL": "https://relay.example.com/v1/responses",
        "X-Relay-Proxy-Config": JSON.stringify({
          transport: "openai_responses",
          authMode: "bearer",
          apiKey: "sk-test",
        }),
      }),
    );

    const reader = res.body!.getReader();
    let received = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value!.byteLength;
    }
    expect(received).toBe(16 * 1024 * 1024);
  });
});

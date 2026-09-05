import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

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

import {
  assertUrlNotSsrf,
  isForbiddenIPv4,
  isForbiddenIPv6,
  SsrfBlockedError,
} from "./ssrf-guard";

describe("ssrf-guard", () => {
  beforeEach(() => {
    // Default public resolution result.
    mocks.resolve4.mockResolvedValue(["203.0.113.10"]);
    mocks.resolve6.mockRejectedValue(new Error("ENODATA"));
    mocks.lookup.mockResolvedValue([{ address: "203.0.113.10", family: 4 }]);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    mocks.lookup.mockReset();
    mocks.resolve4.mockReset();
    mocks.resolve6.mockReset();
  });

  it("allows a public domain and returns the resolved address", async () => {
    const result = await assertUrlNotSsrf("https://api.openai.com/v1/chat/completions");
    expect(result.address.address).toBe("203.0.113.10");
  });

  it("blocks non-http(s) protocols", async () => {
    await expect(assertUrlNotSsrf("file:///etc/passwd")).rejects.toBeInstanceOf(SsrfBlockedError);
  });

  it("blocks a malformed URL", async () => {
    await expect(assertUrlNotSsrf("not-a-url")).rejects.toBeInstanceOf(SsrfBlockedError);
  });

  it("blocks a port outside the allowlist", async () => {
    await expect(assertUrlNotSsrf("https://api.example.com:9999/v1")).rejects.toBeInstanceOf(
      SsrfBlockedError,
    );
  });

  it("blocks cloud metadata IP literals without any DNS lookup", async () => {
    await expect(assertUrlNotSsrf("https://169.254.169.254/latest")).rejects.toBeInstanceOf(
      SsrfBlockedError,
    );
  });

  it("blocks private IP literals", async () => {
    await expect(assertUrlNotSsrf("https://10.0.0.5:8080/v1")).rejects.toBeInstanceOf(
      SsrfBlockedError,
    );
  });

  it("rejects plain http public domains in production", async () => {
    vi.stubEnv("NODE_ENV", "production");
    await expect(assertUrlNotSsrf("http://api.example.com/v1")).rejects.toBeInstanceOf(
      SsrfBlockedError,
    );
  });

  it("blocks a domain that resolves to a private address (DNS rebinding)", async () => {
    mocks.resolve4.mockResolvedValueOnce(["10.0.0.5"]);
    mocks.resolve6.mockRejectedValueOnce(new Error("ENODATA"));
    mocks.lookup.mockResolvedValueOnce([{ address: "10.0.0.5", family: 4 }]);
    await expect(assertUrlNotSsrf("https://rebind.example.com/v1")).rejects.toBeInstanceOf(
      SsrfBlockedError,
    );
  });

  it("blocks an IPv4-mapped IPv6 result in private space", async () => {
    mocks.resolve4.mockRejectedValueOnce(new Error("ENODATA"));
    mocks.resolve6.mockResolvedValueOnce(["::ffff:127.0.0.1"]);
    mocks.lookup.mockResolvedValueOnce([{ address: "::ffff:127.0.0.1", family: 6 }]);
    await expect(assertUrlNotSsrf("https://rebind6.example.com/v1")).rejects.toBeInstanceOf(
      SsrfBlockedError,
    );
  });

  it("fails closed when DNS resolution fails", async () => {
    mocks.resolve4.mockRejectedValueOnce(new Error("ENOTFOUND"));
    mocks.resolve6.mockRejectedValueOnce(new Error("ENOTFOUND"));
    mocks.lookup.mockRejectedValueOnce(new Error("ENOTFOUND"));
    await expect(assertUrlNotSsrf("https://nx.example.com/v1")).rejects.toBeInstanceOf(
      SsrfBlockedError,
    );
  });

  describe("isForbiddenIPv4", () => {
    it.each(["0.0.0.0", "10.1.2.3", "127.0.0.1", "169.254.169.254", "172.16.0.1", "192.168.1.1"])(
      "blocks private and reserved %s",
      (ip) => expect(isForbiddenIPv4(ip)).toBe(true),
    );
    it.each(["203.0.113.10", "8.8.8.8", "1.1.1.1"])("allows public %s", (ip) =>
      expect(isForbiddenIPv4(ip)).toBe(false),
    );
    // Matching the relay and forward paths, 198.18.0.0/15 is deliberately not included, to avoid blocking the fake IPs a TUN proxy hands out.
    it("allows 198.18.x, the benchmark range, for proxy compatibility", () => {
      expect(isForbiddenIPv4("198.18.0.27")).toBe(false);
    });
  });

  describe("isForbiddenIPv6", () => {
    it.each(["::1", "::", "fc00::1", "fd12::1", "fe80::1", "febf::1"])("blocks reserved %s", (ip) =>
      expect(isForbiddenIPv6(ip)).toBe(true),
    );
    it("allows public 2606:4700::1111", () => expect(isForbiddenIPv6("2606:4700::1111")).toBe(false));
  });
});

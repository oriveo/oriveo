// Shared server-side SSRF protection.
//
// Every route that performs a server-side fetch against a user-supplied baseURL must call
// assertUrlNotSsrf first, otherwise an attacker can make the Node process hit internal hosts or
// cloud metadata endpoints such as 169.254.169.254.
//
// The checks are:
// - protocol allowlist (http/https only)
// - port allowlist (ALLOWED_PORTS)
// - private / reserved / link-local / cloud-metadata IP denylist (isForbiddenIPv4/6)
// - every resolved IP is checked after DNS resolution (defeats DNS rebinding); in production the
//   resolved address is pinned
// - localhost is allowed in dev, which local debugging behind a fake-IP proxy needs
//
// The IP denylist deliberately does not cover benchmark ranges such as 198.18.0.0/15, matching
// relay/forward: doing so breaks development behind a TUN proxy (Clash/Surge), where public
// domains resolve into the fake-IP pool.

import type { LookupAddress } from "node:dns";
import { lookup, resolve4, resolve6 } from "node:dns/promises";
import net from "node:net";
// The pure IP denylist lives in @oriveo/core so the server and other hosts share it; re-exported here.
import { isForbiddenIPv4, isForbiddenIPv6 } from "@oriveo/core/providers/ssrf";

export { isForbiddenIPv4, isForbiddenIPv6 };

const ALLOWED_PORTS = new Set(["", "443", "80", "8080", "8443"]);

/** Raised when the SSRF check fails; routes turn this into a 403. */
export class SsrfBlockedError extends Error {
  readonly code = "endpoint_forbidden";
  constructor(message = "Endpoint blocked by server policy") {
    super(message);
    this.name = "SsrfBlockedError";
  }
}

export interface SsrfCheckResult {
  /** The resolved address that passed the check and can be pinned (the host itself when it is an IP literal). */
  address: LookupAddress;
}

/**
 * Check whether a URL is safe to request from the server, throwing SsrfBlockedError otherwise.
 * Accepts a string or a URL; an invalid URL also throws SsrfBlockedError so fetch never sees an
 * unknown protocol.
 *
 * Public provider domains such as api.openai.com are allowed - only private, reserved and
 * metadata addresses are blocked.
 */
export async function assertUrlNotSsrf(rawURL: string | URL): Promise<SsrfCheckResult> {
  let url: URL;
  try {
    url = typeof rawURL === "string" ? new URL(rawURL) : rawURL;
  } catch {
    throw new SsrfBlockedError("Invalid upstream URL");
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new SsrfBlockedError(`Unsupported upstream scheme: ${url.protocol}`);
  }

  if (!ALLOWED_PORTS.has(url.port)) {
    throw new SsrfBlockedError(`Port not allowed: ${url.port}`);
  }

  const allowDevLocal = isAllowedDevHttpHost(url.hostname);
  if (url.protocol === "http:" && !allowDevLocal) {
    throw new SsrfBlockedError("Plain http is not allowed");
  }
  if (!allowDevLocal && isForbiddenAddress(url.hostname)) {
    throw new SsrfBlockedError("Endpoint resolves to a forbidden address");
  }

  try {
    // With all:true, dns/promises lookup returns entries without an address on some Node + Next
    // dev combinations, so resolveAddressesSafe layers resolve4/resolve6, a truthy filter and a
    // single-lookup fallback.
    const addresses = await resolveAddressesSafe(url.hostname);
    if (addresses.length === 0) {
      throw new SsrfBlockedError("Could not resolve host");
    }
    if (!allowDevLocal && addresses.some((entry) => isForbiddenAddress(entry.address))) {
      throw new SsrfBlockedError("Endpoint resolves to a forbidden address");
    }
    const address = addresses.find((entry) => allowDevLocal || !isForbiddenAddress(entry.address));
    if (!address) {
      throw new SsrfBlockedError("Endpoint resolves to a forbidden address");
    }
    return { address };
  } catch (error) {
    if (error instanceof SsrfBlockedError) throw error;
    // Any DNS failure fails closed
    throw new SsrfBlockedError("Could not resolve host");
  }
}

function isValidLookupAddress(entry: unknown): entry is LookupAddress {
  if (!entry || typeof entry !== "object") return false;
  const e = entry as Partial<LookupAddress>;
  return typeof e.address === "string" && (e.family === 4 || e.family === 6);
}

/**
 * Three-layer DNS resolution, in increasing order of reliability:
 * 1. hostname is already an IP literal, so wrap it directly with no DNS
 * 2. localhost and equivalent aliases resolve to a hardcoded 127.0.0.1 + ::1
 * 3. resolve4 + resolve6 return string[], a completely stable shape
 *    Last-resort fallback: if both fail, use dns.lookup (keeps older Node behavior working)
 */
export async function resolveAddressesSafe(hostname: string): Promise<LookupAddress[]> {
  const stripped = hostname.replace(/^\[|\]$/g, "");
  const ipVer = net.isIP(stripped);
  if (ipVer === 4) return [{ address: stripped, family: 4 }];
  if (ipVer === 6) return [{ address: stripped, family: 6 }];

  if (hostname === "localhost") {
    return [
      { address: "127.0.0.1", family: 4 },
      { address: "::1", family: 6 },
    ];
  }

  const [v4, v6] = await Promise.allSettled([resolve4(hostname), resolve6(hostname)]);
  const out: LookupAddress[] = [];
  if (v4.status === "fulfilled") {
    for (const addr of v4.value) {
      if (typeof addr === "string" && net.isIP(addr) === 4) {
        out.push({ address: addr, family: 4 });
      }
    }
  }
  if (v6.status === "fulfilled") {
    for (const addr of v6.value) {
      if (typeof addr === "string" && net.isIP(addr) === 6) {
        out.push({ address: addr, family: 6 });
      }
    }
  }

  if (out.length === 0) {
    try {
      const fallback = await lookup(hostname, { verbatim: true });
      if (Array.isArray(fallback)) {
        const valid = fallback.filter(isValidLookupAddress);
        if (valid.length > 0) return valid;
      } else if (isValidLookupAddress(fallback)) {
        return [fallback];
      }
    } catch {
      // Let the caller see an empty array, which is treated as forbidden
    }
  }
  return out;
}

export function isAllowedDevHttpHost(hostname: string): boolean {
  if (process.env.NODE_ENV === "production") return false;
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
}

export function isForbiddenAddress(hostname: string): boolean {
  const normalized = hostname.replace(/^\[|\]$/g, "");
  const version = net.isIP(normalized);
  if (version === 4) return isForbiddenIPv4(normalized);
  if (version === 6) return isForbiddenIPv6(normalized);
  return false;
}

export const SSRF_ALLOWED_PORTS = ALLOWED_PORTS;

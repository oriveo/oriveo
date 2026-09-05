/**
 * Pure SSRF IP denylist: private, reserved, loopback, link-local and cloud metadata
 * (169.254.169.254) ranges.
 *
 * Zero-dependency string parsing that never touches node:net or node:dns, shared by the desktop
 * main process and the server-side API routes. DNS resolution, the net.isIP check and the
 * assertUrlNotSsrf orchestration stay with each host, which injects its own node:dns.
 *
 * Note: benchmark ranges such as 198.18.0.0/15 are deliberately excluded, matching the relay and
 * forward paths. Including them would break development machines behind a TUN proxy such as Clash
 * or Surge, where public domains resolve into a fake IP pool.
 */

/**
 * Forbidden CIDRs, kept in step one-to-one with isForbiddenIPv4/6 below and locked by ssrf.test.
 * The desktop main process builds an undici `connect.blockList` (net.BlockList) from these to
 * reject the real IP after DNS resolution but before connecting, closing the DNS rebinding TOCTOU
 * window. The server side validates after resolution with isForbiddenIPv4/6. One source of truth.
 */
export const FORBIDDEN_IPV4_CIDRS = [
  '0.0.0.0/8',
  '10.0.0.0/8',
  '127.0.0.0/8',
  '169.254.0.0/16',
  '172.16.0.0/12',
  '192.168.0.0/16',
  // Multicast and reserved ranges, including the 255.255.255.255 broadcast address - no legitimate
  // API endpoint lives here, so denying them costs nothing. 100.64.0.0/10 (CGNAT/Tailscale) is
  // deliberately left out: it would break a BYOK relay self-hosted on a tailnet, a legitimate case.
  '224.0.0.0/4',
  '240.0.0.0/4',
] as const;

export const FORBIDDEN_IPV6_CIDRS = [
  '::/128',
  '::1/128',
  'fc00::/7',
  'fe80::/10',
] as const;

export function isForbiddenIPv4(address: string): boolean {
  const parts = address.split('.').map((part) => Number(part));
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return true;
  }
  const [a, b] = parts;
  return (
    a === 0
    || a === 10
    || a === 127
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 168)
    || a >= 224 // 224/4 multicast plus 240/4 reserved, including the 255.255.255.255 broadcast address
  );
}

export function isForbiddenIPv6(address: string): boolean {
  const lower = address.toLowerCase();
  // IPv4-mapped in dotted-decimal form, for example ::ffff:169.254.169.254.
  const mappedIPv4 = lower.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mappedIPv4) return isForbiddenIPv4(mappedIPv4[1]);
  // IPv4-mapped in hextet form, for example ::ffff:a9fe:a9fe. WHATWG `new URL()` normalizes
  // ::ffff:169.254.169.254 into that form, so a regex matching only dotted decimal missed it and
  // http://[::ffff:169.254.169.254] slipped past the denylist to reach internal or metadata
  // addresses. The two hextets are rebuilt into an IPv4 address and reuse isForbiddenIPv4.
  const hexMappedIPv4 = lower.match(/^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
  if (hexMappedIPv4) {
    const hi = Number.parseInt(hexMappedIPv4[1], 16);
    const lo = Number.parseInt(hexMappedIPv4[2], 16);
    const reconstructed = `${(hi >> 8) & 0xff}.${hi & 0xff}.${(lo >> 8) & 0xff}.${lo & 0xff}`;
    return isForbiddenIPv4(reconstructed);
  }
  const firstHextet = Number.parseInt(lower.split(':')[0] ?? '', 16);
  return (
    lower === '::'
    || lower === '::1'
    || lower.startsWith('fc')
    || lower.startsWith('fd')
    || (Number.isInteger(firstHextet) && firstHextet >= 0xfe80 && firstHextet <= 0xfebf)
  );
}

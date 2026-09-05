import { describe, expect, it } from 'vitest';
import {
  FORBIDDEN_IPV4_CIDRS,
  FORBIDDEN_IPV6_CIDRS,
  isForbiddenIPv4,
  isForbiddenIPv6,
} from '../ssrf';

/**
 * Locks the CIDR constants and the isForbiddenIPv4/6 functions to a single source of truth: the
 * desktop main process builds a net.BlockList from the CIDRs while the server uses the functions, and
 * the two must be equivalent or a gap opens between the BlockList and the post-resolution check.
 */

describe('SSRF denylist: CIDR constants match the functions', () => {
  it('treats every IPv4 CIDR network address and in-range sample as forbidden', () => {
    const samples: Record<string, string[]> = {
      '0.0.0.0/8': ['0.0.0.0', '0.1.2.3'],
      '10.0.0.0/8': ['10.0.0.0', '10.255.255.255'],
      '127.0.0.0/8': ['127.0.0.1', '127.255.0.1'],
      '169.254.0.0/16': ['169.254.0.0', '169.254.169.254'],
      '172.16.0.0/12': ['172.16.0.1', '172.31.255.255'],
      '192.168.0.0/16': ['192.168.0.1', '192.168.255.255'],
      '224.0.0.0/4': ['224.0.0.1', '239.255.255.255'],
      '240.0.0.0/4': ['240.0.0.1', '255.255.255.255'],
    };
    for (const cidr of FORBIDDEN_IPV4_CIDRS) {
      for (const ip of samples[cidr] ?? []) {
        expect(isForbiddenIPv4(ip), `${ip} (${cidr})`).toBe(true);
      }
    }
  });

  it('does not misjudge public IPv4 addresses', () => {
    for (const ip of ['8.8.8.8', '1.1.1.1', '104.18.0.1', '172.15.0.1', '172.32.0.1', '11.0.0.1', '223.255.255.255']) {
      expect(isForbiddenIPv4(ip), ip).toBe(false);
    }
  });

  it('forbids private and reserved IPv6 ranges while letting public ones through', () => {
    for (const ip of ['::1', '::', 'fc00::1', 'fd12::1', 'fe80::1', '::ffff:10.0.0.1']) {
      expect(isForbiddenIPv6(ip), ip).toBe(true);
    }
    for (const ip of ['2606:4700::1', '2001:4860:4860::8888']) {
      expect(isForbiddenIPv6(ip), ip).toBe(false);
    }
  });

  it('still blocks the hexadecimal normalised form of an IPv4-mapped IPv6 address, since new URL rewrites ::ffff:x.x.x.x as ::ffff:hhhh:hhhh', () => {
    // WHATWG new URL() normalises ::ffff:169.254.169.254 into ::ffff:a9fe:a9fe, and a regex that only
    // matched dotted-decimal form would miss it, allowing the denylist to be bypassed to reach the
    // internal network or the metadata service.
    for (const ip of ['::ffff:a9fe:a9fe' /* 169.254.169.254 */, '::ffff:7f00:1' /* 127.0.0.1 */, '::ffff:a00:1' /* 10.0.0.1 */]) {
      expect(isForbiddenIPv6(ip), ip).toBe(true);
    }
    // The mapped form of a public address is not caught (8.8.8.8).
    expect(isForbiddenIPv6('::ffff:808:808'), '::ffff:808:808 (8.8.8.8)').toBe(false);
  });

  it('locks the number and coverage of the CIDR constants so a range cannot be dropped by accident', () => {
    expect(FORBIDDEN_IPV4_CIDRS).toEqual([
      '0.0.0.0/8', '10.0.0.0/8', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16',
      '224.0.0.0/4', '240.0.0.0/4',
    ]);
    expect(FORBIDDEN_IPV6_CIDRS).toEqual(['::/128', '::1/128', 'fc00::/7', 'fe80::/10']);
  });
});

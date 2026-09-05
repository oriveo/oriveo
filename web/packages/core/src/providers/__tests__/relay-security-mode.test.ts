import { describe, expect, it } from 'vitest';
import {
  RELAY_SELECTABLE_SECURITY_MODES,
  normalizeEndpointForSecurityMode,
  relaySecurityModeDecision,
} from '../relay-security-mode';

describe('relaySecurityModeDecision', () => {
  it('keeps TOFU outside the picker and only suggests a weaker mode without writing it', () => {
    expect(RELAY_SELECTABLE_SECURITY_MODES).toEqual([
      'remote_https',
      'local_http',
      'private_vpn',
    ]);
    const decision = relaySecurityModeDecision('192.168.1.20:8080/v1');
    expect(decision.suggestion).toBe('local_http');
    expect(decision.options.find((item) => item.mode === 'local_http')).toMatchObject({
      enabled: true,
      addressClass: 'private_lan',
    });
  });

  it('routes a Tailscale literal only to private_vpn', () => {
    const decision = relaySecurityModeDecision('http://100.101.102.103:11434');
    expect(decision.suggestion).toBe('private_vpn');
    expect(decision.options.find((item) => item.mode === 'local_http')?.enabled).toBe(false);
    expect(decision.options.find((item) => item.mode === 'private_vpn')).toMatchObject({
      enabled: true,
      addressClass: 'private_vpn',
    });
  });

  it('does not offer a weaker mode for explicit HTTPS even when the literal is private', () => {
    const decision = relaySecurityModeDecision('https://192.168.1.20:8080/v1');
    expect(decision.suggestion).toBeUndefined();
    expect(decision.options.find((item) => item.mode === 'local_http')).toMatchObject({
      enabled: false,
      unavailableReason: 'plain_http_scheme_required',
    });
  });

  it.each([
    ['http://203.0.113.8:8080', 'public_address'],
    ['http://relay.internal.example:8080', 'unknown_address'],
    ['http://engine.internal:8080', 'unknown_address'],
    ['http://engine:8080', 'unknown_address'],
  ])('keeps %s disabled without DNS evidence', (endpoint, reason) => {
    const decision = relaySecurityModeDecision(endpoint);
    expect(decision.options.find((item) => item.mode === 'local_http')).toMatchObject({
      enabled: false,
      unavailableReason: reason,
    });
  });

  it('only offers .local as a browser-LNA local-name candidate', () => {
    const decision = relaySecurityModeDecision('http://engine.local:11434');
    expect(decision.suggestion).toBe('local_http');
    expect(decision.options.find((item) => item.mode === 'local_http')).toMatchObject({
      enabled: true,
      addressClass: 'local_name',
    });
    expect(decision.options.find((item) => item.mode === 'private_vpn')).toMatchObject({
      enabled: false,
      unavailableReason: 'unknown_address',
    });
  });

  it('normalizes no-scheme addresses from the selected production mode', () => {
    expect(normalizeEndpointForSecurityMode('192.168.1.20:8080/v1', 'local_http'))
      .toBe('http://192.168.1.20:8080/v1');
    expect(normalizeEndpointForSecurityMode('relay.example.com/v1', 'remote_https'))
      .toBe('https://relay.example.com/v1');
  });
});

import { describe, expect, it } from 'vitest';
import {
  RELAY_HTTPS_REQUIRED_MESSAGE,
  normalizeSecureRelayEndpoint,
  requireSecureRelayEndpoint,
} from './endpoint-policy';

describe('Relay endpoint policy', () => {
  it.each([
    ['relay.example.com/v1/', 'https://relay.example.com/v1'],
    ['https://192.168.1.20:8443/v1/', 'https://192.168.1.20:8443/v1'],
    ['https://relay.local/v1', 'https://relay.local/v1'],
    ['https://relay.corp.example/v1', 'https://relay.corp.example/v1'],
    ['https://[fd7a:115c:a1e0::1]:8443/v1/', 'https://[fd7a:115c:a1e0::1]:8443/v1'],
  ])('accepts secure LAN/VPN endpoint %s', (input, expected) => {
    expect(normalizeSecureRelayEndpoint(input)).toBe(expected);
  });

  it.each([
    'http://192.168.1.20:8080/v1',
    'ftp://relay.local/v1',
    'https://',
    'https://user:secret@relay.local/v1',
  ])('rejects unsafe endpoint %s', (input) => {
    expect(normalizeSecureRelayEndpoint(input)).toBeNull();
  });

  it('throws the actionable HTTPS guidance at the network boundary', () => {
    expect(() => requireSecureRelayEndpoint('http://relay.local/v1'))
      .toThrow(RELAY_HTTPS_REQUIRED_MESSAGE);
  });
});

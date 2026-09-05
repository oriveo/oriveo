import { describe, expect, it } from 'vitest';
import { decodeLocalPairingV1, encodeLocalPairingV1 } from './local-pairing';

describe('local pairing payload v1', () => {
  it('round trips configuration without credentials', () => {
    const encoded = encodeLocalPairingV1({ version: 1, engine: 'ollama', urls: ['http://192.168.1.20:11434', 'http://100.101.102.103:11434'], authMode: 'none', name: 'Home Ollama' });
    expect(encoded.toLowerCase()).not.toMatch(/api.?key|authorization|token|secret/);
    expect(decodeLocalPairingV1(encoded)).toEqual({ version: 1, engine: 'ollama', urls: ['http://192.168.1.20:11434', 'http://100.101.102.103:11434'], authMode: 'none', name: 'Home Ollama' });
  });

  it('decodes the frozen multi-address JSON shape', () => {
    expect(decodeLocalPairingV1('{"v":1,"name":"Fixture Mac","urls":["http://192.168.1.20:8080","http://100.101.102.103:8080"],"engine":"llamacpp","auth":"none"}').urls).toHaveLength(2);
  });

  it('rejects embedded secrets', () => {
    expect(() => decodeLocalPairingV1('oriveo://local-provider?v=1&engine=ollama&endpoint=http%3A%2F%2F127.0.0.1%3A11434&mode=local_http&auth=none&api_key=secret')).toThrow('pairing_payload_contains_secret');
  });

  it('rejects credentials nested in the paired endpoint', () => {
    expect(() => decodeLocalPairingV1('oriveo://local-provider?v=1&engine=ollama&endpoint=http%3A%2F%2F127.0.0.1%3A11434%2F%3Fclient_secret%3Dx&mode=local_http&auth=none')).toThrow('pairing_payload_contains_secret');
  });
});

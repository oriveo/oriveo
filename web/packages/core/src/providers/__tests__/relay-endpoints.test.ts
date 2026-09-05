import { describe, expect, it } from 'vitest';
import { buildRelayEndpointURL } from '../relay-endpoints';

describe('buildRelayEndpointURL', () => {
  it('uses a discovered API root exactly without appending a guessed version', () => {
    expect(buildRelayEndpointURL({
      baseURL: 'https://relay.example.com/prefix',
      transport: 'anthropic_messages',
      endpoint: 'messages',
      exactBaseURL: true,
    })).toBe('https://relay.example.com/prefix/messages');
  });

  it('preserves historical version completion for legacy configs without an exact root', () => {
    expect(buildRelayEndpointURL({
      baseURL: 'https://relay.example.com/prefix',
      transport: 'anthropic_messages',
      endpoint: 'messages',
    })).toBe('https://relay.example.com/prefix/v1/messages');
    expect(buildRelayEndpointURL({
      baseURL: 'https://relay.example.com/prefix',
      transport: 'gemini_generate_content',
      endpoint: 'geminiGenerateContent',
      modelID: 'gemini-2.5-pro',
    })).toBe('https://relay.example.com/prefix/v1beta/models/gemini-2.5-pro:generateContent');
  });

  it('llama.cpp native completion keeps the engine root and targets /completion', () => {
    expect(buildRelayEndpointURL({
      baseURL: 'http://127.0.0.1:8080',
      transport: 'llamacpp_native',
      endpoint: 'llamaCompletion',
      securityMode: 'local_http',
    })).toBe('http://127.0.0.1:8080/completion');
  });
});

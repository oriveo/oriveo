import { describe, expect, it } from 'vitest';
import { buildRelayGenerationValidationRequest, type RelayGenerationValidationConfig } from '../relay-validation-request';

// Regression: with no validation sample no request is sent, and a hardcoded gpt-4o must not be used as a fallback.
// In production only the llama.cpp native protocol goes through here; probes for the four chat protocols are produced by the app's buildRelayPingRequest.
describe('relay generation request without a model', () => {
  it('refuses to build a llamacpp_native request for a blank model ID', () => {
    const config: RelayGenerationValidationConfig & { transport: 'llamacpp_native' } = {
      baseURL: 'https://relay.example.com',
      apiKey: 'sk-test',
      modelID: '   ',
      transport: 'llamacpp_native',
      authMode: 'bearer',
    };
    expect(() => buildRelayGenerationValidationRequest(config)).toThrow(
      expect.objectContaining({ kind: 'network', detail: 'No model to verify this relay with.' }),
    );
  });

  it('still builds the request with the given model ID', () => {
    const request = buildRelayGenerationValidationRequest({
      baseURL: 'https://relay.example.com',
      apiKey: 'sk-test',
      modelID: ' local-model ',
      transport: 'llamacpp_native',
      authMode: 'none',
    });
    expect(request.upstreamURL).toBe('https://relay.example.com/chat/completions');
    expect(request.body).toEqual({ model: 'local-model', stream: false, max_tokens: 1, messages: [{ role: 'user', content: 'ping' }] });
  });
});

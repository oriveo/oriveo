import { describe, expect, it } from 'vitest';

import {
  inferRelayKind,
  makeRelayRequested,
} from './kind-defaults';

describe('makeRelayRequested', () => {
  it('returns the cross-platform defaults for each relay kind', () => {
    expect(makeRelayRequested('openai_compatible')).toMatchObject({
      transport: 'openai_chat_completions',
      authMode: 'bearer',
      stream: true,
      reasoningEffort: 'automatic',
    });

    expect(makeRelayRequested('codex_style')).toMatchObject({
      transport: 'openai_responses',
      authMode: 'bearer',
      stream: true,
      disableResponseStorage: true,
      reasoningEffort: 'automatic',
      codexCompatIdentity: true,
    });

    expect(makeRelayRequested('anthropic_compatible')).toMatchObject({
      transport: 'anthropic_messages',
      authMode: 'x_api_key',
      stream: true,
    });

    expect(makeRelayRequested('gemini_compatible')).toMatchObject({
      transport: 'gemini_generate_content',
      authMode: 'x_goog_api_key',
      stream: true,
    });
  });

  it('preserves user-owned fields when changing relay kind', () => {
    const requested = makeRelayRequested('anthropic_compatible', {
      transport: 'openai_responses',
      authMode: 'bearer',
      modelID: 'claude-3-5-sonnet',
      resolvedAPIBaseURL: 'https://relay.example.com/custom',
      reasoningEffort: 'xhigh',
      serviceTier: 'priority',
      stream: false,
      disableResponseStorage: true,
      headers: [{ key: 'x-custom', value: '1' }],
      queryParams: [{ key: 'api-version', value: '2026-04-25' }],
      customUserAgent: 'Custom UA',
      codexCompatIdentity: false,
    });

    expect(requested).toEqual({
      transport: 'anthropic_messages',
      authMode: 'x_api_key',
      modelID: 'claude-3-5-sonnet',
      resolvedAPIBaseURL: 'https://relay.example.com/custom',
      stream: true,
      headers: [{ key: 'x-custom', value: '1' }],
      queryParams: [{ key: 'api-version', value: '2026-04-25' }],
      customUserAgent: 'Custom UA',
    });
  });

  it('custom kind keeps the existing transport and compatibility toggles', () => {
    expect(makeRelayRequested('custom', {
      transport: 'openai_responses',
      authMode: 'bearer',
      stream: false,
      disableResponseStorage: true,
      codexCompatIdentity: false,
      customUserAgent: 'UA',
    })).toMatchObject({
      transport: 'openai_responses',
      authMode: 'bearer',
      stream: false,
      disableResponseStorage: true,
      codexCompatIdentity: false,
      customUserAgent: 'UA',
    });
  });
});

describe('inferRelayKind', () => {
  it('infers the relay kind from the requested transport alone', () => {
    // The Responses transport is Codex style whether or not the identity toggle is on: the
    // toggle changes the client identity that is sent, not which protocol is spoken.
    expect(inferRelayKind({
      transport: 'openai_responses',
      authMode: 'bearer',
      codexCompatIdentity: true,
    })).toBe('codex_style');

    expect(inferRelayKind({
      transport: 'openai_responses',
      authMode: 'bearer',
    })).toBe('codex_style');

    expect(inferRelayKind({
      transport: 'anthropic_messages',
      authMode: 'x_api_key',
    })).toBe('anthropic_compatible');
  });

  it('falls back to custom when there is no requested config', () => {
    expect(inferRelayKind(null)).toBe('custom');
    expect(inferRelayKind(undefined)).toBe('custom');
  });
});

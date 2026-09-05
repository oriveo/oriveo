/**
 * TransportRegistry: unknown kind fallback and telemetry reporting.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// Path matches the import path in transport-registry.ts; Vitest matches on the module specifier.
vi.mock('../../../telemetry', () => ({
  trackEvent: vi.fn(),
  telemetryProviderKind: (k: string) => k,
}));

import { trackEvent } from '../../../telemetry';
import {
  getStrategyByKind,
  getStrategyForModel,
  knownTransportKinds,
  resolveStrategyByKindOrFallback,
  UnsupportedTransportError,
} from '../transport-registry';
import { endpointKindForTransport, isKnownTransportKind } from '../transport-kind';
import { openAIChatStrategy } from '../strategies/openai-chat';
import { openAIResponsesStrategy } from '../strategies/openai-responses';

describe('transport-registry', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('returns a strategy for a known kind', () => {
    const s = getStrategyByKind('openai_chat');
    expect(s.kind).toBe('openai_chat');
  });

  it('throws UnsupportedTransportError and emits telemetry for an unknown kind', () => {
    expect(() => getStrategyByKind('foo_unknown')).toThrow(UnsupportedTransportError);
    expect(trackEvent).toHaveBeenCalledWith('unknown_transport_kind', { kind: 'foo_unknown' });
  });

  it('getStrategyForModel returns null when transport is not set', () => {
    expect(
      getStrategyForModel({
        id: 'x',
        name: 'x',
        capabilities: ['text'],
        reasoningModeAvailable: false,
        isAvailable: true,
        isDefault: false,
        priceTier: '',
      }),
    ).toBeNull();
    //   emit
    expect(trackEvent).not.toHaveBeenCalled();
  });

  it('getStrategyForModel returns null and emits telemetry for an unknown transport', () => {
    const s = getStrategyForModel({
      id: 'x',
      name: 'x',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
      transport: 'bogus_kind',
    } as Parameters<typeof getStrategyForModel>[0]);
    expect(s).toBeNull();
    expect(trackEvent).toHaveBeenCalledWith('unknown_transport_kind', {
      kind: 'bogus_kind',
      modelId: 'x',
    });
  });

  it('knownTransportKinds exposes every current kind', () => {
    const set = knownTransportKinds();
    expect(set.has('openai_chat')).toBe(true);
    expect(set.has('anthropic_messages')).toBe(true);
    expect(set.has('gemini_generate')).toBe(true);
    expect(set.has('dashscope_native')).toBe(true);
  });

  it('isKnownTransportKind agrees with the registry set', () => {
    for (const k of ['openai_chat', 'anthropic_messages', 'gemini_generate', 'dashscope_native']) {
      expect(isKnownTransportKind(k)).toBe(true);
    }
    expect(isKnownTransportKind('foo_unknown')).toBe(false);
    expect(isKnownTransportKind(undefined)).toBe(false);
  });

  describe('resolveStrategyByKindOrFallback', () => {
    it('returns a strategy for a known kind', () => {
      expect(
        resolveStrategyByKindOrFallback('openai_responses', openAIChatStrategy),
      ).toBe(openAIResponsesStrategy);
      expect(
        resolveStrategyByKindOrFallback('openai_chat', openAIResponsesStrategy),
      ).toBe(openAIChatStrategy);
    });

    it('returns the fallback and emits telemetry for an unknown kind', () => {
      const s = resolveStrategyByKindOrFallback('bogus_kind', openAIChatStrategy, {
        providerKind: 'openAI',
        modelID: 'mystery-model',
      });
      expect(s).toBe(openAIChatStrategy);
      expect(trackEvent).toHaveBeenCalledWith('unknown_transport_kind', {
        kind: 'bogus_kind',
        providerKind: 'openAI',
        modelID: 'mystery-model',
      });
    });

    it('returns the fallback directly for kind=undefined without reporting telemetry', () => {
      const s = resolveStrategyByKindOrFallback(undefined, openAIChatStrategy);
      expect(s).toBe(openAIChatStrategy);
      expect(trackEvent).not.toHaveBeenCalled();
    });
  });

  describe('endpointKindForTransport', () => {
    it('openai_responses maps to the responses endpoint', () => {
      expect(endpointKindForTransport('openai_responses')).toBe('responses');
    });

    it('a streaming kind maps to the chat endpoint', () => {
      expect(endpointKindForTransport('openai_chat')).toBe('chat');
      expect(endpointKindForTransport('anthropic_messages')).toBe('chat');
      expect(endpointKindForTransport('gemini_generate')).toBe('chat');
      expect(endpointKindForTransport('dashscope_native')).toBe('chat');
    });

    it('an image kind maps to the images endpoint', () => {
      expect(endpointKindForTransport('openai_images')).toBe('images');
      expect(endpointKindForTransport('gemini_image')).toBe('images');
      expect(endpointKindForTransport('qwen_image')).toBe('images');
      expect(endpointKindForTransport('grok_image')).toBe('images');
      expect(endpointKindForTransport('zhipu_image')).toBe('images');
    });

    it('a files kind maps to the files endpoint', () => {
      expect(endpointKindForTransport('openai_files')).toBe('files');
      expect(endpointKindForTransport('anthropic_files')).toBe('files');
    });

    it('falls back to chat for an unknown kind', () => {
      expect(endpointKindForTransport('mystery_kind')).toBe('chat');
    });
  });
});

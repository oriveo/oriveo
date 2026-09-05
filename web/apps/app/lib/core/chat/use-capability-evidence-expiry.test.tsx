import { act, cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import * as capabilityEvidence from './capability-evidence';
import {
  __resetCapabilityEvidenceExpirySchedulerForTest,
  useCapabilityEvidenceCollectionExpiry,
  type CapabilityEvidenceExpiryTarget,
} from './use-capability-evidence-expiry';

afterEach(() => {
  cleanup();
  __resetCapabilityEvidenceExpirySchedulerForTest();
  vi.useRealTimers();
});

function Harness({ targets }: { targets: CapabilityEvidenceExpiryTarget[] }) {
  const tick = useCapabilityEvidenceCollectionExpiry(targets);
  return <span data-testid="tick">{tick}</span>;
}

describe('capability evidence expiry scheduler', () => {
  it('uses one shared timer for an 810-model catalog and advances to the next expiry', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-08-09T00:00:00Z'));
    const models = Array.from({ length: 810 }, (_, index) => makeModel(index));
    const provider = makeProvider(models);
    const targets = models.map((model) => ({ provider, model }));

    const expirySpy = vi.spyOn(capabilityEvidence, 'nextCapabilityEvidenceExpiry');
    const rendered = render(<Harness targets={targets} />);

    expect(vi.getTimerCount()).toBe(1);
    expect(expirySpy).toHaveBeenCalledTimes(810);
    rendered.rerender(<Harness targets={targets} />);
    expect(expirySpy).toHaveBeenCalledTimes(810);
    await act(async () => {
      vi.advanceTimersByTime(1_001);
    });
    expect(screen.getByTestId('tick').textContent).toBe('1');
    expect(expirySpy).toHaveBeenCalledTimes(1_620);
    expect(vi.getTimerCount()).toBe(1);
  });
});

function makeModel(index: number): AIModel {
  const id = `model-${index}`;
  return {
    id,
    name: id,
    capabilities: [],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: index === 0,
    priceTier: '',
    transport: 'openai_chat',
    capabilityEvidenceCandidates: [{
      key: 'vision_input',
      support: 'supported',
      source: 'server_profile',
      grade: 'effect_verified',
      scope: 'provider_model_transport',
      providerKind: 'openAI',
      modelId: id,
      transport: 'openai_chat',
      expiresAt: Date.now() + 1_000 + index,
    }],
  };
}

function makeProvider(models: AIModel[]): Provider {
  return {
    id: 'provider-810',
    kind: 'openAI',
    status: { kind: 'connected' },
    models,
    catalogModels: models,
    apiKey: 'local-test-key',
    apiKeyPreview: 'local-test-preview',
  } as Provider;
}

import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  trackEvent: vi.fn(),
  refreshMetadata: vi.fn().mockResolvedValue(undefined),
  initMetadata: vi.fn().mockResolvedValue(undefined),
  resolveCatalogModel: vi.fn(),
}));

vi.mock('../../telemetry', () => ({
  trackEvent: mocks.trackEvent,
}));

vi.mock('../../metadata/metadata-client', () => ({
  refreshMetadata: mocks.refreshMetadata,
  initMetadata: mocks.initMetadata,
  resolveCatalogModel: mocks.resolveCatalogModel,
}));

import {
  __resetSelfHealMetadataRefreshThrottle,
  reportUnsupportedParamDropped,
} from '../unsupported-param-telemetry';

async function flushMicrotasks() {
  await Promise.resolve();
  await new Promise((resolve) => setImmediate(resolve));
}

describe('reportUnsupportedParamDropped', () => {
  beforeEach(() => {
    __resetSelfHealMetadataRefreshThrottle();
    mocks.refreshMetadata.mockClear();
  });

  it('forces a metadata refresh after reporting a self-heal event', async () => {
    mocks.trackEvent.mockClear();
    mocks.resolveCatalogModel.mockReturnValue({ transport: 'openai_chat_completions' });
    reportUnsupportedParamDropped({
      providerKind: 'grok',
      modelID: 'grok-4',
      param: 'reasoning_effort',
    });
    await flushMicrotasks();

    expect(mocks.trackEvent).toHaveBeenCalledWith('self_heal_param_dropped', {
      parameter: 'reasoning_effort',
      status: 'recovered',
      transport: 'openai_chat_completions',
      error_class: 'unsupported_parameter',
    });
    expect(mocks.trackEvent.mock.calls[0]?.[1]).not.toHaveProperty('model_id');
    expect(mocks.trackEvent.mock.calls[0]?.[1]).not.toHaveProperty('provider_kind');
    expect(mocks.refreshMetadata).toHaveBeenCalledTimes(1);
    expect(mocks.initMetadata).not.toHaveBeenCalled();
  });

  // Regression: concurrent calls are merged by metadata-client's refreshPromise, but serial calls have
  // no upper bound, so dropping several parameters in one request would fire several conditional GETs.
  // The telemetry event itself must still be sent every time; only the refresh is throttled.
  it('several self-heals within 60 seconds force only one metadata refresh, but every one reports telemetry', async () => {
    mocks.trackEvent.mockClear();
    mocks.resolveCatalogModel.mockReturnValue({ transport: 'openai_chat_completions' });
    for (const param of ['reasoning_effort', 'temperature', 'top_p']) {
      reportUnsupportedParamDropped({ providerKind: 'grok', modelID: 'grok-4', param });
    }
    await flushMicrotasks();

    expect(mocks.trackEvent).toHaveBeenCalledTimes(3);
    expect(mocks.refreshMetadata).toHaveBeenCalledTimes(1);
  });

  it('reports transport as unknown when the catalog has no entry, and never falls back to providerKind', async () => {
    mocks.trackEvent.mockClear();
    mocks.resolveCatalogModel.mockReturnValue(null);
    reportUnsupportedParamDropped({
      providerKind: 'relay',
      modelID: 'custom',
      param: 'temperature',
    });
    await flushMicrotasks();

    const properties = mocks.trackEvent.mock.calls.at(-1)?.[1] as Record<string, unknown>;
    expect(properties.transport).toBe('unknown');
    expect(Object.values(properties)).not.toContain('relay');
  });
});

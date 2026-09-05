/**
 * Catalog model filtering: hide models with an unrecognised transport or a too-high minClientVersion.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// The path must match the import path used inside catalog-filter.ts.
vi.mock('../../../telemetry', () => ({
  trackEvent: vi.fn(),
  telemetryProviderKind: (k: string) => k,
}));

import { trackEvent } from '../../../telemetry';
import {
  createCatalogFilterContext,
  shouldHideModelForTransport,
  __testing,
} from '../catalog-filter';

describe('shouldHideModelForTransport', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('hides an unknown transport and reports telemetry', () => {
    const ctx = createCatalogFilterContext();
    const hidden = shouldHideModelForTransport(
      { id: 'foo', transport: 'bogus_kind' },
      ctx,
    );
    expect(hidden).toBe(true);
    expect(ctx.modelIdsHidden).toContain('foo');
    expect(trackEvent).toHaveBeenCalledWith('unknown_transport_kind', {
      kind: 'bogus_kind',
      modelId: 'foo',
    });
  });

  it('lets a known transport through', () => {
    const ctx = createCatalogFilterContext();
    expect(
      shouldHideModelForTransport({ id: 'bar', transport: 'openai_chat' }, ctx),
    ).toBe(false);
    expect(trackEvent).not.toHaveBeenCalled();
  });

  it('lets a missing transport through, for compatibility with older metadata', () => {
    const ctx = createCatalogFilterContext();
    expect(shouldHideModelForTransport({ id: 'baz' }, ctx)).toBe(false);
  });

  it('emits telemetry only once for a repeated kind', () => {
    const ctx = createCatalogFilterContext();
    shouldHideModelForTransport({ id: 'm1', transport: 'bogus' }, ctx);
    shouldHideModelForTransport({ id: 'm2', transport: 'bogus' }, ctx);
    shouldHideModelForTransport({ id: 'm3', transport: 'bogus' }, ctx);
    expect(trackEvent).toHaveBeenCalledTimes(1);
  });

  it('hides and reports a minClientVersion above the client version', () => {
    const ctx = createCatalogFilterContext();
    // The client falls back to '0.0.0' when NEXT_PUBLIC_APP_VERSION is absent, so any version is newer.
    const hidden = shouldHideModelForTransport(
      { id: 'future', minClientVersion: '99.0.0' },
      ctx,
    );
    expect(hidden).toBe(true);
    expect(trackEvent).toHaveBeenCalledWith(
      'unknown_transport_kind',
      expect.objectContaining({
        kind: 'min_client_version',
        required: '99.0.0',
      }),
    );
  });

  it('lets a minClientVersion equal to or below the client version through', () => {
    const ctx = createCatalogFilterContext();
    expect(
      shouldHideModelForTransport({ id: 'old', minClientVersion: '0.0.0' }, ctx),
    ).toBe(false);
  });
});

describe('SemVer comparison', () => {
  it('compares the major version first', () => {
    expect(__testing.compareSemver('2.0.0', '1.9.9')).toBeGreaterThan(0);
  });

  it('compares the minor version', () => {
    expect(__testing.compareSemver('1.2.0', '1.1.9')).toBeGreaterThan(0);
  });

  it('compares the patch version', () => {
    expect(__testing.compareSemver('1.0.5', '1.0.4')).toBeGreaterThan(0);
  });

  it('reports equal versions as equal', () => {
    expect(__testing.compareSemver('1.0.0', '1.0.0')).toBe(0);
  });

  it('ignores a leading v', () => {
    expect(__testing.compareSemver('v1.0.0', '1.0.0')).toBe(0);
  });

  it('pads a short version with zeros', () => {
    expect(__testing.compareSemver('1.0', '1.0.0')).toBe(0);
  });
});

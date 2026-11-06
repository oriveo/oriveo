/**
 * Shared fixture studio_availability.v1.json: every case runs through the Web
 * studioAvailability and every expected key is compared, webApiStatus included.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  isStudioCompiledIn,
  studioAvailability,
  studioAvailabilityInputFromFeatureFlags,
  type StudioAvailability,
  type StudioAvailabilityInput,
} from '../availability';

const ROOT = resolve(__dirname, '../../../../../../..');

interface AvailabilityCase {
  caseId: string;
  input: StudioAvailabilityInput;
  expect: StudioAvailability;
}

const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/studio-contracts/studio_availability.v1.json'), 'utf8',
)) as { cases: AvailabilityCase[] };

describe('studio_availability.v1', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('fixture has cases', () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
  });

  for (const entry of fixture.cases) {
    it(`STUDIO-AVAILABILITY-${entry.caseId}`, () => {
      const result = studioAvailability(entry.input);
      expect(Object.keys(result).sort()).toEqual(Object.keys(entry.expect).sort());
      for (const key of Object.keys(entry.expect) as (keyof StudioAvailability)[]) {
        expect(result[key], `${entry.caseId}.${key}`).toBe(entry.expect[key]);
      }
    });
  }

  it('empty featureFlags with compileFlag on shows the entry but not managed models', () => {
    const input = studioAvailabilityInputFromFeatureFlags({}, {
      compileFlag: true,
      imageDisabled: false,
      enabledManagedModels: 2,
      isPro: false,
    });
    expect(input.remoteStudioEnabled).toBeUndefined();
    expect(input.remoteManagedEnabled).toBeUndefined();
    const result = studioAvailability(input);
    expect(result.entryVisible).toBe(true);
    expect(result.managedListed).toBe(false);
  });

  it('featureFlags keys map onto the remote inputs', () => {
    const input = studioAvailabilityInputFromFeatureFlags(
      { studio_enabled: false, studio_managed_enabled: true },
      { compileFlag: true, isPro: true },
    );
    expect(input.remoteStudioEnabled).toBe(false);
    expect(input.remoteManagedEnabled).toBe(true);
    expect(studioAvailability(input).entryVisible).toBe(false);
  });

  it('non-boolean featureFlags values stay undefined', () => {
    const input = studioAvailabilityInputFromFeatureFlags(
      { studio_enabled: 'false', studio_managed_enabled: 1 },
      { compileFlag: true, isPro: false },
    );
    expect(input.remoteStudioEnabled).toBeUndefined();
    expect(input.remoteManagedEnabled).toBeUndefined();
  });

  it('compileFlag defaults to isStudioCompiledIn()', () => {
    vi.stubEnv('NEXT_PUBLIC_STUDIO_ENABLED', 'true');
    expect(studioAvailabilityInputFromFeatureFlags({}, { isPro: false }).compileFlag).toBe(true);
    vi.stubEnv('NEXT_PUBLIC_STUDIO_ENABLED', 'false');
    expect(studioAvailabilityInputFromFeatureFlags({}, { isPro: false }).compileFlag).toBe(false);
  });
});

describe('isStudioCompiledIn', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('explicit "true" compiles studio in', () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('NEXT_PUBLIC_STUDIO_ENABLED', 'true');
    expect(isStudioCompiledIn()).toBe(true);
  });

  it('explicit "false" compiles studio out', () => {
    vi.stubEnv('NODE_ENV', 'development');
    vi.stubEnv('NEXT_PUBLIC_STUDIO_ENABLED', 'false');
    expect(isStudioCompiledIn()).toBe(false);
  });

  it('unset with NODE_ENV=production compiles studio out', () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('NEXT_PUBLIC_STUDIO_ENABLED', undefined);
    expect(isStudioCompiledIn()).toBe(false);
  });

  it('unset with NODE_ENV=development compiles studio in', () => {
    vi.stubEnv('NODE_ENV', 'development');
    vi.stubEnv('NEXT_PUBLIC_STUDIO_ENABLED', undefined);
    expect(isStudioCompiledIn()).toBe(true);
  });

  it('unset with NODE_ENV=test compiles studio out', () => {
    vi.stubEnv('NODE_ENV', 'test');
    vi.stubEnv('NEXT_PUBLIC_STUDIO_ENABLED', undefined);
    expect(isStudioCompiledIn()).toBe(false);
  });
});

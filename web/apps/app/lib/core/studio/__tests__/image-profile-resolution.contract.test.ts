/**
 * Shared fixture image_profile_resolution.v1.json: every resolution case runs
 * through the Web resolveImageProfile (profileRef, reason, appliedOverride), every
 * visibility case through visibleInStudio, and the hard-coded enums / required
 * fields / route allow tables are compared with image_profile.v2.json.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  IMAGE_EDIT_TRANSPORTS,
  IMAGE_OPERATIONS,
  IMAGE_PRICING_UNITS,
  IMAGE_PROFILE_REASONS,
  IMAGE_PROFILE_REQUIRED_FIELDS,
  IMAGE_PROFILE_SOURCES,
  IMAGE_QUALITY_TIERS,
  IMAGE_RESOLUTION_TIERS,
  IMAGE_ROUTES,
  IMAGE_ROUTE_RULES,
  IMAGE_SIZE_PARAMS,
  checkImageProfile,
  resolveImageProfile,
  visibleInStudio,
  type ImageMetadataSlice,
  type ImageRelayContext,
  type ImageRouteRule,
  type StudioVisibilityContext,
} from '../image-profile';

const ROOT = resolve(__dirname, '../../../../../../..');
const CONTRACTS = resolve(ROOT, 'shared/model-contracts');

interface ResolutionCase {
  caseId: string;
  input: { providerKind?: string; modelId: string; relay?: ImageRelayContext };
  expect: {
    profileRef: string | null;
    reason: string | null;
    appliedOverride?: Record<string, unknown>;
  };
}

interface VisibilityCase {
  caseId: string;
  profileRef: string;
  context: StudioVisibilityContext;
  expectVisible: boolean;
}

interface ProfileSchema {
  enums: Record<string, string[]>;
  fields: { required: string[] };
  routes: Record<string, { allowedEditTransports: string[]; allowedSizeParams: string[] }>;
}

function readJson<T>(name: string): T {
  return JSON.parse(readFileSync(resolve(CONTRACTS, name), 'utf8')) as T;
}

const fixture = readJson<{
  reasons: string[];
  metadata: ImageMetadataSlice & { profiles: { image: Record<string, unknown> } };
  cases: ResolutionCase[];
  visibilityCases: VisibilityCase[];
}>('image_profile_resolution.v1.json');
const schema = readJson<ProfileSchema>('image_profile.v2.json');

describe('image_profile_resolution.v1', () => {
  it('fixture has cases and visibility cases', () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
    expect(fixture.visibilityCases.length).toBeGreaterThan(0);
  });

  for (const entry of fixture.cases) {
    it(`IMAGE-PROFILE-RESOLUTION-${entry.caseId}`, () => {
      const result = resolveImageProfile(
        fixture.metadata,
        entry.input.providerKind,
        entry.input.modelId,
        entry.input.relay,
      );
      expect(result.profileRef, `${entry.caseId}.profileRef`).toBe(entry.expect.profileRef);
      expect(result.reason, `${entry.caseId}.reason`).toBe(entry.expect.reason);
      expect(result.appliedOverride, `${entry.caseId}.appliedOverride`)
        .toEqual(entry.expect.appliedOverride ?? null);
      if (entry.expect.profileRef === null) {
        expect(result.profile, `${entry.caseId}.profile`).toBeNull();
      } else {
        expect(result.profile, `${entry.caseId}.profile`).not.toBeNull();
        const merged: Readonly<Record<string, unknown>> = { ...result.profile };
        expect(merged.imageOutput, `${entry.caseId}.imageOutput`).toBe(true);
        for (const [key, value] of Object.entries(entry.expect.appliedOverride ?? {})) {
          expect(merged[key], `${entry.caseId}.${key}`).toEqual(value);
        }
      }
    });
  }

  for (const entry of fixture.visibilityCases) {
    it(`IMAGE-PROFILE-VISIBILITY-${entry.caseId}`, () => {
      const checked = checkImageProfile(fixture.metadata.profiles.image[entry.profileRef]);
      expect(checked.reason, `${entry.caseId}.reason`).toBeNull();
      expect(checked.profile, `${entry.caseId}.profile`).not.toBeNull();
      expect(visibleInStudio(checked.profile, entry.context)).toBe(entry.expectVisible);
    });
  }

  it('optional field with a wrong JSON type is absent from the resolved profile', () => {
    const tableEntry: Readonly<Record<string, unknown>> = fixture.metadata.profiles.image.optional_wrong_type as Record<string, unknown>;
    expect(tableEntry.typicalSeconds, 'fixture keeps a wrong-typed typicalSeconds').toBe('fast');
    const result = resolveImageProfile(fixture.metadata, 'openAI', 'optional-wrong-type-model');
    expect(result.reason).toBeNull();
    expect(result.profileRef).toBe('optional_wrong_type');
    expect(result.profile).not.toBeNull();
    const resolved: Readonly<Record<string, unknown>> = { ...result.profile };
    expect(Object.prototype.hasOwnProperty.call(resolved, 'typicalSeconds')).toBe(false);
    expect(resolved.maxReferenceImages).toBe(16);
    expect(resolved.nParam).toBe(true);
  });

  it('optional typicalSeconds with a wrong element type is absent from the resolved profile', () => {
    const tableEntry = fixture.metadata.profiles.image.optional_element_wrong_type as Record<string, unknown>;
    expect(tableEntry.typicalSeconds, 'fixture keeps a wrong element in typicalSeconds')
      .toEqual(['fast', 60]);
    const result = resolveImageProfile(fixture.metadata, 'openAI', 'optional-element-type-model');
    expect(result.reason).toBeNull();
    expect(result.profileRef).toBe('optional_element_wrong_type');
    expect(result.profile).not.toBeNull();
    const resolved: Readonly<Record<string, unknown>> = { ...result.profile };
    expect(Object.prototype.hasOwnProperty.call(resolved, 'typicalSeconds')).toBe(false);
    expect(resolved.maxReferenceImages).toBe(16);
  });

  it('null optional field is absent from the resolved profile', () => {
    const result = resolveImageProfile(fixture.metadata, 'openAI', 'null-transport-model');
    expect(result.reason).toBeNull();
    const resolved: Readonly<Record<string, unknown>> = { ...result.profile };
    expect(Object.prototype.hasOwnProperty.call(resolved, 'editTransport')).toBe(false);
  });

  it('null profile is never visible', () => {
    expect(visibleInStudio(null, { connectionUsable: true, hasBase: false, referenceCount: 0 }))
      .toBe(false);
  });

  it('reason closed set matches the fixture', () => {
    expect([...IMAGE_PROFILE_REASONS].sort()).toEqual([...fixture.reasons].sort());
  });

  it('enums match image_profile.v2.json', () => {
    expect([...IMAGE_OPERATIONS]).toEqual(schema.enums.operations);
    expect([...IMAGE_ROUTES]).toEqual(schema.enums.routes);
    expect([...IMAGE_EDIT_TRANSPORTS]).toEqual(schema.enums.editTransports);
    expect([...IMAGE_SIZE_PARAMS]).toEqual(schema.enums.sizeParams);
    expect([...IMAGE_QUALITY_TIERS]).toEqual(schema.enums.qualityTiers);
    expect([...IMAGE_RESOLUTION_TIERS]).toEqual(schema.enums.resolutionTiers);
    expect([...IMAGE_PROFILE_SOURCES]).toEqual(schema.enums.sources);
    expect([...IMAGE_PRICING_UNITS]).toEqual(schema.enums.pricingUnits);
    expect(Object.keys(schema.enums).sort()).toEqual([
      'editTransports', 'operations', 'pricingUnits', 'qualityTiers',
      'resolutionTiers', 'routes', 'sizeParams', 'sources',
    ]);
  });

  it('required fields match image_profile.v2.json', () => {
    expect([...IMAGE_PROFILE_REQUIRED_FIELDS]).toEqual(schema.fields.required);
  });

  it('route allow tables match image_profile.v2.json', () => {
    const rules: Readonly<Record<string, ImageRouteRule | undefined>> = IMAGE_ROUTE_RULES;
    expect(Object.keys(rules).sort()).toEqual([...schema.enums.routes].sort());
    for (const route of schema.enums.routes) {
      expect([...(rules[route]?.allowedEditTransports ?? [])], `${route}.edit`)
        .toEqual(schema.routes[route]?.allowedEditTransports);
      expect([...(rules[route]?.allowedSizeParams ?? [])], `${route}.size`)
        .toEqual(schema.routes[route]?.allowedSizeParams);
    }
  });
});

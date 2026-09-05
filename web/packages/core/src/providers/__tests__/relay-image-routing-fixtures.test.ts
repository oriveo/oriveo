/**
 * Cross-client consistency test for the relay image routing rules.
 *
 * The rules live in `test-fixtures/relay/routing-fixtures.json`. Each client implements its
 * own pure function, and this fixture pins their output case by case. The fixture states it
 * itself: every client's tests must assert its pure function produces identical output for
 * all cases, so the rules cannot drift apart.
 *
 * This file is the web side of that. To change a rule, change the fixture first.
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { RelayTransport } from '@oriveo/shared/pure-types';
import { isDedicatedImageModel } from '@oriveo/shared/relay/image-models';
import {
  pickChatDriverModelID,
  relayImageRoute,
  shouldForceRelayStream,
  type ChatDriverCandidate,
} from '../relay-runtime-support';

// __tests__ -> providers -> src -> core -> packages -> web -> <repo root>
const FIXTURE_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../../../../shared/test-fixtures/relay/routing-fixtures.json',
);

interface FixtureCase {
  id: string;
  note?: string;
  /** Cases that only apply to one client (such as the iOS relay-manual- prefix compatibility data); other clients skip them */
  platform?: string;
}

interface Fixture {
  imageRoute: { cases: (FixtureCase & { transport: string; expected: string })[] };
  shouldForceStream: {
    cases: (FixtureCase & { transport: string; capabilities: string[]; expected: boolean })[];
  };
  isDedicatedImageModel: { cases: (FixtureCase & { modelID: string; expected: boolean })[] };
  pickChatDriverModelID: {
    cases: (FixtureCase & {
      currentModelID: string;
      models: { id: string; capabilities: string[]; available: boolean; isDefault: boolean }[];
      expectedSuccess?: string;
      expectedError?: string;
    })[];
  };
}

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, 'utf-8')) as Fixture;

/** The fixture uses the client-neutral `imageGen`; the canonical capability value on web is `imageGeneration` (see enums.ts). */
function toWebCapabilities(capabilities: readonly string[]): string[] {
  return capabilities.map((cap) => (cap === 'imageGen' ? 'imageGeneration' : cap));
}

/**
 * The fixture's expected imageRoute values use the camelCase raw values from the iOS enum,
 * while the canonical web value is the snake_case form delivered by backend metadata (see
 * ports.RelayTransportRule['imageRoute']). The two correspond one to one and differ only in
 * naming style; iOS itself accepts both spellings in `imageRouteFromRuntime`.
 */
const IMAGE_ROUTE_ALIASES: Record<string, string> = {
  inlineResponsesTool: 'inline_responses_tool',
  imagesEndpoint: 'images_endpoint',
  geminiModality: 'gemini_modality',
  unsupported: 'unsupported',
};

function toWebImageRoute(expected: string): string {
  const mapped = IMAGE_ROUTE_ALIASES[expected];
  if (!mapped) throw new Error(`fixture uses an unknown imageRoute value: ${expected}`);
  return mapped;
}

/** Run only cases with no platform restriction, or restricted to web. */
function appliesToWeb(testCase: FixtureCase): boolean {
  return !testCase.platform || testCase.platform === 'web';
}

describe('relay image routing - shared cross-client fixture', () => {
  it('reads the fixture file and finds all four case groups non-empty, failing clearly on a wrong path', () => {
    expect(fixture.imageRoute.cases.length).toBeGreaterThan(0);
    expect(fixture.shouldForceStream.cases.length).toBeGreaterThan(0);
    expect(fixture.isDedicatedImageModel.cases.length).toBeGreaterThan(0);
    expect(fixture.pickChatDriverModelID.cases.length).toBeGreaterThan(0);
  });

  describe('imageRoute', () => {
    for (const testCase of fixture.imageRoute.cases.filter(appliesToWeb)) {
      it(`${testCase.id}: ${testCase.transport} → ${testCase.expected}`, () => {
        expect(relayImageRoute(testCase.transport as RelayTransport, null))
          .toBe(toWebImageRoute(testCase.expected));
      });
    }
  });

  describe('isDedicatedImageModel', () => {
    for (const testCase of fixture.isDedicatedImageModel.cases.filter(appliesToWeb)) {
      it(`${testCase.id}: ${testCase.modelID} → ${testCase.expected}`, () => {
        expect(isDedicatedImageModel(testCase.modelID)).toBe(testCase.expected);
      });
    }
  });

  describe('shouldForceStream', () => {
    for (const testCase of fixture.shouldForceStream.cases.filter(appliesToWeb)) {
      it(`${testCase.id}: ${testCase.transport} + [${testCase.capabilities}] → ${testCase.expected}`, () => {
        expect(
          shouldForceRelayStream(
            testCase.transport as RelayTransport,
            toWebCapabilities(testCase.capabilities),
            null,
          ),
        ).toBe(testCase.expected);
      });
    }
  });

  describe('pickChatDriverModelID', () => {
    for (const testCase of fixture.pickChatDriverModelID.cases.filter(appliesToWeb)) {
      it(`${testCase.id}: ${testCase.note ?? ''}`.trim(), () => {
        const models: ChatDriverCandidate[] = testCase.models.map((model) => ({
          id: model.id,
          capabilities: toWebCapabilities(model.capabilities),
          isAvailable: model.available,
          isDefault: model.isDefault,
        }));
        const result = pickChatDriverModelID({
          currentModelID: testCase.currentModelID,
          models,
          defaultModelID: models.find((model) => model.isDefault)?.id ?? null,
        });

        if (testCase.expectedSuccess) {
          expect(result).toEqual({ ok: true, modelID: testCase.expectedSuccess });
        } else {
          expect(result).toEqual({ ok: false, reason: testCase.expectedError });
        }
      });
    }
  });
});

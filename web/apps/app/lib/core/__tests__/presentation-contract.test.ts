/**
 * Presentation contract golden tests.
 *
 * Shared fixture: model-contracts/presentation_fixtures.v1.json.
 * Every client renders model cards and the provider catalog through one shared set of
 * components, so the structural elements derived from the same fixture must match:
 *   - whether the vendor subtitle is shown
 *   - whether the recommended badge is shown
 *   - capability badge order and count
 *   - pricing branch (priced / free / unknown)
 *   - whether the reasoning / web search / image generation pickers appear
 *   - container level: group header count and order, empty state, offline banner,
 *     Manual-Retained section
 *
 * Strategy: rather than mounting the whole React tree (expensive, needs jsdom + RTL, and
 * ModelCard is widely coupled), pure derive*Presentation() functions take the fixture
 * metadata fields and return a PresentationDescriptor whose shape matches the fixture
 * expectedRender. Those functions are themselves part of the contract: they define how
 * metadata fields map to UI structure assertions.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

// Fixture types

type PricingStatus = 'priced' | 'free' | 'unknown';

interface FixturePricing {
  promptPerMToken: number | null;
  completionPerMToken: number | null;
  cachedInputPerMToken: number | null;
}

interface FixtureProfiles {
  reasoning: string | null;
  webSearch: string | null;
  imageGen: string | null;
}

interface FixtureUIHints {
  groupKey?: string;
  groupName?: string;
  rank: number;
  recommended: boolean;
  badgeOrder: string[];
}

interface FixtureModel {
  canonicalModelId: string;
  displayName: string;
  vendorKey: string | null;
  vendorName: string | null;
  contextLength?: number | null;
  pricing?: FixturePricing | null;
  pricingStatus: PricingStatus;
  capabilities: string[];
  profiles?: FixtureProfiles;
  uiHints: FixtureUIHints;
}

interface LeafCase {
  id: string;
  providerKind: string;
  model: FixtureModel;
  expectedRender: ExpectedLeafRender;
}

interface ContainerCase {
  id: string;
  providerKind: string;
  models: FixtureModel[];
  expectedRender: ExpectedContainerRender;
}

interface FixtureProviderData {
  displayName: string;
  defaultModelId?: string | null;
  validationModelId?: string | null;
  resolveMap?: Record<string, string>;
  models: Record<string, FixtureModel>;
}

interface ManualRetainedRef {
  modelId: string;
  displayName: string;
}

interface StateCase {
  id: string;
  providerKind: string;
  metadataSource?: 'freshNetwork' | 'cachedOffline';
  providerData: FixtureProviderData;
  manualRetainedModels?: ManualRetainedRef[];
  expectedRender: ExpectedStateRender;
}

interface ExpectedLeafRender {
  showsVendorSubtitle: boolean;
  vendorSubtitleText: string | null;
  showsRecommendedBadge: boolean;
  capabilityBadges: string[];
  showsCachedPricing: boolean;
  pricingBranch: PricingStatus;
  showsReasoningPicker: boolean;
  showsWebSearchPicker: boolean;
  showsImageGenPicker: boolean;
}

interface ExpectedContainerRender {
  groupHeaders: string[];
  modelOrderWithinGroups: Record<string, string[]>;
}

interface ExpectedStateRender {
  showsEmptyStateCopy: boolean;
  showsRetryAction: boolean;
  showsCatalogList: boolean;
  showsOfflineBanner: boolean;
  showsManualRetainedSection: boolean;
  manualRetainedHeaderKey?: string;
}

interface FixtureFile {
  contractVersion: number;
  leafCases: LeafCase[];
  containerCases: ContainerCase[];
  stateCases: StateCase[];
}

const fixturePath = path.resolve(
  process.cwd(),
  '../../../shared/model-contracts/presentation_fixtures.v1.json',
);
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as FixtureFile;

// Presentation Selector
//
// These three pure functions are the contract for how the shared rendering components
// interpret metadata fields; equivalent fixtures must produce the same descriptor everywhere.

type PresentationDescriptor = ExpectedLeafRender;
type ContainerDescriptor = ExpectedContainerRender;
type StateDescriptor = ExpectedStateRender;

const AGGREGATOR_PROVIDER_KINDS = new Set(['openRouter', 'siliconFlow']);

/**
 * Leaf level: map a single model to a PresentationDescriptor.
 *
 *   - vendor subtitle: shown only when both vendorKey and vendorName are non-empty,
 *     otherwise the whole slot is hidden
 *   - recommended badge: uiHints.recommended === true
 *   - capability badges: badgeOrder order, minus 'text', minus anything absent from capabilities
 *   - pricing branch: read straight from pricingStatus; only priced shows the cache pricing row
 *   - reasoning/webSearch/imageGen pickers: shown only when the matching profiles field is
 *     non-null (capabilities may list reasoning while profiles.reasoning is null, and then no
 *     picker may be shown)
 */
function derivePresentation(model: FixtureModel): PresentationDescriptor {
  const showsVendorSubtitle = Boolean(model.vendorKey && model.vendorName);
  const vendorSubtitleText = showsVendorSubtitle ? (model.vendorName as string) : null;

  const capabilitySet = new Set(model.capabilities);
  const capabilityBadges = (model.uiHints.badgeOrder ?? []).filter(
    (cap) => cap !== 'text' && capabilitySet.has(cap),
  );

  const pricingBranch = model.pricingStatus;
  const showsCachedPricing = pricingBranch === 'priced';

  const profiles = model.profiles ?? { reasoning: null, webSearch: null, imageGen: null };

  return {
    showsVendorSubtitle,
    vendorSubtitleText,
    showsRecommendedBadge: model.uiHints.recommended === true,
    capabilityBadges,
    showsCachedPricing,
    pricingBranch,
    showsReasoningPicker: profiles.reasoning != null,
    showsWebSearchPicker: profiles.webSearch != null,
    showsImageGenPicker: profiles.imageGen != null,
  };
}

/**
 * Container level: map a provider model list to a ContainerDescriptor.
 *
 * Rules:
 *   - aggregator providers (openRouter / siliconFlow): group by vendorName, order group headers
 *     by first appearance of the vendor, sort within a vendor by uiHints.rank descending
 *   - direct providers: group by uiHints.groupName, order group headers by the highest rank in
 *     each group descending, sort within a group by rank descending
 *
 * Tie-breaker: equal ranks sort by canonicalModelId ASCII ascending.
 */
function deriveContainerPresentation(
  providerKind: string,
  models: FixtureModel[],
): ContainerDescriptor {
  const isAggregator = AGGREGATOR_PROVIDER_KINDS.has(providerKind);

  // 1) Group: aggregators by vendorName, direct providers by groupName
  const groupOrder: string[] = [];
  const buckets = new Map<string, FixtureModel[]>();

  for (const model of models) {
    const groupName = isAggregator
      ? (model.vendorName ?? '')
      : (model.uiHints.groupName ?? '');
    if (!buckets.has(groupName)) {
      buckets.set(groupName, []);
      groupOrder.push(groupName);
    }
    buckets.get(groupName)!.push(model);
  }

  // 2) Within a group: rank descending, tie-broken by canonicalModelId ASCII ascending
  const sortedBuckets = new Map<string, FixtureModel[]>();
  for (const [name, list] of buckets) {
    const sorted = [...list].sort((a, b) => {
      const rankDiff = (b.uiHints.rank ?? 0) - (a.uiHints.rank ?? 0);
      if (rankDiff !== 0) return rankDiff;
      return a.canonicalModelId.localeCompare(b.canonicalModelId);
    });
    sortedBuckets.set(name, sorted);
  }

  // 3) Group header order
  let orderedHeaders: string[];
  if (isAggregator) {
    // Aggregator: keep the first-appearance order of vendors, so groupOrder stays as is
    orderedHeaders = groupOrder;
  } else {
    // Direct: highest rank per group descending; equal ranks fall back to group name ASCII ascending for stability
    orderedHeaders = [...groupOrder].sort((a, b) => {
      const maxA = Math.max(...sortedBuckets.get(a)!.map((m) => m.uiHints.rank ?? 0));
      const maxB = Math.max(...sortedBuckets.get(b)!.map((m) => m.uiHints.rank ?? 0));
      if (maxA !== maxB) return maxB - maxA;
      return a.localeCompare(b);
    });
  }

  const modelOrderWithinGroups: Record<string, string[]> = {};
  for (const header of orderedHeaders) {
    modelOrderWithinGroups[header] = sortedBuckets.get(header)!.map((m) => m.canonicalModelId);
  }

  return {
    groupHeaders: orderedHeaders,
    modelOrderWithinGroups,
  };
}

/**
 * State level: map provider data, metadata source and the manual-retained list onto the
 * visibility of the empty state, retry, list, offline banner and Manual-Retained section.
 */
function deriveStatePresentation(input: {
  metadataSource?: 'freshNetwork' | 'cachedOffline';
  providerData: FixtureProviderData;
  manualRetainedModels?: ManualRetainedRef[];
}): StateDescriptor {
  const modelCount = Object.keys(input.providerData.models ?? {}).length;
  const showsCatalogList = modelCount > 0;
  const showsEmptyStateCopy = !showsCatalogList;
  const showsRetryAction = showsEmptyStateCopy;

  const showsOfflineBanner = input.metadataSource === 'cachedOffline';

  const manualCount = input.manualRetainedModels?.length ?? 0;
  const showsManualRetainedSection = manualCount > 0;

  const descriptor: StateDescriptor = {
    showsEmptyStateCopy,
    showsRetryAction,
    showsCatalogList,
    showsOfflineBanner,
    showsManualRetainedSection,
  };
  if (showsManualRetainedSection) {
    descriptor.manualRetainedHeaderKey = 'providers.catalog.manualRetainedHeader';
  }
  return descriptor;
}

// Tests

describe('presentation contract — leaf', () => {
  for (const leafCase of fixture.leafCases) {
    it(`${leafCase.id} — derivePresentation matches expectedRender`, () => {
      const actual = derivePresentation(leafCase.model);
      // expectedRender carries a $comment debug field, so compare only the contract fields
      const expected: ExpectedLeafRender = {
        showsVendorSubtitle: leafCase.expectedRender.showsVendorSubtitle,
        vendorSubtitleText: leafCase.expectedRender.vendorSubtitleText,
        showsRecommendedBadge: leafCase.expectedRender.showsRecommendedBadge,
        capabilityBadges: leafCase.expectedRender.capabilityBadges,
        showsCachedPricing: leafCase.expectedRender.showsCachedPricing,
        pricingBranch: leafCase.expectedRender.pricingBranch,
        showsReasoningPicker: leafCase.expectedRender.showsReasoningPicker,
        showsWebSearchPicker: leafCase.expectedRender.showsWebSearchPicker,
        showsImageGenPicker: leafCase.expectedRender.showsImageGenPicker,
      };
      expect(actual).toEqual(expected);
    });
  }
});

describe('presentation contract — container', () => {
  for (const containerCase of fixture.containerCases) {
    it(`${containerCase.id} — deriveContainerPresentation matches expectedRender`, () => {
      const actual = deriveContainerPresentation(
        containerCase.providerKind,
        containerCase.models,
      );
      const expected: ExpectedContainerRender = {
        groupHeaders: containerCase.expectedRender.groupHeaders,
        modelOrderWithinGroups: containerCase.expectedRender.modelOrderWithinGroups,
      };
      expect(actual).toEqual(expected);
    });
  }
});

describe('presentation contract — state', () => {
  for (const stateCase of fixture.stateCases) {
    it(`${stateCase.id} — deriveStatePresentation matches expectedRender`, () => {
      const actual = deriveStatePresentation({
        metadataSource: stateCase.metadataSource,
        providerData: stateCase.providerData,
        manualRetainedModels: stateCase.manualRetainedModels,
      });
      const expected: ExpectedStateRender = {
        showsEmptyStateCopy: stateCase.expectedRender.showsEmptyStateCopy,
        showsRetryAction: stateCase.expectedRender.showsRetryAction,
        showsCatalogList: stateCase.expectedRender.showsCatalogList,
        showsOfflineBanner: stateCase.expectedRender.showsOfflineBanner,
        showsManualRetainedSection: stateCase.expectedRender.showsManualRetainedSection,
      };
      if (stateCase.expectedRender.showsManualRetainedSection) {
        expected.manualRetainedHeaderKey = stateCase.expectedRender.manualRetainedHeaderKey;
      }
      expect(actual).toEqual(expected);
    });
  }
});

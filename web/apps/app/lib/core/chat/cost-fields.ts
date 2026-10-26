/**
 * Helpers that derive the cost and citation fields.
 *
 * - `mergeCitationsWithExisting`: merges old and new citations by normalizeUrl on a
 *   continuation or a regenerate.
 * - `applyCitationsToMessage`: writes citations back onto a given message in the store.
 * - `deriveCostFields`: computes cost and cache token fields from a UsageBreakdown for
 *   use on a ChatMessage.
 * - `mergeMessageUsageFields`: accumulates the normalized token usage fields across a
 *   continuation.
 */

import type { StoreApi } from 'zustand';
import type { AIModel, Attachment, Citation, Provider } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import type { StreamUsage } from '../providers/types';
import { normalizeUrl } from '../providers/transport/citation-utils';
import {
  calcCost,
  calcCostFromResolved,
  estimateCostWithCurrency,
  type CalcCostResult,
  type CostSource,
  type PricingInput,
} from './cost';
import type { UsageBreakdown } from './usage-breakdown';
import { getRelayRuntimeConfig, resolveCatalogModel } from '../metadata/metadata-client';
import { resolveRelayOfficialMatch } from '../providers/relay-official-catalog-match';
import { resolveRelaySelectionTransport } from '../providers/provider-selection-snapshot';
import { estimatePricingV2, type PricingV2Estimate } from '../pricing/pricing-v2-estimate';
import { isOfficialEndpointKind } from '@oriveo/core/providers/transport/endpoint-resolver';
import {
  connectionRegionId,
  providerPricedAllInUsd,
  selectRegionPricing,
} from '../cost/region-pricing';
import type { ResolvedModelMetadata } from '../metadata/metadata-client';
import {
  addMessageCost,
  mergeNonUsdCost,
  normalizeCostCurrency,
  type MessageCostParts,
  type NonUsdCost,
} from '../cost/cost-currency';
import { COST_EPSILON } from '../../utils/format-utils';

/** Connection fields that pricing looks at: kind, whether it is a subscription, and the endpoint source (region price selection). */
export type CostConnection = Pick<Provider, 'kind' | 'authMode' | 'baseURLText' | 'endpointSource' | 'relayRequested'>;

/**
 * Cost record of one message: cost / source describe only the USD part (0 + 'unknown' when there is no USD part);
 * the single non-USD part goes into nonUsdCost (omitted = none), with no currency conversion.
 */
export type CostRecord = CalcCostResult & { nonUsdCost?: NonUsdCost };

/** One priced part: the amount is in the original currencyCode (default = USD). */
interface CostPart {
  cost: number;
  source: CostSource;
  currencyCode: string | undefined;
}

/**
 * Merge old and new citations on a continuation or regenerate.
 * Same strategy as mergeCitation: normalizeUrl is the primary key and arrival order is
 * preserved. Written out separately here rather than reusing mergeCitation, which is
 * built for the incremental ctx.citations case: the old citations go in first and new
 * ones with the same key are skipped, so nothing is duplicated.
 */
export function mergeCitationsWithExisting(
  existing: Citation[] | undefined,
  next: Citation[] | undefined,
): Citation[] | undefined {
  if (!existing || existing.length === 0) return next;
  if (!next || next.length === 0) return existing;
  const merged: Citation[] = [...existing];
  const seen = new Set(existing.map((c) => normalizeUrl(c.url)));
  for (const c of next) {
    const key = normalizeUrl(c.url);
    if (key && seen.has(key)) continue;
    if (key) seen.add(key);
    merged.push(c);
  }
  return merged;
}

export function applyCitationsToMessage(
  store: StoreApi<AppStore>,
  conversationId: string,
  messageId: string,
  citations: Citation[] | undefined,
): void {
  if (!citations || citations.length === 0) return;
  const conversation = store.getState().conversations.find((c) => c.id === conversationId);
  const target = conversation?.messages.find((m) => m.id === messageId);
  if (!conversation || !target) return;
  const merged = mergeCitationsWithExisting(target.citations, citations);
  if (!merged || merged.length === 0) return;
  store.getState().updateConversation(conversationId, {
    messages: conversation.messages.map((m) =>
      m.id === messageId ? { ...m, citations: merged } : m,
    ),
  });
}

/**
 * Map a model's own local prices onto calcCost's PricingInput.
 *
 * The units differ, so do not mix them: `promptPrice` and `completionPrice` are
 * **per token** (already divided by 1e6 during model sync), while the four cache prices
 * are **per M token**, and calcCost converts each on its own terms.
 * Returns null when both primary prices are missing so calcCost can honestly report
 * `unknown`, which is what "the price really is not known" looks like. Do not invent a 0.
 */
function localPricingOf(model: AIModel): PricingInput | null {
  if (typeof model.promptPrice !== 'number' && typeof model.completionPrice !== 'number') {
    return null;
  }
  return {
    promptPerToken: model.promptPrice,
    completionPerToken: model.completionPrice,
    cachedInputPerMToken: model.cacheReadInputPerMToken,
    cacheCreationInputPerMToken: model.cacheCreationInputPerMToken,
    cacheWrite5mPerMToken: model.cacheWrite5mPerMToken,
    cacheWrite1hPerMToken: model.cacheWrite1hPerMToken,
  };
}

/**
 * The priced parts of a message -> cost record: USD parts add into cost; non-USD parts merge into nonUsdCost via {@link mergeNonUsdCost}.
 * A part without a valid currency is recorded as unknown rather than falling back to USD; unpriced parts are skipped.
 */
function recordOfParts(parts: readonly CostPart[]): CostRecord {
  let usd: CalcCostResult = { cost: 0, source: 'unknown' };
  let nonUsd: NonUsdCost | undefined;
  for (const part of parts) {
    if (part.source === 'unknown') continue;
    const currency = normalizeCostCurrency(part.currencyCode);
    if (currency === null) continue;
    if (currency === 'USD') {
      usd = usd.source === 'unknown'
        ? { cost: part.cost, source: part.source }
        : { cost: usd.cost + part.cost, source: usd.source };
    } else {
      nonUsd = mergeNonUsdCost(nonUsd, { currencyCode: currency, amount: part.cost, costSource: part.source });
    }
  }
  return nonUsd ? { ...usd, nonUsdCost: nonUsd } : usd;
}

/**
 * pricingV2 estimate -> single-message cost record (cost-currency.v1 recordCases).
 *
 * Pass one estimate or all estimates of one message (e.g. generation cost + retrieval cost); estimated ones are recorded
 * in the original currency into the matching part, unavailable ones are not recorded; when nothing is recorded the result is
 * cost 0 + 'unknown' with no nonUsdCost.
 */
export function costResultOfEstimate(estimates: PricingV2Estimate | readonly PricingV2Estimate[]): CostRecord {
  const list: readonly PricingV2Estimate[] = Array.isArray(estimates) ? estimates : [estimates as PricingV2Estimate];
  return recordOfParts(list.map((estimate) => estimate.status === 'estimated'
    ? { cost: estimate.amount, source: 'localEstimate', currencyCode: estimate.currencyCode }
    : { cost: 0, source: 'unknown', currencyCode: undefined }));
}

/**
 * Cost of one delivered round (cost-currency.v1 mixed_cny_generation_usd_retrieval): the generation cost record plus the retrieval cost (USD).
 * costSource describes the merged USD part: localEstimate when the generation USD part is unknown while retrieval cost > 0, otherwise the generation's own.
 * The message costSource and usage reporting use this, not deriveCostFields' costSource directly.
 */
export function roundCostOf(
  costInfo: { cost: number; costSource: CostSource; nonUsdCost?: NonUsdCost },
  retrievalCost: number,
): MessageCostParts & { costSource: CostSource } {
  const parts = addMessageCost(
    { estimatedCost: costInfo.cost, nonUsdCost: costInfo.nonUsdCost },
    { estimatedCost: retrievalCost },
  );
  const costSource = costInfo.costSource === 'unknown' && retrievalCost > COST_EPSILON
    ? 'localEstimate'
    : costInfo.costSource;
  return { ...parts, costSource };
}

/**
 * The catalog price of this message: Relay uses the same official match as the unit-price label ({@link resolveRelayOfficialMatch}),
 * the matched entry is used as the catalog price as is, with no region selection; official providers select the region price by
 * the connection's effective region ({@link selectRegionPricing}).
 * Returns catalog (the catalog entry) and resolved (the selected price used for estimating); null when not found.
 */
function catalogPricingOf(
  model: AIModel,
  connection: CostConnection | undefined,
): { catalog: ResolvedModelMetadata | null; resolved: ResolvedModelMetadata | null } {
  const providerKind = connection?.kind;
  if (!providerKind) return { catalog: null, resolved: null };
  if (providerKind === 'relay') {
    const match = resolveRelayOfficialMatch(
      model,
      resolveRelaySelectionTransport(connection as Provider, model),
      getRelayRuntimeConfig(),
    );
    const catalog = match?.metadata ?? null;
    return { catalog, resolved: catalog };
  }
  const catalog = resolveCatalogModel(model.id, providerKind);
  return { catalog, resolved: catalog ? selectRegionPricing(catalog, connectionRegionId(connection)) : null };
}

/**
 * Whether the model's own local price (no currency, treated as USD) may be used as a fallback: only when the selected currency can be determined to be USD;
 * when the currency cannot be determined or is non-USD there is never a fallback (recorded as unknown).
 * The catalog-miss branch uses the same decision as Android DeliveredCostResolver.allowsLocalPriceWithoutCatalog; the catalog-hit branches are:
 * - Relay: when an official entry is matched, pricing follows the matched entry (same as official messages) with no fallback (a pricingV2 that cannot estimate means unknown); the model's own price is used only when nothing matched.
 * - Custom endpoint: no region selection, falls back as before.
 * - Official provider with a catalog hit: only the entry's price is used (a selected region entry estimates at that region's price); if it cannot estimate the result is unknown with no fallback
 *   (an entry with pricingV2 but a pricingStatus of unknown is also recorded as unknown, as unpriced).
 * - Official provider with a catalog miss: fall back only if every price of this provider's catalog is USD ({@link providerPricedAllInUsd}); empty metadata means it cannot be determined.
 */
function allowsLocalPrice(
  connection: CostConnection | undefined,
  catalog: ResolvedModelMetadata | null,
): boolean {
  if (!connection) return false;
  if (connection.kind === 'relay') return catalog === null;
  if (!isOfficialEndpointKind(connection.kind) || connection.endpointSource === 'custom') return true;
  // Once an official entry matches only the entry's price is used; if it cannot estimate the result is unknown and the model's own price is not used.
  if (catalog) return false;
  return providerPricedAllInUsd(connection.kind);
}

/**
 * Compute the cost from a UsageBreakdown and fill in the cache and costSource fields of
 * a ChatMessage.
 *
 * - For the catalog price see {@link catalogPricingOf}: Relay uses the official matched entry (no region selection), official providers select the region price by the connection's effective region;
 *   estimates use the selected price and currency, with no conversion.
 * - The actual upstream cost (USD) comes first; when the catalog carries a per_token pricingV2 the local estimate goes through {@link estimatePricingV2}
 *   (length tiers / time windows are priced by `now`), and unavailable honestly returns `unknown`, never an invented 0.
 * - Otherwise {@link calcCost} is used (consuming metadata cachedInput / cacheWrite5m/1h).
 * - When the breakdown is missing (an older strategy that does not expose one, or empty usage) it falls back to {@link estimateCostWithCurrency}.
 * - The model's own local price is a fallback only when the selected currency can be determined to be USD ({@link allowsLocalPrice}).
 * - cost / costSource describe only the USD part; a non-USD estimate goes into `nonUsdCost` (cost 0 + 'unknown'), and USD omits that key.
 * - The returned fields spread straight onto a ChatMessage:
 *     `cachedInputTokens` / `cacheCreation5mTokens` / `cacheCreation1hTokens` / `costSource`
 */
export function deriveCostFields(
  usage: StreamUsage | undefined,
  model: AIModel | undefined,
  connection: CostConnection | undefined,
  /** The pricing instant (for time windows): passed explicitly by the caller, production passes the current time and tests a fixed instant (no default). */
  now: () => Date,
  /**
   * Unit count for per-unit pricing (image count / seconds): when the entry's unit is not per_token the estimate is perUnit x count, ignoring usage.
   * Required (so it cannot be forgotten): paths that cannot produce a per-unit result pass undefined explicitly (= not estimated per unit, handed to per-token pricing);
   * paths that may produce images pass {@link generatedImageUnits}.
   */
  units: number | undefined,
): DerivedCostFields {
  const perUnit = perUnitCostFields(usage, model, connection, units);
  if (perUnit) return perUnit;
  const whole = deriveLegCostFields(usage, model, connection, now);
  if (!usage || whole.costSource === 'subscription') return whole;
  // Multi-leg message: if any leg reported no usage the whole message is unknown; tokens are still summed over the legs that reported.
  if (usage.allLegsReported === false) return { ...withoutCost(whole), cost: 0, costSource: 'unknown' };
  if (!usage.legs || usage.legs.length < 2) return whole;
  // Estimate each leg (that leg's actual upstream cost > estimate) and add them; if any leg cannot be estimated (neither USD nor non-USD) the whole message is unknown, never trusting an undercounted sum.
  return sumLegCostFields(whole, usage.legs.map((leg) => deriveLegCostFields(leg, model, connection, now)));
}

/**
 * Number of images generated this round, used as the units of {@link deriveCostFields}.
 * Honestly returns 0 when there are none: per-unit entries record unknown for 0 units (not estimated by token, no "at least 1 unit" minimum), and per-token entries ignore the count.
 */
export function generatedImageUnits(attachments: readonly Attachment[]): number {
  return attachments.filter((attachment) => attachment.kind === 'image').length;
}

/**
 * Per-unit pricing: when the selected entry's pricingV2.unit is not per_token, it has a perUnit, and the caller supplied a unit count,
 * the whole message is priced once from the actual count (not per leg), amount = perUnit x count, recorded in the entry's currency, independent of usage (estimated even when the upstream reported no usage).
 * - Actual upstream cost comes first: on a non-Relay connection where the upstream reported it (every leg must report it for multi-leg) this returns null so the per-token path records upstream (Relay never adopts the upstream cost).
 * - Free entries (pricingStatus free) record 0 (an estimate source), regardless of the count.
 * - 0 units record unknown, neither switching to per-token estimating nor using an "at least 1 unit" minimum.
 * Returns null when not applicable, handing over to per-token estimating.
 */
function perUnitCostFields(
  usage: StreamUsage | undefined,
  model: AIModel | undefined,
  connection: CostConnection | undefined,
  units: number | undefined,
): DerivedCostFields | null {
  if (units == null || !Number.isFinite(units) || units < 0 || !model) return null;
  if (connection?.authMode === 'subscription') return null;
  const { resolved } = catalogPricingOf(model, connection);
  if (resolved?.pricingStatus !== 'priced' && resolved?.pricingStatus !== 'free') return null;
  const perUnitPrice = perUnitPriceOf(resolved);
  if (!perUnitPrice) return null;
  if (connection?.kind !== 'relay' && everyLegReportedUpstreamCost(usage)) return null;
  const messageUsage = deriveMessageUsageFields(usage);
  if (resolved.pricingStatus === 'free') {
    return { ...costFieldsOf({ cost: 0, source: 'localEstimate' }), ...messageUsage };
  }
  if (units === 0) return { cost: 0, costSource: 'unknown', ...messageUsage };
  const record = costResultOfEstimate({
    status: 'estimated',
    amount: perUnitPrice.perUnit * units,
    currencyCode: perUnitPrice.currencyCode,
  });
  return { ...costFieldsOf(record), ...messageUsage };
}

/**
 * Per-unit price and currency (unit price and unit are read from pricingV2 first): if pricingV2 exists only it is used;
 * otherwise the legacy price's pricingUnit + costPerUnit are read (a missing pricingUnit counts as per_token). Returns null for per-token pricing.
 */
function perUnitPriceOf(
  resolved: ResolvedModelMetadata,
): { perUnit: number; currencyCode: string | undefined } | null {
  const pricingV2 = resolved.pricingV2;
  if (pricingV2) {
    if (pricingV2.unit === 'per_token' || typeof pricingV2.perUnit !== 'number') return null;
    return { perUnit: pricingV2.perUnit, currencyCode: pricingV2.currencyCode };
  }
  const legacyUnit = resolved.pricingUnit ?? 'per_token';
  const costPerUnit = resolved.pricing?.costPerUnit;
  if (legacyUnit === 'per_token' || typeof costPerUnit !== 'number') return null;
  return { perUnit: costPerUnit, currencyCode: resolved.currencyCode };
}

/**
 * Precondition for adopting the upstream actual cost under per-unit pricing: a single leg reported it; for multi-leg every leg must report it.
 * If any leg reported no usage or only some legs reported the actual cost it is not adopted (the merged upstreamCost is just the sum of the reporting legs), and the whole message is estimated per unit.
 */
function everyLegReportedUpstreamCost(usage: StreamUsage | undefined): boolean {
  if (!usage || usage.allLegsReported === false) return false;
  const reported = (leg: StreamUsage) => {
    const upstreamCost = leg.breakdown?.upstreamCost;
    return typeof upstreamCost === 'number' && Number.isFinite(upstreamCost);
  };
  return usage.legs && usage.legs.length > 0 ? usage.legs.every(reported) : reported(usage);
}

/**
 * Multi-leg per-currency summing: USD legs add up, and non-USD goes through {@link mergeNonUsdCost} into the single non-USD part
 * (same rule as single-record recordCases: a second non-USD currency -> {first currency, 0, unknown}, the USD part is kept, no addition and no conversion);
 * if any leg cannot be estimated (neither USD nor non-USD) the whole message is unknown.
 * USD part source: upstream is recorded only when every leg's USD part came from the actual upstream cost; if any leg is an estimate that estimate's source is recorded. Token / cache fields come from `whole`.
 */
export function sumLegCostFields(whole: DerivedCostFields, records: readonly DerivedCostFields[]): DerivedCostFields {
  const unknown: DerivedCostFields = { ...withoutCost(whole), cost: 0, costSource: 'unknown' };
  if (records.some((record) => record.costSource === 'unknown' && !record.nonUsdCost)) return unknown;
  let usd: CalcCostResult = { cost: 0, source: 'unknown' };
  let nonUsd: NonUsdCost | undefined;
  for (const record of records) {
    if (record.costSource !== 'unknown') {
      usd = usd.source === 'unknown'
        ? { cost: record.cost, source: record.costSource }
        : { cost: usd.cost + record.cost, source: usd.source === 'upstream' ? record.costSource : usd.source };
    }
    if (record.nonUsdCost) nonUsd = mergeNonUsdCost(nonUsd, record.nonUsdCost);
  }
  return { ...withoutCost(whole), ...costFieldsOf(nonUsd ? { ...usd, nonUsdCost: nonUsd } : usd) };
}

export type DerivedCostFields = {
  cost: number;
  costSource: CostSource;
  nonUsdCost?: NonUsdCost;
  cachedInputTokens?: number;
  cacheCreation5mTokens?: number;
  cacheCreation1hTokens?: number;
  inputTokens?: number;
  outputTokens?: number;
  cacheCreationInputTokens?: number;
};

function withoutCost(fields: DerivedCostFields): Omit<DerivedCostFields, 'cost' | 'costSource' | 'nonUsdCost'> {
  const { cost: _cost, costSource: _source, nonUsdCost: _nonUsd, ...rest } = fields;
  return rest;
}

/** Estimate a single leg (or the merged whole message's token / cache fields); see {@link deriveCostFields}. */
function deriveLegCostFields(
  usage: StreamUsage | undefined,
  model: AIModel | undefined,
  connection: CostConnection | undefined,
  now: () => Date,
): DerivedCostFields {
  const messageUsage = deriveMessageUsageFields(usage);
  const providerKind = connection?.kind;
  // Short-circuit subscription mode **before** any price lookup: Grok's usage parser
  // turns `cost_in_usd_ticks` into `breakdown.upstreamCost`, and calcCost prefers the
  // upstream value. Without the short-circuit every message would show an amount
  // converted at API rates that the user never paid, since they pay a monthly fee.
  // Token counts are still shown.
  if (connection?.authMode === 'subscription') {
    return { cost: 0, costSource: 'subscription', ...messageUsage };
  }
  if (!usage || !model) {
    return { cost: 0, costSource: 'unknown', ...messageUsage };
  }
  const { catalog, resolved } = catalogPricingOf(model, connection);
  const localPriceAllowed = allowsLocalPrice(connection, catalog);
  // Relay does not adopt the upstream actual cost: the unit and currency of a cost reported by an arbitrary relay cannot be trusted, so estimate by the matched entry / local price.
  const breakdown: UsageBreakdown | undefined = providerKind === 'relay' && usage.breakdown
    ? withoutUpstreamCost(usage.breakdown)
    : usage.breakdown;
  if (breakdown && providerKind) {
    const legacy = calcCostFromResolved(breakdown, resolved);
    // The actual upstream cost is USD; the catalog price is recorded in the selected price's currency.
    let result: CostRecord = legacy.source === 'localEstimate'
      ? recordOfParts([{ cost: legacy.cost, source: legacy.source, currencyCode: resolved?.currencyCode }])
      : legacy;
    // pricingV2 is read only when the legacy pricingStatus is known (priced / free): with unknown, v2 does not take part
    // and the legacy path honestly judges unknown instead of producing a number.
    const v2 = legacy.source !== 'upstream'
      && (resolved?.pricingStatus === 'priced' || resolved?.pricingStatus === 'free')
      && resolved.pricingV2
      ? estimatePricingV2(resolved.pricingV2, {
          // breakdown.promptTokens is already the uncached input (cache reads / writes have their own buckets), so nothing is subtracted again.
          uncachedInputTokens: breakdown.promptTokens,
          cacheReadTokens: breakdown.cachedInputTokens,
          cacheWrite5mTokens: breakdown.cacheCreation5mTokens,
          cacheWrite1hTokens: breakdown.cacheCreation1hTokens,
          outputTokens: breakdown.completionTokens,
        }, now())
      : undefined;
    if (v2?.status === 'estimated' || v2?.status === 'unavailable') {
      result = costResultOfEstimate(v2);
    } else if (legacy.source === 'unknown' && localPriceAllowed) {
      // The model is not in the catalog (e.g. a Relay model that matched no official entry):
      // calcCost would then return (0, unknown) and zero out the whole cost. The fallback must
      // bucket the same way: feed it the model's own local prices (USD), so calcCost applies the
      // same fallback ratios internally (read x0.5, 5m write x1.25, 1h write x2.0) and both
      // paths agree. Multiplying the cache-inclusive total input directly would roughly
      // double the estimate on every cache hit.
      result = calcCost(breakdown, localPricingOf(model));
    }
    // Only emit a cache field that was actually observed. Writing 0 would claim the provider
    // reported a zero, which is a different fact from it reporting nothing at all.
    const cacheFields: {
      cachedInputTokens?: number;
      cacheCreation5mTokens?: number;
      cacheCreation1hTokens?: number;
    } = {};
    if (breakdown.cacheReadObserved || breakdown.cachedInputTokens > 0) {
      cacheFields.cachedInputTokens = breakdown.cachedInputTokens;
    }
    if (breakdown.cacheWriteObserved || breakdown.cacheCreation5mTokens > 0) {
      cacheFields.cacheCreation5mTokens = breakdown.cacheCreation5mTokens;
    }
    if (breakdown.cacheWriteObserved || breakdown.cacheCreation1hTokens > 0) {
      cacheFields.cacheCreation1hTokens = breakdown.cacheCreation1hTokens;
    }
    return { ...costFieldsOf(result), ...cacheFields, ...messageUsage };
  }
  // Fallback: the older two-item estimate (no cache split), using the selected price and currency; without a valid currency it is recorded as unknown, never falling back to USD.
  // The selected catalog price is tried first (official providers use resolved first), then the model's own price if allowed.
  const fallback = estimateCostWithCurrency(usage, model, providerKind, resolved, false)
    ?? (localPriceAllowed ? estimateCostWithCurrency(usage, model, providerKind, null, true) : null);
  const record = fallback == null
    ? { cost: 0, source: 'unknown' as const }
    : recordOfParts([{ cost: fallback.amount, source: 'localEstimate', currencyCode: fallback.currencyCode }]);
  return { ...costFieldsOf(record), ...messageUsage };
}

function withoutUpstreamCost(breakdown: UsageBreakdown): UsageBreakdown {
  const { upstreamCost: _upstreamCost, ...rest } = breakdown;
  return rest;
}

function costFieldsOf(record: CostRecord): {
  cost: number;
  costSource: CostSource;
  nonUsdCost?: NonUsdCost;
} {
  return {
    cost: record.cost,
    costSource: record.source,
    ...(record.nonUsdCost ? { nonUsdCost: record.nonUsdCost } : {}),
  };
}

function deriveMessageUsageFields(usage: StreamUsage | undefined): {
  inputTokens?: number;
  outputTokens?: number;
  cachedInputTokens?: number;
  cacheCreationInputTokens?: number;
} {
  if (!usage) return {};
  if (usage.messageUsage) return { ...usage.messageUsage };
  if (usage.breakdown) {
    const breakdown = usage.breakdown;
    const cacheCreationInputTokens =
      breakdown.cacheCreation5mTokens + breakdown.cacheCreation1hTokens;
    return {
      inputTokens:
        breakdown.promptTokens +
        breakdown.cachedInputTokens +
        breakdown.cacheCreation5mTokens +
        breakdown.cacheCreation1hTokens,
      outputTokens: breakdown.completionTokens,
      // The newer parser uses the observed flag to tell a real 0 from a missing field; a positive value still matches older breakdowns.
      ...(breakdown.cacheReadObserved || breakdown.cachedInputTokens > 0
        ? { cachedInputTokens: breakdown.cachedInputTokens }
        : {}),
      ...(breakdown.cacheWriteObserved || cacheCreationInputTokens > 0
        ? { cacheCreationInputTokens }
        : {}),
    };
  }
  return {
    ...(typeof usage.prompt_tokens === 'number' ? { inputTokens: usage.prompt_tokens } : {}),
    ...(typeof usage.completion_tokens === 'number'
      ? { outputTokens: usage.completion_tokens }
      : {}),
  };
}

/**
 * Continuation case: accumulate the cache token fields of prev and this round.
 *
 * - Stays undefined only when both sides are missing; if either side is confirmed
 *   (including a confirmed 0), the accumulated result is kept.
 * - Callers spread it onto a ChatMessage: `{ ...interruptedMsg, ...mergeMessageUsageFields(prev, cur) }`
 */
export function mergeMessageUsageFields(
  prev: {
    inputTokens?: number;
    outputTokens?: number;
    cachedInputTokens?: number;
    cacheCreationInputTokens?: number;
    cacheCreation5mTokens?: number;
    cacheCreation1hTokens?: number;
  },
  cur: {
    inputTokens?: number;
    outputTokens?: number;
    cachedInputTokens?: number;
    cacheCreationInputTokens?: number;
    cacheCreation5mTokens?: number;
    cacheCreation1hTokens?: number;
  },
): {
  inputTokens?: number;
  outputTokens?: number;
  cachedInputTokens?: number;
  cacheCreationInputTokens?: number;
  cacheCreation5mTokens?: number;
  cacheCreation1hTokens?: number;
} {
  const sumOpt = (a?: number, b?: number): number | undefined => {
    if (a == null && b == null) return undefined;
    return (a ?? 0) + (b ?? 0);
  };
  const out: {
    inputTokens?: number;
    outputTokens?: number;
    cachedInputTokens?: number;
    cacheCreationInputTokens?: number;
    cacheCreation5mTokens?: number;
    cacheCreation1hTokens?: number;
  } = {};
  const input = sumOpt(prev.inputTokens, cur.inputTokens);
  if (input != null) out.inputTokens = input;
  const output = sumOpt(prev.outputTokens, cur.outputTokens);
  if (output != null) out.outputTokens = output;
  const cached = sumOpt(prev.cachedInputTokens, cur.cachedInputTokens);
  if (cached != null) out.cachedInputTokens = cached;
  const cacheCreation = sumOpt(prev.cacheCreationInputTokens, cur.cacheCreationInputTokens);
  if (cacheCreation != null) out.cacheCreationInputTokens = cacheCreation;
  const c5m = sumOpt(prev.cacheCreation5mTokens, cur.cacheCreation5mTokens);
  if (c5m != null) out.cacheCreation5mTokens = c5m;
  const c1h = sumOpt(prev.cacheCreation1hTokens, cur.cacheCreation1hTokens);
  if (c1h != null) out.cacheCreation1hTokens = c1h;
  return out;
}

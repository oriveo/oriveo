import { getProviderDisplayName } from '@oriveo/config';
import type { ChatMessage, Conversation, Provider, ProviderKind } from '@oriveo/shared';
import { COST_EPSILON } from '../../utils/format-utils';
import { normalizeUUID } from '../../utils/id-utils';
import {
  addNonUsdCostToTotals,
  hasNonUsdCostTotals,
  mergeNonUsdCostTotals,
  settleNonUsdCostTotals,
  type NonUsdCostTotals,
} from './cost-currency';

export type CostSummarySource = 'local_device';

export interface MonthlyCostProviderEntry {
  providerKind: ProviderKind;
  providerID: string;
  displayName: string;
  baseURLText?: string;
  relayKind?: Provider['relayKind'];
  modelHints?: string[];
  /** USD part. */
  cost: number;
  /** Non-USD part totalled per currency; comes only from local messages, omitted when absent. */
  nonUsdTotals?: NonUsdCostTotals;
}

export interface MonthlyCostSummary {
  /** USD total. */
  totalCost: number;
  /** Non-USD totals accumulated per currency, never added to totalCost; omitted when absent. */
  nonUsdTotals?: NonUsdCostTotals;
  providers: MonthlyCostProviderEntry[];
  hiddenProviderCount: number;
  isVisible: boolean;
  source: CostSummarySource;
}

interface ProviderIdentitySnapshot {
  kind: ProviderKind;
  customName?: string;
  baseURLText?: string | null;
  relayKind?: Provider['relayKind'];
  modelHints: string[];
}

function snapshotIdentities(providers: Provider[]): Map<string, ProviderIdentitySnapshot> {
  const snapshot = new Map<string, ProviderIdentitySnapshot>();
  for (const provider of providers) {
    snapshot.set(provider.id, {
      kind: provider.kind,
      customName: provider.customName,
      baseURLText: provider.baseURLText,
      relayKind: provider.relayKind,
      modelHints: [...provider.models, ...provider.catalogModels]
        .flatMap((model) => [model.groupKey, model.groupName, model.id, model.name])
        .filter((value): value is string => Boolean(value)),
    });
  }
  return snapshot;
}

function resolveDisplayName(
  providerKind: ProviderKind,
  providerID: string,
  identities: Map<string, ProviderIdentitySnapshot>,
): string {
  if (providerKind === 'relay') {
    const snapshot = identities.get(providerID);
    const trimmed = snapshot?.customName?.trim();
    if (trimmed) return trimmed;
    const host = parseBaseURLHost(snapshot?.baseURLText);
    if (host) return `${getProviderDisplayName('relay')} - ${host}`;
  }
  return getProviderDisplayName(providerKind);
}

function parseBaseURLHost(baseURL?: string | null): string | undefined {
  if (!baseURL) return undefined;
  try {
    return new URL(baseURL).host || undefined;
  } catch {
    return undefined;
  }
}

export function buildMonthlyCostSummary(
  conversations: Conversation[],
  providers: Provider[],
  now: Date = new Date(),
  visibleProviderLimit = 3,
): MonthlyCostSummary {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  const identities = snapshotIdentities(providers);
  const groupedCosts = new Map<string, MonthlyCostProviderEntry>();

  for (const conversation of conversations) {
    if (conversation.isDraft) continue;

    for (const message of conversation.messages) {
      if (message.role !== 'assistant') continue;
      if (message.state !== 'delivered') continue;
      const usdCost = usdCostOf(message);
      if (usdCost === null) continue;

      const occurredAt = resolveOccurredAt(message.createdAt, conversation.updatedAt);
      if (!occurredAt) continue;
      if (occurredAt < start || occurredAt >= end) continue;

      const providerID = message.providerID ?? conversation.providerID ?? '';
      const key = `${message.providerKind}\u0000${providerID}`;
      const previous = groupedCosts.get(key);
      const nonUsdTotals = addNonUsdCostToTotals(previous?.nonUsdTotals, message.nonUsdCost);
      groupedCosts.set(key, {
        providerKind: message.providerKind,
        providerID,
        displayName: previous?.displayName
          ?? resolveDisplayName(message.providerKind, providerID, identities),
        baseURLText: previous?.baseURLText ?? identities.get(providerID)?.baseURLText ?? undefined,
        relayKind: previous?.relayKind ?? identities.get(providerID)?.relayKind,
        modelHints: previous?.modelHints ?? identities.get(providerID)?.modelHints,
        cost: (previous?.cost ?? 0) + usdCost,
        ...(nonUsdTotals ? { nonUsdTotals } : {}),
      });
    }
  }

  // Messages are summed at face value; epsilon is applied only to each provider's total, and providers whose totals are not displayable are dropped.
  const sortedProviders = Array.from(groupedCosts.values())
    .map(settleProviderEntry)
    .filter((entry): entry is MonthlyCostProviderEntry => entry !== null)
    .sort(compareProviderEntries);

  const totalCost = sortedProviders.reduce((sum, item) => sum + item.cost, 0);
  // Each currency accumulates on its own, never across currencies.
  let nonUsdTotals: NonUsdCostTotals | undefined;
  for (const entry of sortedProviders) {
    nonUsdTotals = mergeNonUsdCostTotals(nonUsdTotals, entry.nonUsdTotals);
  }

  return {
    totalCost,
    ...(nonUsdTotals ? { nonUsdTotals } : {}),
    providers: sortedProviders.slice(0, visibleProviderLimit),
    hiddenProviderCount: Math.max(0, sortedProviders.length - visibleProviderLimit),
    isVisible: (totalCost > COST_EPSILON || hasNonUsdCostTotals(nonUsdTotals)) && sortedProviders.length > 0,
    source: 'local_device',
  };
}

/** Apply epsilon to a provider entry's totals: USD <= COST_EPSILON counts as 0, non-USD keeps only currencies > COST_EPSILON; null when neither part remains. */
function settleProviderEntry(entry: MonthlyCostProviderEntry): MonthlyCostProviderEntry | null {
  const cost = entry.cost > COST_EPSILON ? entry.cost : 0;
  const nonUsdTotals = settleNonUsdCostTotals(entry.nonUsdTotals);
  if (cost === 0 && !nonUsdTotals) return null;
  const settled: MonthlyCostProviderEntry = { ...entry, cost };
  if (nonUsdTotals) settled.nonUsdTotals = nonUsdTotals;
  else delete settled.nonUsdTotals;
  return settled;
}

/**
 * The USD part a message can contribute (face value, no per-message epsilon; epsilon applies only to totals);
 * null when neither the USD nor the non-USD part has a positive usable amount (not counted).
 */
function usdCostOf(message: ChatMessage): number | null {
  const usd = Number.isFinite(message.estimatedCost) && message.estimatedCost > 0 ? message.estimatedCost : 0;
  const part = message.nonUsdCost;
  const hasNonUsd = !!part && part.costSource !== 'unknown' && Number.isFinite(part.amount) && part.amount > 0;
  if (usd === 0 && !hasNonUsd) return null;
  return usd;
}

export function buildMonthlyCostByProvider(
  conversations: Conversation[],
  now: Date = new Date(),
): Map<string, number> {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  const costs = new Map<string, number>();
  forEachProviderMessageCost(conversations, start, end, (providerID, message) => {
    if (!Number.isFinite(message.estimatedCost) || message.estimatedCost <= 0) return;
    costs.set(providerID, (costs.get(providerID) ?? 0) + message.estimatedCost);
  });
  // Messages are summed at face value; epsilon applies only to each provider's total.
  for (const [providerID, cost] of costs) {
    if (cost <= COST_EPSILON) costs.delete(providerID);
  }
  return costs;
}

/**
 * Billed message: the USD or non-USD part has a recorded cost, with source upstream / localEstimate
 * and an amount > COST_EPSILON. Legacy messages without a USD costSource count as localEstimate; a message
 * with only a non-USD part has a top-level costSource of unknown, so nonUsdCost must be checked.
 * A mixed-currency message counts once.
 */
export function isBilledMessage(message: ChatMessage): boolean {
  const usdSource = message.costSource ?? 'localEstimate';
  const usdBilled = (usdSource === 'upstream' || usdSource === 'localEstimate')
    && Number.isFinite(message.estimatedCost)
    && message.estimatedCost > COST_EPSILON;
  if (usdBilled) return true;
  const nonUsd = message.nonUsdCost;
  return !!nonUsd
    && (nonUsd.costSource === 'upstream' || nonUsd.costSource === 'localEstimate')
    && Number.isFinite(nonUsd.amount)
    && nonUsd.amount > COST_EPSILON;
}

/**
 * Billed message count ({@link isBilledMessage}) per providerID (normalized with normalizeUUID) for the current month,
 * using the same traversal as {@link buildMonthlyCostByProvider}. Providers without billed messages do not appear.
 */
export function buildMonthlyBilledMessageCountByProvider(
  conversations: Conversation[],
  now: Date = new Date(),
): Map<string, number> {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  const counts = new Map<string, number>();
  forEachProviderMessageCost(conversations, start, end, (providerID, message) => {
    if (!isBilledMessage(message)) return;
    const key = normalizeUUID(providerID);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  });
  return counts;
}

/**
 * Non-USD totals per providerID for the current month, on the same basis as {@link buildMonthlyCostByProvider};
 * together they form "USD number + nonUsd map". Providers without a non-USD part do not appear.
 */
export function buildMonthlyNonUsdCostByProvider(
  conversations: Conversation[],
  now: Date = new Date(),
): Map<string, NonUsdCostTotals> {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  return buildNonUsdCostByProvider(conversations, start, end);
}

/**
 * Daily non-USD totals per providerID for the last 7 days (UTC calendar days, the last slot is today).
 */
export function buildDailyNonUsdCostsLast7DaysByProvider(
  conversations: Conversation[],
  now: Date = new Date(),
): Map<string, Array<NonUsdCostTotals | undefined>> {
  const result = new Map<string, Array<NonUsdCostTotals | undefined>>();
  const todayStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const dayMs = 86_400_000;
  for (let offset = 6; offset >= 0; offset -= 1) {
    const start = new Date(todayStart - offset * dayMs);
    const end = new Date(start.getTime() + dayMs);
    for (const [providerID, totals] of buildNonUsdCostByProvider(conversations, start, end)) {
      const buckets = result.get(providerID) ?? new Array<NonUsdCostTotals | undefined>(7).fill(undefined);
      buckets[6 - offset] = totals;
      result.set(providerID, buckets);
    }
  }
  return result;
}

function buildNonUsdCostByProvider(
  conversations: Conversation[],
  start: Date,
  end: Date,
): Map<string, NonUsdCostTotals> {
  const totals = new Map<string, NonUsdCostTotals>();
  forEachProviderMessageCost(conversations, start, end, (providerID, message) => {
    const next = addNonUsdCostToTotals(totals.get(providerID), message.nonUsdCost);
    if (next) totals.set(providerID, next);
  });
  // Messages are summed at face value; epsilon applies only to each provider's total within this range (month / day bucket).
  for (const [providerID, raw] of totals) {
    const settled = settleNonUsdCostTotals(raw);
    if (settled) totals.set(providerID, settled);
    else totals.delete(providerID);
  }
  return totals;
}

/** Visit delivered assistant messages in the range by providerID (message-level providerID first, legacy messages fall back to the conversation level; drafts are skipped). */
function forEachProviderMessageCost(
  conversations: Conversation[],
  start: Date,
  end: Date,
  visit: (providerID: string, message: ChatMessage) => void,
): void {
  for (const conversation of conversations) {
    if (conversation.isDraft) continue;

    for (const message of conversation.messages) {
      if (message.role !== 'assistant') continue;
      if (message.state !== 'delivered') continue;

      const occurredAt = resolveOccurredAt(message.createdAt, conversation.updatedAt);
      if (!occurredAt || occurredAt < start || occurredAt >= end) continue;

      const providerID = message.providerID ?? conversation.providerID;
      if (!providerID) continue;
      visit(providerID, message);
    }
  }
}

function resolveOccurredAt(messageCreatedAt?: string, conversationUpdatedAt?: string): Date | null {
  const candidate = messageCreatedAt ?? conversationUpdatedAt;
  if (!candidate) return null;

  const date = new Date(candidate);
  return Number.isNaN(date.getTime()) ? null : date;
}

function compareProviderEntries(left: MonthlyCostProviderEntry, right: MonthlyCostProviderEntry): number {
  if (left.cost !== right.cost) return right.cost - left.cost;
  return left.displayName.localeCompare(right.displayName);
}

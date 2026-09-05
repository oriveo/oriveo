import { getProviderDisplayName } from '@oriveo/config';
import type { Conversation, Provider, ProviderKind } from '@oriveo/shared';
import { COST_EPSILON } from '../../utils/format-utils';

export type CostSummarySource = 'local_device';

export interface MonthlyCostProviderEntry {
  providerKind: ProviderKind;
  providerID: string;
  displayName: string;
  baseURLText?: string;
  relayKind?: Provider['relayKind'];
  modelHints?: string[];
  cost: number;
}

export interface MonthlyCostSummary {
  totalCost: number;
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
      if (!Number.isFinite(message.estimatedCost) || message.estimatedCost <= COST_EPSILON) continue;

      const occurredAt = resolveOccurredAt(message.createdAt, conversation.updatedAt);
      if (!occurredAt) continue;
      if (occurredAt < start || occurredAt >= end) continue;

      const providerID = message.providerID ?? conversation.providerID ?? '';
      const key = `${message.providerKind}\u0000${providerID}`;
      const previous = groupedCosts.get(key);
      groupedCosts.set(key, {
        providerKind: message.providerKind,
        providerID,
        displayName: previous?.displayName
          ?? resolveDisplayName(message.providerKind, providerID, identities),
        baseURLText: previous?.baseURLText ?? identities.get(providerID)?.baseURLText ?? undefined,
        relayKind: previous?.relayKind ?? identities.get(providerID)?.relayKind,
        modelHints: previous?.modelHints ?? identities.get(providerID)?.modelHints,
        cost: (previous?.cost ?? 0) + message.estimatedCost,
      });
    }
  }

  const sortedProviders = Array.from(groupedCosts.values())
    .sort(compareProviderEntries);

  const totalCost = sortedProviders.reduce((sum, item) => sum + item.cost, 0);

  return {
    totalCost,
    providers: sortedProviders.slice(0, visibleProviderLimit),
    hiddenProviderCount: Math.max(0, sortedProviders.length - visibleProviderLimit),
    isVisible: totalCost > COST_EPSILON && sortedProviders.length > 0,
    source: 'local_device',
  };
}

export function buildMonthlyCostByProvider(
  conversations: Conversation[],
  now: Date = new Date(),
): Map<string, number> {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  const costs = new Map<string, number>();

  for (const conversation of conversations) {
    if (conversation.isDraft) continue;

    for (const message of conversation.messages) {
      if (message.role !== 'assistant') continue;
      if (message.state !== 'delivered') continue;
      if (!Number.isFinite(message.estimatedCost) || message.estimatedCost <= COST_EPSILON) continue;

      const occurredAt = resolveOccurredAt(message.createdAt, conversation.updatedAt);
      if (!occurredAt || occurredAt < start || occurredAt >= end) continue;

      const providerID = message.providerID ?? conversation.providerID;
      if (!providerID) continue;
      costs.set(providerID, (costs.get(providerID) ?? 0) + message.estimatedCost);
    }
  }

  return costs;
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

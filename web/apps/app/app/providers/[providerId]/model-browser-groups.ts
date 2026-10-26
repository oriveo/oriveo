import type { AIModel, Provider, ProviderKind } from "@oriveo/shared";
import { relayCatalogGroups } from "@oriveo/shared/relay/relay-catalog-grouping";
import { deduplicateByCanonical, deduplicateModels } from "../../../lib/core/providers/catalog-model";
import { relayBindingFamily } from "../../../lib/core/provider-model-ops";
import {
  modelSupportsCapabilityFilter,
  type ModelCapabilityPresentationProjector,
} from "../../../lib/core/chat/model-capability-presentation";

export type ModelBrowserSort = "recommended" | "name" | "price" | "context";

export interface ModelBrowserGroup {
  id: string;
  title: string;
  models: AIModel[];
}

interface BuildModelBrowserGroupsOptions {
  catalogModels: AIModel[];
  popularitySourceModels?: AIModel[];
  query: string;
  capFilter: string | null;
  sortBy: ModelBrowserSort;
  providerKind: ProviderKind;
  providerLabel: string;
  provider?: Provider;
  capabilityProjector?: ModelCapabilityPresentationProjector;
  preserveCatalogOrder?: boolean;
  /** Localized title of the relay "Other" group (models with an unknown family land here). */
  otherGroupTitle?: string;
  /**
   * Skip canonical deduplication: step 2 of adding models matches by literal ID,
   * so a date snapshot typed in by the user must not be folded away by the group projection.
   */
  literalIDs?: boolean;
}

export function buildModelBrowserGroups({
  catalogModels,
  popularitySourceModels,
  query,
  capFilter,
  sortBy,
  providerKind,
  providerLabel,
  provider,
  capabilityProjector,
  preserveCatalogOrder = false,
  otherGroupTitle,
  literalIDs = false,
}: BuildModelBrowserGroupsOptions): ModelBrowserGroup[] {
  const normalizedQuery = query.trim().toLowerCase();
  // Presentation-level deduplication as a safety net against duplicates in older persisted data or missed by sync
  const dedupedModels = literalIDs ? catalogModels : deduplicateModels(catalogModels, providerKind);
  if (providerKind === "relay") {
    return buildRelayModelBrowserGroups({
      models: dedupedModels,
      normalizedQuery,
      capFilter,
      sortBy,
      provider,
      capabilityProjector,
      preserveCatalogOrder,
      otherGroupTitle: otherGroupTitle ?? providerLabel,
    });
  }
  const groupPopularity = buildGroupPopularityIndex({
    models: deduplicateByCanonical(popularitySourceModels ?? catalogModels),
    providerKind,
    providerLabel,
    provider,
    capabilityProjector,
  });
  const groups = new Map<string, AIModel[]>();
  for (const model of dedupedModels) {
    if (capFilter && (!provider || !modelSupportsCapabilityFilter(
      provider,
      model,
      capFilter,
      capabilityProjector?.(provider, model),
    ))) {
      continue;
    }
    const groupIdentity = resolveGroupIdentity(
      model,
      providerKind,
      providerLabel,
    );
    const groupId = groupIdentity.id;
    const currentModels = groups.get(groupId) ?? [];
    currentModels.push(model);
    groups.set(groupId, currentModels);
  }

  return [...groups.entries()]
    .map(([id, models]) => {
      const title = resolveGroupIdentity(
        models[0],
        providerKind,
        providerLabel,
      ).title;
      const filteredModels = normalizedQuery
        ? filterModelsWithinGroup(models, normalizedQuery, title, id)
        : models;

      return {
        id,
        title,
        models:
          preserveCatalogOrder && sortBy === "recommended"
            ? [...filteredModels]
            : [...filteredModels].sort((lhs, rhs) =>
                compareModels(lhs, rhs, sortBy, providerKind, provider, capabilityProjector),
              ),
      };
    })
    .filter((group) => group.models.length > 0)
    .sort((lhs, rhs) =>
      preserveCatalogOrder
        ? 0
        : compareGroups(lhs, rhs, providerKind, groupPopularity, provider, capabilityProjector),
    );
}

/**
 * Relay (including local-machine connections): grouping uses the pure function shared by all three clients
 * (family = cached by-model family, then heuristics). Groups keep the order of first appearance in the catalog
 * with "Other" last, instead of being ordered by metadata groupKey or popularity; sorting and search within a group are unchanged.
 */
function buildRelayModelBrowserGroups(input: {
  models: AIModel[];
  normalizedQuery: string;
  capFilter: string | null;
  sortBy: ModelBrowserSort;
  provider?: Provider;
  capabilityProjector?: ModelCapabilityPresentationProjector;
  preserveCatalogOrder: boolean;
  otherGroupTitle: string;
}): ModelBrowserGroup[] {
  const { capFilter, provider, capabilityProjector, normalizedQuery, sortBy } = input;
  const filtered = input.models.filter((model) => !capFilter || (provider && modelSupportsCapabilityFilter(
    provider,
    model,
    capFilter,
    capabilityProjector?.(provider, model),
  )));
  return relayCatalogGroups(filtered, relayBindingFamily)
    .map((group) => {
      const title = group.label ?? input.otherGroupTitle;
      const models = normalizedQuery
        ? filterModelsWithinGroup(group.models, normalizedQuery, title, group.id)
        : group.models;
      return {
        id: group.id,
        title,
        models: input.preserveCatalogOrder && sortBy === "recommended"
          ? [...models]
          : [...models].sort((lhs, rhs) => compareModels(lhs, rhs, sortBy, "relay", provider, capabilityProjector)),
      };
    })
    .filter((group) => group.models.length > 0);
}

export function shouldRenderGroupedModelBrowser(
  _providerKind: ProviderKind,
  groups: ModelBrowserGroup[],
): boolean {
  // Presentation contract: whether groups are shown depends only on metadata (the number of
  // groups), never on a hardcoded provider.kind.
  return groups.length > 1;
}

export function sortEnabledModels(models: AIModel[], provider?: Provider): AIModel[] {
  return [...models].sort((lhs, rhs) => compareEnabledModels(lhs, rhs, provider));
}

function resolveGroupIdentity(
  model: AIModel | undefined,
  providerKind: ProviderKind,
  providerLabel: string,
): { id: string; title: string } {
  if (!model) {
    return { id: providerKind, title: providerLabel };
  }

  // Hard rule: the vendor or group of an aggregating provider may only come from the backend
  // metadata `uiHints.groupKey/groupName`. Parsing the vendor out of a model id slug is not
  // allowed.
  return {
    id: model.groupKey ?? providerKind,
    title: model.groupName ?? providerLabel,
  };
}

function compareGroups(
  lhs: ModelBrowserGroup,
  rhs: ModelBrowserGroup,
  _providerKind: ProviderKind,
  popularityByGroupId: Map<string, number>,
  provider?: Provider,
  capabilityProjector?: ModelCapabilityPresentationProjector,
): number {
  // Presentation contract: group ordering depends only on metadata (the uiHints.rank of the
  // models in the group plus capability weights), never on a vendor allow list keyed on
  // provider.kind.
  const lhsScore = popularityByGroupId.get(lhs.id)
    ?? catalogGroupSortKey(lhs, provider, capabilityProjector);
  const rhsScore = popularityByGroupId.get(rhs.id)
    ?? catalogGroupSortKey(rhs, provider, capabilityProjector);
  const scoreDiff = rhsScore - lhsScore;
  if (scoreDiff !== 0) {
    return scoreDiff;
  }

  return lhs.title.localeCompare(rhs.title, undefined, {
    numeric: true,
    sensitivity: "base",
  });
}

function buildGroupPopularityIndex({
  models,
  providerKind,
  providerLabel,
  provider,
  capabilityProjector,
}: {
  models: AIModel[];
  providerKind: ProviderKind;
  providerLabel: string;
  provider?: Provider;
  capabilityProjector?: ModelCapabilityPresentationProjector;
}): Map<string, number> {
  const groupedModels = new Map<string, AIModel[]>();
  for (const model of models) {
    const groupIdentity = resolveGroupIdentity(
      model,
      providerKind,
      providerLabel,
    );
    const currentModels = groupedModels.get(groupIdentity.id) ?? [];
    currentModels.push(model);
    groupedModels.set(groupIdentity.id, currentModels);
  }

  return new Map(
    [...groupedModels.entries()].map(([groupId, groupModels]) => [
      groupId,
      groupPopularityScore(groupModels, provider, capabilityProjector),
    ]),
  );
}

function catalogGroupSortKey(
  group: ModelBrowserGroup,
  provider?: Provider,
  capabilityProjector?: ModelCapabilityPresentationProjector,
): number {
  return groupPopularityScore(group.models, provider, capabilityProjector);
}

function groupPopularityScore(
  models: AIModel[],
  provider?: Provider,
  capabilityProjector?: ModelCapabilityPresentationProjector,
): number {
  const [first = 0, second = 0, third = 0] = models
    .map((model) => catalogPriorityScore(model, provider, capabilityProjector))
    .sort((left, right) => right - left);

  return first * 10_000 + second * 100 + third;
}

function compareModels(
  lhs: AIModel,
  rhs: AIModel,
  sortBy: ModelBrowserSort,
  _providerKind: ProviderKind,
  provider?: Provider,
  capabilityProjector?: ModelCapabilityPresentationProjector,
): number {
  if (lhs.isAvailable !== rhs.isAvailable) {
    return lhs.isAvailable ? -1 : 1;
  }

  // The user's chosen ordering wins
  if (sortBy === "price") {
    const priceDiff = normalizedPrice(lhs) - normalizedPrice(rhs);
    if (priceDiff !== 0) {
      return priceDiff;
    }
  }

  if (sortBy === "context") {
    const contextDiff = (rhs.contextLength ?? 0) - (lhs.contextLength ?? 0);
    if (contextDiff !== 0) {
      return contextDiff;
    }
  }

  if (sortBy === "name") {
    const nameDiff = lhs.name.localeCompare(rhs.name, undefined, {
      numeric: true,
      sensitivity: "base",
    });
    if (nameDiff !== 0) {
      return nameDiff;
    }
  }

  // recommended, or the fallback: priority, then recency, then name
  const priorityDiff = catalogPriorityScore(rhs, provider, capabilityProjector)
    - catalogPriorityScore(lhs, provider, capabilityProjector);
  if (priorityDiff !== 0) {
    return priorityDiff;
  }

  const createdAtDiff = (rhs.createdAt ?? 0) - (lhs.createdAt ?? 0);
  if (createdAtDiff !== 0) {
    return createdAtDiff;
  }

  return lhs.name.localeCompare(rhs.name, undefined, {
    numeric: true,
    sensitivity: "base",
  });
}

function compareEnabledModels(lhs: AIModel, rhs: AIModel, provider?: Provider): number {
  // Relay has no default model: the legacy isDefault flag is not moved to the front.
  if (provider?.kind !== 'relay' && lhs.isDefault !== rhs.isDefault) {
    return lhs.isDefault ? -1 : 1;
  }

  if (lhs.isAvailable !== rhs.isAvailable) {
    return lhs.isAvailable ? -1 : 1;
  }

  const rankDiff = (rhs.sortRank ?? 0) - (lhs.sortRank ?? 0);
  if (rankDiff !== 0) {
    return rankDiff;
  }

  const priorityDiff = catalogPriorityScore(rhs, provider) - catalogPriorityScore(lhs, provider);
  if (priorityDiff !== 0) {
    return priorityDiff;
  }

  const createdAtDiff = (rhs.createdAt ?? 0) - (lhs.createdAt ?? 0);
  if (createdAtDiff !== 0) {
    return createdAtDiff;
  }

  return lhs.name.localeCompare(rhs.name, undefined, {
    numeric: true,
    sensitivity: 'base',
  });
}

function catalogPriorityScore(
  model: AIModel,
  provider?: Provider,
  capabilityProjector?: ModelCapabilityPresentationProjector,
): number {
  if (model.sortRank != null) {
    return model.sortRank;
  }

  let score = 0;
  const capabilityPresentation = provider ? capabilityProjector?.(provider, model) : undefined;

  if (model.isAvailable) {
    score += 180;
  }

  if (provider && modelSupportsCapabilityFilter(provider, model, "reasoning", capabilityPresentation)) {
    score += 28;
  }

  if (provider && modelSupportsCapabilityFilter(provider, model, "image", capabilityPresentation)) {
    score += 18;
  }

  if (provider && modelSupportsCapabilityFilter(provider, model, "file", capabilityPresentation)) {
    score += 12;
  }

  if (provider && modelSupportsCapabilityFilter(provider, model, "web", capabilityPresentation)) {
    score += 8;
  }

  if (model.promptPrice === 0 || model.completionPrice === 0) {
    score += 4;
  }

  return score + recencyScore(model.createdAt);
}

function normalizedPrice(model: AIModel): number {
  return (model.promptPrice ?? 0) + (model.completionPrice ?? 0);
}

function recencyScore(createdAt: number | undefined): number {
  if (!createdAt || createdAt <= 0) {
    return 0;
  }

  const ageSeconds = Math.max(0, Date.now() / 1000 - createdAt);
  const day = 24 * 60 * 60;

  if (ageSeconds < 30 * day) return 24;
  if (ageSeconds < 90 * day) return 16;
  if (ageSeconds < 180 * day) return 8;
  if (ageSeconds < 365 * day) return 3;
  return 0;
}

function filterModelsWithinGroup(
  models: AIModel[],
  normalizedQuery: string,
  title: string,
  groupId: string,
): AIModel[] {
  const groupMatches =
    title.toLowerCase().includes(normalizedQuery) ||
    groupId.toLowerCase().includes(normalizedQuery);

  if (groupMatches) {
    return models;
  }

  return models.filter(
    (model) =>
      model.name.toLowerCase().includes(normalizedQuery) ||
      model.id.toLowerCase().includes(normalizedQuery) ||
      model.summary?.toLowerCase().includes(normalizedQuery),
  );
}

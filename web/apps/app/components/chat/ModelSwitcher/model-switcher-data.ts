import type { AIModel, Provider, ProviderKind } from "@oriveo/shared";
import { usesServerOrderedModels } from "@oriveo/shared";
import { selectResolvedCatalog } from "../../../lib/core/store/selectors";
import type { FilterKey } from "./presentation-mode";
import { modelSupportsCapabilityFilter } from "../../../lib/core/chat/model-capability-presentation";
import { modelSupportsGenerationParameter } from "../../../lib/core/chat/stream-options";
import type { ModelCapabilityPresentationProjector } from "../../../lib/core/chat/model-capability-presentation";

export function modelMatchesQuery(model: AIModel, query: string): boolean {
  if (!query) return true;
  return (
    model.name.toLowerCase().includes(query) ||
    model.id.toLowerCase().includes(query) ||
    model.summary?.toLowerCase().includes(query) === true
  );
}

/**
 * Strip vendor prefixes ("NVIDIA: " / "OpenAI: ") and the "(free)" suffix so a model row shows the
 * plain model name. The vendor is shown separately on the second meta line and the price goes through the priceTier badge, which avoids repeating both.
 */
export function cleanModelName(name: string): string {
  let cleaned = name;
  // Strip the "Vendor: " prefix, matching only when a single word precedes the colon so real names containing a colon survive
  const prefixMatch = cleaned.match(/^([^:]{1,32}):\s+(.+)$/);
  if (prefixMatch) {
    cleaned = prefixMatch[2];
  }
  // Strip the trailing "(free)" or " free"
  cleaned = cleaned.replace(/\s*\(free\)\s*$/i, "").trim();
  return cleaned || name;
}

/**
 * Extract the vendor prefix from a model name ("NVIDIA: gpt..." -> "NVIDIA"). undefined means the
 * name carries no recognizable vendor prefix and the caller should fall back to the provider label.
 */
export function extractVendorFromName(name: string): string | undefined {
  const match = name.match(/^([^:]{1,32}):\s+/);
  return match ? match[1].trim() : undefined;
}

export function isFreeModel(model: AIModel): boolean {
  const tier = model.priceTier?.toLowerCase().trim();
  if (tier === "free" || tier === " " || tier === "0") return true;
  if (model.promptPrice === 0 && model.completionPrice === 0) return true;
  return false;
}

export function modelMatchesFilters(
  provider: Provider,
  model: AIModel,
  filters: Set<FilterKey>,
  capabilityProjector?: ModelCapabilityPresentationProjector,
  /**
     * Entering from the primary action of a not-adjustable row lists only the models that can really
     * adjust this generation parameter. It is the same layer of filtering as the capability chips
     * above (both only consume existing decision functions), so it lives in the same predicate; the rule itself is in `modelSupportsGenerationParameter` and is not duplicated here.
   */
  requiredGenerationParameterId?: string,
): boolean {
  if (
    requiredGenerationParameterId
    && !modelSupportsGenerationParameter(provider, model, requiredGenerationParameterId)
  ) return false;
  if (filters.size === 0) return true;
  for (const filter of filters) {
    if (filter === "free") {
      if (!isFreeModel(model)) return false;
      continue;
    }
    if (filter === "recommended") {
      if (!model.isRecommended) return false;
      continue;
    }
    // Capability filters only consume the facade projection. A relay list with no actual stream
    // context fails closed rather than passing a requested transport off as a verified capability.
    if (!modelSupportsCapabilityFilter(
      provider,
      model,
      filter,
      capabilityProjector?.(provider, model),
    )) return false;
  }
  return true;
}

/**
 * Compact context length display: 32K / 128K / 1M.
 * Truncated to one decimal with trailing zeros dropped.
 */
export function formatContextLength(tokens: number | undefined): string | undefined {
  if (!tokens || tokens <= 0) return undefined;
  if (tokens >= 1_000_000) {
    const mil = tokens / 1_000_000;
    const num = mil >= 10 ? Math.round(mil).toString() : mil.toFixed(1).replace(/\.0$/, "");
    return `${num}M`;
  }
  if (tokens >= 1000) {
    const k = Math.round(tokens / 1000);
    return `${k}K`;
  }
  return `${tokens}`;
}

export function supportsAddModels(provider: Provider | undefined): boolean {
  if (!provider) return false;
  if (provider.kind === "relay") return true;
  // Official providers: use the resolved catalog to tell whether there are unenabled models to add
  const resolved = selectResolvedCatalog(provider);
  return resolved.catalog.some((m) => !m.isEnabled);
}

export function sortProviderModels(
  models: AIModel[],
  providerKind?: ProviderKind,
): AIModel[] {
  // The order for managed and free providers comes from the server (group.sort_order ->
  // model.sort_order). Reordering locally by isRecommended or by name would scramble the vendor
  // grouping (ProviderSectionRow builds groups in order of first appearance) and would make a group.sort_order change in the admin console wait for a release to take effect.
  if (providerKind && usesServerOrderedModels(providerKind)) return [...models];

  return [...models].sort((lhs, rhs) => {
    if (lhs.isDefault !== rhs.isDefault) {
      return lhs.isDefault ? -1 : 1;
    }
    // After the default, sort by recommended and then by name so recommended models stay visible near the top
    const lhsRec = lhs.isRecommended ? 1 : 0;
    const rhsRec = rhs.isRecommended ? 1 : 0;
    if (lhsRec !== rhsRec) return rhsRec - lhsRec;

    return lhs.name.localeCompare(rhs.name, undefined, {
      numeric: true,
      sensitivity: "base",
    });
  });
}

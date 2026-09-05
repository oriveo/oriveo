import type { Provider } from "@oriveo/shared";
import { sameNormalizedID } from "../../lib/utils/id-utils";
import { getProviderInstanceDisplayName } from "../../lib/core/providers/provider-display";

export function getModelSwitcherProviderLabel(provider: Provider): string {
  return getProviderInstanceDisplayName(provider);
}

export function sortModelSwitcherProviders(
  providers: Provider[],
  selectedProviderId?: string,
): Provider[] {
  return [...providers].sort((lhs, rhs) => {
    const lhsSelected = sameNormalizedID(lhs.id, selectedProviderId);
    const rhsSelected = sameNormalizedID(rhs.id, selectedProviderId);
    if (lhsSelected !== rhsSelected) return lhsSelected ? -1 : 1;

    return getModelSwitcherProviderLabel(lhs).localeCompare(
      getModelSwitcherProviderLabel(rhs),
      undefined,
      { numeric: true, sensitivity: "base" },
    );
  });
}

export function getDefaultExpandedModelSwitcherProviderIds(
  providers: Provider[],
  selectedProviderId?: string,
): Set<string> {
  if (selectedProviderId) {
    const matched = providers.find((provider) =>
      sameNormalizedID(provider.id, selectedProviderId),
    );
    if (matched) return new Set([matched.id]);
  }
  const firstProvider = providers[0];
  return new Set(firstProvider ? [firstProvider.id] : []);
}

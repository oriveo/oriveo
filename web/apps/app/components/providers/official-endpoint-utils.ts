import type { PublicProviderConfig, ProviderRegionOption } from '../../lib/core/metadata/metadata-client';
import { resolveTrustedHosts, trustedHostMatch } from '@oriveo/core/providers/transport/endpoint-resolver';
import {
  FALLBACK_MOONSHOT_REGIONS,
  FALLBACK_MINIMAX_REGIONS,
  FALLBACK_QWEN_REGIONS,
  FALLBACK_SILICONFLOW_REGIONS,
} from '../../app/providers/new/provider-config-catalog';

// Offline fallback table used when the delivered one is missing (data only, no longer the criterion for "which vendors have regions"): whether to show regions depends only on whether that vendor's
// metadata has regionOptions.
const FALLBACK_OPTIONS: Partial<Record<string, ProviderRegionOption[]>> = {
  miniMax: FALLBACK_MINIMAX_REGIONS,
  qwen: FALLBACK_QWEN_REGIONS,
  moonshot: FALLBACK_MOONSHOT_REGIONS,
  siliconFlow: FALLBACK_SILICONFLOW_REGIONS,
};

export function resolveOfficialEndpointOptions(
  kind: string,
  providerConfig?: PublicProviderConfig | null,
): ProviderRegionOption[] {
  const configuredOptions = normalizeRegionOptions(providerConfig?.regionOptions);
  if (configuredOptions.length > 0) {
    return configuredOptions;
  }

  // The hard-coded fallback options also go through the trusted table (same matching function as the decoding layer): when the delivered table is missing / empty, only the last two segments of
  // that vendor's built-in fallback host are trusted, so the fallback cannot become a way around the trusted table.
  const fallback = FALLBACK_OPTIONS[kind];
  const trustedHosts = fallback ? resolveTrustedHosts(kind, providerConfig?.trustedHosts) : undefined;
  return fallback && trustedHosts
    ? fallback.filter((option) => trustedHostMatch(option.baseURL, trustedHosts))
    : [];
}

/**
 * Table for reverse lookup of regions: bypasses the trusted table, textually identical to before (the delivered table as is, otherwise the hard-coded fallback table).
 * Used only to recognize which region a user-saved address belongs to; options always use `resolveOfficialEndpointOptions`.
 */
export function resolveOfficialEndpointLookupOptions(
  kind: string,
  providerConfig?: PublicProviderConfig | null,
): ProviderRegionOption[] {
  const raw = providerConfig?.unfilteredRegionOptions !== undefined
    ? providerConfig.unfilteredRegionOptions
    : providerConfig?.regionOptions;
  const configuredOptions = normalizeRegionOptions(raw);
  return configuredOptions.length > 0 ? configuredOptions : FALLBACK_OPTIONS[kind] ?? [];
}

/**
 * The trusted table only constrains the options, not the value the user already saved: when a saved address is not among the options but can be found by reverse lookup in the
 * unfiltered table, it is appended to the list as the current value and the address is kept verbatim - saving without changes leaves it identical,
 * and it is not mistaken for the default region.
 */
export function withStoredOfficialEndpointOption(
  options: ProviderRegionOption[],
  lookupOptions: ProviderRegionOption[],
  storedURL?: string,
): ProviderRegionOption[] {
  const target = normalizeEndpointURL(storedURL);
  if (!target || !storedURL) return options;
  if (options.some((option) => normalizeEndpointURL(option.baseURL) === target)) return options;
  const stored = lookupOptions.find((option) => normalizeEndpointURL(option.baseURL) === target);
  if (!stored || options.some((option) => option.id === stored.id)) return options;
  return [...options, { ...stored, baseURL: storedURL }];
}

/**
 * Region echo on the detail page: a `region:<id>` source whose item is in the displayed (trusted) catalog takes priority - even if metadata moved
 * the address and the literal no longer matches, it is still recognized; otherwise match by literal address, falling back to the first item when nothing matches.
 */
export function resolveSelectedOfficialEndpointId(
  options: ProviderRegionOption[],
  currentURL?: string,
  fallbackURL?: string,
  endpointSource?: string,
): string {
  if (options.length === 0) {
    return '';
  }

  const sourceRegionId = endpointSource?.startsWith('region:') ? endpointSource.slice('region:'.length) : null;
  if (sourceRegionId && options.some((option) => option.id === sourceRegionId)) {
    return sourceRegionId;
  }

  const targetURL = normalizeEndpointURL(currentURL) ?? normalizeEndpointURL(fallbackURL);
  const matched = targetURL
    ? options.find((option) => normalizeEndpointURL(option.baseURL) === targetURL)
    : null;

  return matched?.id ?? options[0]?.id ?? '';
}

export function getOfficialEndpointOptionTranslationKey(
  kind: string,
  optionId: string,
): string | null {
  switch (kind) {
    case 'miniMax':
      if (optionId === 'global' || optionId === 'cn') {
        return `endpointOptions.miniMax.${optionId}`;
      }
      return null;
    case 'qwen':
      if (optionId === 'sg' || optionId === 'bj' || optionId === 'hk' || optionId === 'us') {
        return `endpointOptions.qwen.${optionId}`;
      }
      return null;
    case 'moonshot':
      if (optionId === 'intl' || optionId === 'cn') {
        return `endpointOptions.moonshot.${optionId}`;
      }
      return null;
    case 'siliconFlow':
      if (optionId === 'cn' || optionId === 'intl') {
        return `endpointOptions.siliconFlow.${optionId}`;
      }
      return null;
    default:
      return null;
  }
}

/** Returns null for vendors with no dedicated note copy (the region picker is shown as usual, just without a note). */
export function getOfficialEndpointDescriptionTranslationKey(
  kind: string,
): string | null {
  if (kind === 'miniMax') return 'officialEndpointDescriptionMiniMax';
  if (kind === 'moonshot') return 'officialEndpointDescriptionMoonshot';
  if (kind === 'siliconFlow') return 'officialEndpointDescriptionSiliconFlow';
  if (kind === 'qwen') return 'officialEndpointDescriptionQwen';
  return null;
}

function normalizeRegionOptions(
  regionOptions?: PublicProviderConfig['regionOptions'],
): ProviderRegionOption[] {
  if (!Array.isArray(regionOptions)) {
    return [];
  }

  return regionOptions
    .filter(
      (option): option is ProviderRegionOption =>
        Boolean(option)
        && typeof option.id === 'string'
        && option.id.trim().length > 0
        && typeof option.label === 'string'
        && option.label.trim().length > 0
        && typeof option.baseURL === 'string'
        && option.baseURL.trim().length > 0,
    )
    .map((option) => ({
      id: option.id.trim(),
      label: option.label.trim(),
      baseURL: option.baseURL.trim(),
      privacyPolicyURL: option.privacyPolicyURL?.trim(),
      apiKeyHelpURL: option.apiKeyHelpURL?.trim(),
    }));
}

function normalizeEndpointURL(url?: string): string | null {
  const trimmed = url?.trim();
  if (!trimmed) {
    return null;
  }

  // Older saved qwen region bases carry a /compatible-mode/v1 suffix while the region base is now the
  // native origin, so strip the suffix before matching or the region picker mismatches onto the first entry.
  return trimmed.replace(/\/+$/, '').replace(/\/compatible-mode\/v1$/, '');
}

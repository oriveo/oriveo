import type { PublicProviderConfig, ProviderRegionOption } from '../../lib/core/metadata/metadata-client';
import {
  FALLBACK_MOONSHOT_REGIONS,
  FALLBACK_MINIMAX_REGIONS,
  FALLBACK_QWEN_REGIONS,
  FALLBACK_SILICONFLOW_REGIONS,
} from '../../app/providers/new/provider-config-catalog';

export type OfficialEndpointProviderKind = 'miniMax' | 'qwen' | 'moonshot' | 'siliconFlow';

const FALLBACK_OPTIONS: Record<OfficialEndpointProviderKind, ProviderRegionOption[]> = {
  miniMax: FALLBACK_MINIMAX_REGIONS,
  qwen: FALLBACK_QWEN_REGIONS,
  moonshot: FALLBACK_MOONSHOT_REGIONS,
  siliconFlow: FALLBACK_SILICONFLOW_REGIONS,
};

export function isOfficialEndpointProvider(kind: string): kind is OfficialEndpointProviderKind {
  return kind === 'miniMax' || kind === 'qwen' || kind === 'moonshot' || kind === 'siliconFlow';
}

export function resolveOfficialEndpointOptions(
  kind: string,
  providerConfig?: PublicProviderConfig | null,
): ProviderRegionOption[] {
  if (!isOfficialEndpointProvider(kind)) {
    return [];
  }

  const configuredOptions = normalizeRegionOptions(providerConfig?.regionOptions);
  if (configuredOptions.length > 0) {
    return configuredOptions;
  }

  return FALLBACK_OPTIONS[kind];
}

export function resolveSelectedOfficialEndpointId(
  options: ProviderRegionOption[],
  currentURL?: string,
  fallbackURL?: string,
): string {
  if (options.length === 0) {
    return '';
  }

  const targetURL = normalizeEndpointURL(currentURL) ?? normalizeEndpointURL(fallbackURL);
  const matched = targetURL
    ? options.find((option) => normalizeEndpointURL(option.baseURL) === targetURL)
    : null;

  return matched?.id ?? options[0]?.id ?? '';
}

export function getOfficialEndpointOptionTranslationKey(
  kind: OfficialEndpointProviderKind,
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

export function getOfficialEndpointDescriptionTranslationKey(
  kind: OfficialEndpointProviderKind,
): string {
  if (kind === 'miniMax') return 'officialEndpointDescriptionMiniMax';
  if (kind === 'moonshot') return 'officialEndpointDescriptionMoonshot';
  if (kind === 'siliconFlow') return 'officialEndpointDescriptionSiliconFlow';
  return 'officialEndpointDescriptionQwen';
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

import {
  getProviderDisplayName,
  providerDefaults,
  type ConfiguredProviderKind,
  type ProviderDefault,
} from "@oriveo/config";

import type {
  ProviderRegionOption,
  PublicProviderConfig,
} from "../../../lib/core/metadata/metadata-client";

export interface ProviderSetupDefaults extends ProviderDefault {
  autoFillNote?: string | null;
}

export interface ProviderSetupCatalog {
  providers: Array<{
    kind: ConfiguredProviderKind;
    displayName: string;
    category: ProviderSetupProviderConfig["category"];
  }>;
  defaultsByKind: Record<ConfiguredProviderKind, ProviderSetupDefaults>;
  configsByKind: Record<ConfiguredProviderKind, ProviderSetupProviderConfig>;
  qwenRegions: ProviderRegionOption[];
  defaultKind: ConfiguredProviderKind;
}

type KnownPublicProviderConfig = PublicProviderConfig & {
  kind: ConfiguredProviderKind;
};

export interface ProviderSetupProviderConfig {
  category: "direct" | "aggregator";
  regionOptions: ProviderRegionOption[];
}

const FALLBACK_PROVIDER_ORDER: ConfiguredProviderKind[] = [
  "openAI",
  "anthropic",
  "gemini",
  "openRouter",
  "deepseek",
  "grok",
  "siliconFlow",
  "groq",
  "togetherAI",
  "fireworksAI",
  "miniMax",
  "zhipu",
  "qwen",
  "moonshot",
  "mistral",
];

const KNOWN_PROVIDER_KINDS = new Set<ConfiguredProviderKind>(
  FALLBACK_PROVIDER_ORDER,
);

const DEFAULT_KIND: ConfiguredProviderKind = "openRouter";

const FALLBACK_PROVIDER_CATEGORIES: Record<
  ConfiguredProviderKind,
  ProviderSetupProviderConfig["category"]
> = {
  openAI: "direct",
  anthropic: "direct",
  gemini: "direct",
  openRouter: "aggregator",
  deepseek: "direct",
  grok: "direct",
  siliconFlow: "aggregator",
  groq: "aggregator",
  togetherAI: "aggregator",
  fireworksAI: "aggregator",
  miniMax: "direct",
  zhipu: "direct",
  qwen: "direct",
  moonshot: "direct",
  mistral: "direct",
};

// Native DashScope origins, without /compatible-mode/v1, matching the native chat path
// protocol so picking a region does not lead to a 404 on chat. Kept in step with the
// backend providerConfigs.regionOptions.
export const FALLBACK_QWEN_REGIONS: ProviderRegionOption[] = [
  {
    id: "sg",
    label: "Singapore (International)",
    baseURL: "https://dashscope-intl.aliyuncs.com",
  },
  {
    id: "bj",
    label: "Beijing (China Mainland)",
    baseURL: "https://dashscope.aliyuncs.com",
  },
  {
    id: "hk",
    label: "Hong Kong",
    baseURL: "https://cn-hongkong.dashscope.aliyuncs.com",
  },
  {
    id: "us",
    label: "Virginia (US)",
    baseURL: "https://dashscope-us.aliyuncs.com",
  },
];

export const FALLBACK_MINIMAX_REGIONS: ProviderRegionOption[] = [
  {
    id: "global",
    label: "Global (api.minimax.io)",
    baseURL: "https://api.minimax.io/v1",
  },
  {
    id: "cn",
    label: "China Mainland (api.minimaxi.com)",
    baseURL: "https://api.minimaxi.com/v1",
  },
];

export const FALLBACK_MOONSHOT_REGIONS: ProviderRegionOption[] = [
  {
    id: "intl",
    label: "International (api.moonshot.ai)",
    baseURL: "https://api.moonshot.ai/v1",
    privacyPolicyURL: "https://platform.kimi.ai/docs/agreement/userprivacy.md",
  },
  {
    id: "cn",
    label: "China Mainland (api.moonshot.cn)",
    baseURL: "https://api.moonshot.cn/v1",
    privacyPolicyURL: "https://platform.kimi.com/docs/agreement/userprivacy.md",
  },
];

export const FALLBACK_SILICONFLOW_REGIONS: ProviderRegionOption[] = [
  {
    id: "cn",
    label: "China Mainland (api.siliconflow.cn)",
    baseURL: "https://api.siliconflow.cn/v1",
    apiKeyHelpURL: "https://cloud.siliconflow.cn/account/ak",
  },
  {
    id: "intl",
    label: "International (api.siliconflow.com)",
    baseURL: "https://api.siliconflow.com/v1",
    apiKeyHelpURL: "https://cloud.siliconflow.com/account/ak",
  },
];

export function resolveProviderSetupCatalog(
  providerConfigs?: PublicProviderConfig[] | null,
): ProviderSetupCatalog {
  if (providerConfigs == null) {
    return buildFallbackCatalog();
  }

  const knownConfigs = (providerConfigs ?? []).filter(isKnownProviderConfig);
  const defaultsByKind = buildFallbackDefaults();
  const configsByKind = buildFallbackProviderConfigs();
  if (knownConfigs.length === 0) {
    return {
      providers: [],
      defaultsByKind,
      configsByKind,
      qwenRegions: configsByKind.qwen.regionOptions,
      defaultKind: DEFAULT_KIND,
    };
  }

  const sortedConfigs = [...knownConfigs].sort(compareProviderConfigs);

  for (const config of sortedConfigs) {
    defaultsByKind[config.kind] = mergeWithFallback(config);
    configsByKind[config.kind] = mergeProviderConfig(config);
  }

  const providers = sortedConfigs.map((config) => ({
    kind: config.kind,
    displayName:
      normalizeOptionalText(config.selectionLabel) ??
      normalizeOptionalText(config.displayName) ??
      getProviderDisplayName(config.kind),
    category: configsByKind[config.kind].category,
  }));

  const qwenConfig = sortedConfigs.find((config) => config.kind === "qwen");
  const qwenRegions = qwenConfig
    ? configsByKind.qwen.regionOptions
    : configsByKind.qwen.regionOptions;

  return {
    providers,
    defaultsByKind,
    configsByKind,
    qwenRegions,
    defaultKind: resolveDefaultKind(providers.map((provider) => provider.kind)),
  };
}

function buildFallbackCatalog(): ProviderSetupCatalog {
  return {
    providers: FALLBACK_PROVIDER_ORDER.map((kind) => ({
      kind,
      displayName: providerDefaults[kind].displayName,
      category: FALLBACK_PROVIDER_CATEGORIES[kind],
    })),
    defaultsByKind: buildFallbackDefaults(),
    configsByKind: buildFallbackProviderConfigs(),
    qwenRegions: [...FALLBACK_QWEN_REGIONS],
    defaultKind: DEFAULT_KIND,
  };
}

function buildFallbackDefaults(): Record<
  ConfiguredProviderKind,
  ProviderSetupDefaults
> {
  return FALLBACK_PROVIDER_ORDER.reduce(
    (acc, kind) => {
      acc[kind] = {
        ...providerDefaults[kind],
        autoFillNote: null,
      };
      return acc;
    },
    {} as Record<ConfiguredProviderKind, ProviderSetupDefaults>,
  );
}

function buildFallbackProviderConfigs(): Record<
  ConfiguredProviderKind,
  ProviderSetupProviderConfig
> {
  return FALLBACK_PROVIDER_ORDER.reduce(
    (acc, kind) => {
      acc[kind] = {
        category: FALLBACK_PROVIDER_CATEGORIES[kind],
        regionOptions:
          kind === "miniMax"
            ? [...FALLBACK_MINIMAX_REGIONS]
            : kind === "qwen"
              ? [...FALLBACK_QWEN_REGIONS]
              : kind === "moonshot"
                ? [...FALLBACK_MOONSHOT_REGIONS]
                : kind === "siliconFlow"
                  ? [...FALLBACK_SILICONFLOW_REGIONS]
                  : [],
      };
      return acc;
    },
    {} as Record<ConfiguredProviderKind, ProviderSetupProviderConfig>,
  );
}

function mergeWithFallback(
  config: KnownPublicProviderConfig,
): ProviderSetupDefaults {
  const fallback = providerDefaults[config.kind];

  return {
    displayName:
      normalizeOptionalText(config.displayName) ?? fallback.displayName,
    shortName: normalizeOptionalText(config.shortName) ?? fallback.shortName,
    apiKeyPlaceholder:
      normalizeOptionalText(config.apiKeyPlaceholder) ??
      fallback.apiKeyPlaceholder,
    defaultBaseURL:
      normalizeOptionalText(config.defaultBaseURL) ?? fallback.defaultBaseURL,
    keyHelpUrl:
      normalizeOptionalText(config.apiKeyHelpURL) ?? fallback.keyHelpUrl,
    autoFillNote: normalizeOptionalText(config.autoFillNote) ?? null,
  };
}

function mergeProviderConfig(
  config: KnownPublicProviderConfig,
): ProviderSetupProviderConfig {
  const fallback = buildFallbackProviderConfigs()[config.kind];
  const regionOptions = normalizeRegionOptions(config.regionOptions);
  const usesFallbackRegionOptions =
    typeof config.regionOptions === "undefined" && regionOptions.length === 0;

  return {
    category: normalizeCategory(config.category) ?? fallback.category,
    regionOptions: usesFallbackRegionOptions
      ? fallback.regionOptions
      : regionOptions,
  };
}

function compareProviderConfigs(
  left: KnownPublicProviderConfig,
  right: KnownPublicProviderConfig,
): number {
  const leftOrder = left.sortOrder ?? Number.MAX_SAFE_INTEGER;
  const rightOrder = right.sortOrder ?? Number.MAX_SAFE_INTEGER;
  if (leftOrder !== rightOrder) {
    return leftOrder - rightOrder;
  }

  const leftFallbackIndex = FALLBACK_PROVIDER_ORDER.indexOf(left.kind);
  const rightFallbackIndex = FALLBACK_PROVIDER_ORDER.indexOf(right.kind);
  if (leftFallbackIndex !== rightFallbackIndex) {
    return leftFallbackIndex - rightFallbackIndex;
  }

  return left.kind.localeCompare(right.kind);
}

function resolveDefaultKind(
  kinds: ConfiguredProviderKind[],
): ConfiguredProviderKind {
  return kinds.includes(DEFAULT_KIND) ? DEFAULT_KIND : (kinds[0] ?? DEFAULT_KIND);
}

function isKnownProviderConfig(
  config: PublicProviderConfig,
): config is KnownPublicProviderConfig {
  return KNOWN_PROVIDER_KINDS.has(config.kind as ConfiguredProviderKind);
}

function normalizeRegionOptions(
  regionOptions: PublicProviderConfig["regionOptions"],
): ProviderRegionOption[] {
  if (!Array.isArray(regionOptions)) {
    return [];
  }

  return regionOptions
    .map((region) => ({
      id: region.id.trim(),
      label: region.label.trim(),
      baseURL: region.baseURL.trim().replace(/\/+$/, ""),
      privacyPolicyURL: region.privacyPolicyURL?.trim(),
      apiKeyHelpURL: region.apiKeyHelpURL?.trim(),
    }))
    .filter(
      (region) => Boolean(region.id) && Boolean(region.label) && Boolean(region.baseURL),
    );
}

function normalizeCategory(
  value: string | undefined,
): ProviderSetupProviderConfig["category"] | undefined {
  if (value === "direct" || value === "aggregator") {
    return value;
  }
  return undefined;
}

function normalizeOptionalText(value: string | null | undefined) {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}

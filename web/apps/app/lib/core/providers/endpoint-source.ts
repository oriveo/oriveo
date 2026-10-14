/**
 * Web wiring of the official-provider address source and the setup fields: projects the metadata providerConfig into
 * the shape core resolution needs, and computes endpointSource for the three paths that write baseURLText (setup page / address edit / sync landing).
 * Full rules in shared test-fixtures/provider-catalog/endpoint-source.v1.json and setup-fields.v1.json.
 */
import type { StoreApi } from 'zustand';
import type { Provider } from '@oriveo/shared';
import {
  classifyEndpointSource,
  resolveEndpointSourceBaseURL,
  fillSetupTemplate,
  isOfficialEndpointKind,
  normalizeEndpointSourceURL,
  normalizeSetupFieldValue,
  reconcileEndpointSource,
  templatePlaceholderIds,
  type EndpointSource,
  type OfficialEndpointConfig,
  type SetupFieldId,
  type SetupValues,
} from '@oriveo/core/providers/transport/endpoint-resolver';
import {
  getPublicProviderConfig,
  hasPublicProviderConfigSource,
  type PublicProviderConfig,
} from '../metadata/metadata-client';
import { putProvider } from '../../infra/storage/idb';
import type { AppStore } from '../store/app-store';

export function endpointConfigFromPublic(
  config: PublicProviderConfig | null | undefined,
): OfficialEndpointConfig | null {
  if (!config) return null;
  return {
    defaultBaseURL: config.defaultBaseURL,
    regionOptions: config.regionOptions ?? null,
    trustedHosts: config.trustedHosts ?? null,
    setupFields: config.setupFields ?? null,
  };
}

/**
 * Root address used for requests: an official provider first runs lazy migration in memory, then default / region:<id>
 * is computed from the current metadata, falling back to the literal if it cannot be computed;
 * non-official providers (Relay / local / hosted / Free) return baseURLText as is. All official send paths take the address through it;
 * identity / fingerprint / display still read the literal baseURLText.
 */
export function requestBaseURLText(
  provider: Pick<Provider, 'kind' | 'baseURLText' | 'endpointSource' | 'setupValues'> | null | undefined,
): string | undefined {
  if (!provider) return undefined;
  if (!isOfficialEndpointKind(provider.kind)) return provider.baseURLText;
  return resolveEndpointSourceBaseURL(
    provider.kind,
    provider,
    endpointConfigFromPublic(getPublicProviderConfig(provider.kind)),
  ) ?? provider.baseURLText;
}

/**
 * Startup backfill: official records run lazy migration: unclassified ones are classified by the current metadata, R1 retired regions are migrated away
 * (runs even without metadata), R2 default sources are pinned to the matched region; classified records run it too. Writes only locally (does not change
 * updatedAt, does not notify sync); runs at the same time as the deterministic-id migration, after it.
 */
export async function backfillOfficialEndpointSources(store: StoreApi<AppStore>): Promise<void> {
  const hasMetadata = hasPublicProviderConfigSource();
  const changed: Provider[] = [];
  const nextProviders = store.getState().providers.map((provider) => {
    if (!isOfficialEndpointKind(provider.kind)) return provider;
    const config = hasMetadata ? endpointConfigFromPublic(getPublicProviderConfig(provider.kind)) : null;
    const reconciled = reconcileEndpointSource(provider.kind, provider, config);
    if (
      reconciled.endpointSource === provider.endpointSource
      && reconciled.baseURLText === provider.baseURLText
    ) {
      return provider;
    }
    changed.push(reconciled);
    return reconciled;
  });
  if (changed.length === 0) return;
  store.setState({ providers: nextProviders });
  await Promise.all(changed.map((provider) => putProvider(provider).catch(() => {})));
}

/** Classify the literal address by the current (decoded) metadata; returns undefined for non-official providers or when there is no metadata. */
export function classifyProviderEndpointSource(
  kind: string,
  baseURLText: string | null | undefined,
  config: OfficialEndpointConfig | null = endpointConfigFromPublic(getPublicProviderConfig(kind)),
): EndpointSource | undefined {
  if (!isOfficialEndpointKind(kind)) return undefined;
  return classifyEndpointSource(kind, baseURLText, config);
}

/**
 * endpointSource when writing baseURLText (address edit, sync landing): address unchanged (equal after normalization) and a source already exists →
 * keep it, so an unrelated write after metadata changed the address does not turn default / region into custom; address changed → reclassify by the current
 * metadata (cleared when it cannot be classified, left for resolution time). Returns an empty patch for non-official providers.
 */
export function endpointSourcePatchForBaseURL(
  kind: string,
  nextBaseURLText: string | null | undefined,
  previous?: Pick<Provider, 'baseURLText' | 'endpointSource'>,
  config?: OfficialEndpointConfig | null,
): Pick<Provider, 'endpointSource'> {
  if (!isOfficialEndpointKind(kind)) return {};
  if (
    previous?.endpointSource
    && normalizeEndpointSourceURL(previous.baseURLText) === normalizeEndpointSourceURL(nextBaseURLText)
  ) {
    return { endpointSource: previous.endpointSource };
  }
  return {
    endpointSource: config === undefined
      ? classifyProviderEndpointSource(kind, nextBaseURLText)
      : classifyProviderEndpointSource(kind, nextBaseURLText, config),
  };
}

export interface OfficialSetupEndpointInput {
  kind: string;
  /** Configuration seen by the setup page: regionOptions is the one in the selector (already through the trusted table). */
  config: OfficialEndpointConfig;
  /** Selected region id when there are regions; pass null when there are none. */
  regionId: string | null;
  /** Address typed by hand under "Advanced settings" when there are no regions; empty = unchanged. */
  customBaseURL?: string;
  values?: SetupValues;
}

export interface OfficialSetupEndpoint {
  /** Fields the selected template needs the user to fill (inserted below the region selector). */
  fields: SetupFieldId[];
  /** The selected template as is (for telemetry); contains placeholders when values are unfilled. */
  template: string;
  /** null = field value missing or invalid, the primary button is disabled. */
  result: Pick<Provider, 'baseURLText' | 'endpointSource' | 'setupValues'> | null;
}

/** Address, source and setup field values at setup page submit. */
export function buildOfficialSetupEndpoint(input: OfficialSetupEndpointInput): OfficialSetupEndpoint {
  const { config } = input;
  const regions = config.regionOptions ?? [];
  const region = regions.length > 0
    ? regions.find((option) => option.id === input.regionId) ?? null
    : null;
  const custom = regions.length === 0 ? input.customBaseURL?.trim() ?? '' : '';
  const template = region?.baseURL ?? (custom || (config.defaultBaseURL ?? ''));
  const fields = (custom ? [] : templatePlaceholderIds(template))
    .filter((id): id is SetupFieldId => config.setupFields?.some((field) => field.id === id) === true);

  let endpointSource: EndpointSource | undefined;
  if (region) {
    endpointSource = `region:${region.id}`;
  } else if (custom) {
    endpointSource = classifyProviderEndpointSource(input.kind, custom, config) ?? 'custom';
  } else {
    endpointSource = 'default';
  }

  if (fields.length === 0) {
    return { fields, template, result: { baseURLText: template, endpointSource } };
  }
  const setupValues: SetupValues = {};
  for (const id of fields) {
    const value = normalizeSetupFieldValue(input.values?.[id]);
    if (!value) return { fields, template, result: null };
    setupValues[id] = value;
  }
  const baseURLText = fillSetupTemplate(template, setupValues);
  return {
    fields,
    template,
    result: baseURLText ? { baseURLText, endpointSource, setupValues } : null,
  };
}

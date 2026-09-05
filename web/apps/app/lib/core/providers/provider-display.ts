import type { Provider, ProviderKind } from '@oriveo/shared';
import { getProviderDisplayName } from '@oriveo/config';

export function getProviderInstanceDisplayName(provider: Provider): string {
  const customName = provider.customName?.trim();
  return customName || getProviderDisplayName(provider.kind);
}

type ProviderNameSource = Pick<Provider, 'id' | 'kind' | 'customName'>;

export function makeDefaultProviderInstanceName(
  kind: ProviderKind,
  providers: ProviderNameSource[],
): string | undefined {
  return makeUniqueProviderInstanceName(getProviderDisplayName(kind), kind, providers);
}

export function makeUniqueProviderInstanceName(
  desiredName: string,
  kind: ProviderKind,
  providers: ProviderNameSource[],
  excludingProviderId?: string,
): string {
  const trimmedName = desiredName.trim();
  const baseName = trimmedName || getProviderDisplayName(kind);
  const existingNames = new Set(
    providers
      .filter((provider) => provider.kind === kind && provider.id !== excludingProviderId)
      .map((provider) => provider.customName?.trim() || getProviderDisplayName(provider.kind))
      .filter((name) => name.length > 0)
      .map(normalizeProviderName),
  );

  if (!existingNames.has(normalizeProviderName(baseName))) {
    return baseName;
  }

  const suffixBaseName = removeNumericSuffix(baseName);
  let suffix = 2;
  while (existingNames.has(normalizeProviderName(`${suffixBaseName} ${suffix}`))) {
    suffix += 1;
  }
  return `${suffixBaseName} ${suffix}`;
}

export function makeRelayDefaultProviderInstanceName(
  endpoint: string,
  providers: ProviderNameSource[],
  excludingProviderId?: string,
): string {
  return makeUniqueProviderInstanceName(
    relayDomainNameFromEndpoint(endpoint) ?? getProviderDisplayName('relay'),
    'relay',
    providers,
    excludingProviderId,
  );
}

export function relayDomainNameFromEndpoint(endpoint: string): string | null {
  const host = parseHost(endpoint);
  if (!host) return null;
  if (host === 'localhost' || isIPv4Address(host) || isIPv6Address(host)) return host;

  const labels = host.split('.').filter(Boolean);
  if (labels.length <= 2) return host;
  return labels.slice(-2).join('.');
}

function normalizeProviderName(name: string): string {
  return name.trim().replace(/\s+/g, ' ').toLocaleLowerCase();
}

function removeNumericSuffix(name: string): string {
  const match = name.match(/^(.*?)(?:\s+\d+)?$/);
  const base = match?.[1]?.trim();
  return base || name.trim();
}

function parseHost(endpoint: string): string | null {
  const trimmed = endpoint.trim();
  if (!trimmed) return null;
  const candidate = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(trimmed)
    ? trimmed
    : `https://${trimmed}`;
  try {
    return new URL(candidate).hostname.toLocaleLowerCase().replace(/^\[|\]$/g, '');
  } catch {
    return null;
  }
}

function isIPv4Address(host: string): boolean {
  const parts = host.split('.');
  return parts.length === 4 && parts.every((part) => {
    if (!/^\d+$/.test(part)) return false;
    const value = Number(part);
    return value >= 0 && value <= 255;
  });
}

function isIPv6Address(host: string): boolean {
  return host.includes(':');
}

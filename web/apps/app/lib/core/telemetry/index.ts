/**
 * The app's telemetry seam.
 *
 * Nothing is recorded anywhere by default: `getTelemetry()` returns a no-op client, and every
 * call site goes through it. A deployment that wants product analytics installs its own
 * implementation of the `Telemetry` interface with `setTelemetry()`.
 *
 * The value of routing every call through this module is the normalisation below. Provider kinds
 * and model identifiers have to be reduced before they can be recorded at all, and doing that
 * inline at each call site is how one of them ends up shipping a user's private model catalog.
 */

import {
  createNoopTelemetry,
  type Telemetry,
  type TelemetryEventName,
  type TelemetryProperties,
} from '@oriveo/shared';

let instance: Telemetry | null = null;

export function getTelemetry(): Telemetry {
  if (!instance) {
    instance = createNoopTelemetry({
      apiKey: null,
      platform: 'web-app',
      appVersion: process.env.NEXT_PUBLIC_APP_VERSION ?? '0.0.0',
      releaseChannel: process.env.NODE_ENV === 'production' ? 'release' : 'debug',
      debug: process.env.NODE_ENV !== 'production',
    });
  }
  return instance;
}

/** Installs a telemetry client. Pass `null` to go back to the no-op. */
export function setTelemetry(client: Telemetry | null): void {
  instance = client;
}

export function trackEvent(event: TelemetryEventName, props?: TelemetryProperties): void {
  try {
    getTelemetry().track(event, props);
  } catch (err) {
    if (process.env.NODE_ENV !== 'production') {
      // eslint-disable-next-line no-console
      console.warn('[telemetry] track failed', event, err);
    }
  }
}

export function trackPage(path: string, props?: TelemetryProperties): void {
  try {
    getTelemetry().page(path, props);
  } catch (err) {
    if (process.env.NODE_ENV !== 'production') {
      // eslint-disable-next-line no-console
      console.warn('[telemetry] page failed', path, err);
    }
  }
}

export function setTelemetrySuperProperties(props: TelemetryProperties): void {
  try {
    getTelemetry().setSuperProperties(props);
  } catch {
    // Super properties are decoration; losing them must never break a call site.
  }
}

/**
 * Normalises a provider kind into the lowercase form used by every client, so the same provider
 * groups together no matter which app recorded the event.
 */
export function telemetryProviderKind(kind: string | null | undefined): string {
  if (!kind) return 'unknown';
  return kind.toLowerCase();
}

/**
 * Reduces a model identifier to something safe to record. A relay model id comes from a catalog on
 * the user's own machine and routinely carries a company, project, or internal code name, so it is
 * user data rather than a dimension worth aggregating: every relay model reports as `custom`.
 *
 * Every event carrying a model identity must go through this function. Inlining
 * `kind === 'relay' ? 'custom' : id` at a call site is how one of them ends up missing the check.
 */
export function telemetryModelID(
  providerKind: string | null | undefined,
  modelID: string,
): string {
  return providerKind === 'relay' ? 'custom' : modelID;
}

/**
 * Distinct from `telemetryProviderKind`'s `unknown`: `unknown` means a value was expected and could
 * not be read, which is an instrumentation defect; `unspecified` means the user has not chosen yet,
 * which is a normal state. Merging the two makes a setup funnel unreadable.
 */
export const TELEMETRY_KIND_UNSPECIFIED = 'unspecified';

/** How far a provider setup got. Official providers skip `endpointEntered`; relays do not. */
export const ProviderSetupStep = {
  kindPicker: 'kind_picker',
  kindSelected: 'kind_selected',
  endpointEntered: 'endpoint_entered',
  apiKeyEntered: 'api_key_entered',
  submitting: 'submitting',
} as const;

export type ProviderSetupStepValue =
  (typeof ProviderSetupStep)[keyof typeof ProviderSetupStep];

export type ProviderSetupEntryPointValue =
  | 'onboarding'
  | 'providers'
  | 'model_picker'
  | 'skill_edit'
  | 'direct_link';

/** The only builder for `provider_setup_abandoned` properties. */
export function providerSetupAbandonedProperties(input: {
  providerKind: string;
  stepReached: ProviderSetupStepValue;
  endpoint: string | null | undefined;
  relayKind?: string;
  entryPoint: ProviderSetupEntryPointValue;
  isFirstProvider?: boolean;
  connectionAttempts: number;
  lastErrorCode?: string | null;
}): TelemetryProperties {
  return {
    provider_kind: input.providerKind,
    step_reached: input.stepReached,
    endpoint_host: telemetryEndpointHost(input.endpoint),
    endpoint: telemetryEndpoint(input.endpoint),
    relay_kind: input.relayKind ?? '',
    entry_point: input.entryPoint,
    ...(input.isFirstProvider === undefined
      ? {}
      : { is_first_provider: input.isFirstProvider }),
    connection_attempts: input.connectionAttempts,
    last_error_code: input.lastErrorCode ?? '',
  };
}

/**
 * Which setup screen a `provider_key_validated` came from.
 *
 * The provider kind cannot answer this: a local engine and a custom relay both persist as `relay`,
 * so without the surface there is no way to tell which entry point a user was on when it failed.
 */
export const ProviderSetupSurface = {
  providerSetup: 'provider_setup',
  relaySetup: 'relay_setup',
  localCompute: 'local_compute',
} as const;

export type ProviderSetupSurfaceValue =
  (typeof ProviderSetupSurface)[keyof typeof ProviderSetupSurface];

/** How the connection authenticates. */
export const TelemetryAuthMode = {
  apiKey: 'api_key',
  subscription: 'subscription',
} as const;

export type TelemetryAuthModeValue =
  (typeof TelemetryAuthMode)[keyof typeof TelemetryAuthMode];

/**
 * The only builder for `provider_key_validated` properties. Exactly one event is recorded when the
 * user submits, whether it succeeded or not, with the same fields as
 * `providerSetupAbandonedProperties` so that "gave up" and "submitted" can be compared on the same
 * dimensions.
 */
export function providerKeyValidatedProperties(input: {
  providerKind: string;
  success: boolean;
  errorCode?: string | null;
  endpoint: string | null | undefined;
  relayKind?: string;
  entryPoint: ProviderSetupEntryPointValue;
  isFirstProvider?: boolean;
  connectionAttempts: number;
  authMode?: TelemetryAuthModeValue;
  setupSurface: ProviderSetupSurfaceValue;
}): TelemetryProperties {
  return {
    provider_kind: input.providerKind,
    success: input.success,
    // An empty string on success states plainly that no error was observed, rather than passing
    // `unknown` off as a conclusion.
    error_code: input.errorCode ?? '',
    endpoint_host: telemetryEndpointHost(input.endpoint),
    endpoint: telemetryEndpoint(input.endpoint),
    relay_kind: input.relayKind ?? '',
    entry_point: input.entryPoint,
    ...(input.isFirstProvider === undefined
      ? {}
      : { is_first_provider: input.isFirstProvider }),
    connection_attempts: input.connectionAttempts,
    auth_mode: input.authMode ?? TelemetryAuthMode.apiKey,
    setup_surface: input.setupSurface,
  };
}

/**
 * The single implementation of endpoint redaction: keep `scheme://host[:port]/path`, drop userinfo
 * and the query and fragment. Some relays carry a token in `user:pass@` or `?key=`, so neither may
 * survive. A value with no scheme is completed as https.
 */
export function sanitizeTelemetryURL(
  value: string | null | undefined,
): string | undefined {
  const trimmed = value?.trim();
  if (!trimmed) return undefined;

  const candidate = /^[a-z][a-z\d+.-]*:\/\//i.test(trimmed)
    ? trimmed
    : `https://${trimmed}`;

  try {
    const url = new URL(candidate);
    if ((url.protocol !== 'http:' && url.protocol !== 'https:') || !url.hostname) {
      return undefined;
    }

    const path = url.pathname.replace(/\/+$/, '');
    return `${url.protocol}//${url.host}${path}`;
  } catch {
    return undefined;
  }
}

/** Redacted endpoint. Missing or unparseable becomes an empty string, which filters better than null. */
export function telemetryEndpoint(raw: string | null | undefined): string {
  return sanitizeTelemetryURL(raw) ?? '';
}

/** Endpoint host including a non-default port. Missing or unparseable becomes an empty string. */
export function telemetryEndpointHost(raw: string | null | undefined): string {
  const normalized = sanitizeTelemetryURL(raw);
  if (!normalized) return '';
  return normalized.split('://').slice(1).join('://').split('/')[0] ?? '';
}

export type { TelemetryEventName, TelemetryProperties } from '@oriveo/shared';

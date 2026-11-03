/**
 * StudioAvailability: the single answer every studio entry point asks
 * (sidebar entry, /studio/* deep links, badge, chat "open in studio", managed
 * model listing). Pure function over a build flag, two remote feature flags and
 * local state; truth table lives in the shared fixture studio_availability.v1.json.
 */

/** Remote keys in /api/metadata runtimeConfig.featureFlags. Only referenced in this file. */
const REMOTE_STUDIO_ENABLED_KEY = 'studio_enabled';
const REMOTE_STUDIO_MANAGED_ENABLED_KEY = 'studio_managed_enabled';

/** Defaults when a remote key is missing: studio is on, managed models are off. */
const REMOTE_STUDIO_ENABLED_DEFAULT = true;
const REMOTE_STUDIO_MANAGED_ENABLED_DEFAULT = false;

export interface StudioAvailabilityInput {
  compileFlag: boolean;
  /** Missing = true (the remote flag only hides studio in an emergency). */
  remoteStudioEnabled?: boolean;
  /** Missing = false. */
  remoteManagedEnabled?: boolean;
  /** Managed protection switch image_disabled. Missing = false. */
  imageDisabled?: boolean;
  /** Number of enabled hosted image models. Missing = 0. */
  enabledManagedModels?: number;
  isPro: boolean;
}

export type StudioWebApiStatus = 'served' | 'not_found';

export interface StudioAvailability {
  entryVisible: boolean;
  deepLinkOpens: boolean;
  badgeRendered: boolean;
  managedListed: boolean;
  managedInChatPicker: boolean;
  /** Chat image works are always registered locally, regardless of flags. */
  chatWorkRegistration: boolean;
  /** Pro works sync regardless of flags, so turning the entry on does not trigger a mass upload. */
  syncWorks: boolean;
  /** /api/studio/* is served only when compiled in; otherwise 404. */
  webApiStatus: StudioWebApiStatus;
}

export type StudioLocalInput = Omit<
  StudioAvailabilityInput,
  'compileFlag' | 'remoteStudioEnabled' | 'remoteManagedEnabled'
> & {
  /** Missing = isStudioCompiledIn(). */
  compileFlag?: boolean;
};

/**
 * Build-time switch. NEXT_PUBLIC_STUDIO_ENABLED must be read literally so Next
 * inlines it at build time. Explicit "true" / "false" wins; when unset, studio is
 * compiled in only for development builds.
 */
export function isStudioCompiledIn(): boolean {
  const flag = process.env.NEXT_PUBLIC_STUDIO_ENABLED;
  if (flag === 'true') return true;
  if (flag === 'false') return false;
  return process.env.NODE_ENV === 'development';
}

export function studioAvailability(input: StudioAvailabilityInput): StudioAvailability {
  const remoteStudio = input.remoteStudioEnabled ?? REMOTE_STUDIO_ENABLED_DEFAULT;
  const remoteManaged = input.remoteManagedEnabled ?? REMOTE_STUDIO_MANAGED_ENABLED_DEFAULT;
  const imageDisabled = input.imageDisabled ?? false;
  const enabledManagedModels = input.enabledManagedModels ?? 0;

  const entry = input.compileFlag && remoteStudio;
  const managed = entry && remoteManaged && !imageDisabled && enabledManagedModels > 0;

  return {
    entryVisible: entry,
    deepLinkOpens: entry,
    badgeRendered: entry,
    managedListed: managed,
    managedInChatPicker: managed,
    chatWorkRegistration: true,
    syncWorks: input.isPro,
    webApiStatus: input.compileFlag ? 'served' : 'not_found',
  };
}

function readBooleanFlag(
  featureFlags: Readonly<Record<string, unknown>> | null | undefined,
  key: string,
): boolean | undefined {
  const value = featureFlags?.[key];
  return typeof value === 'boolean' ? value : undefined;
}

/**
 * Maps runtimeConfig.featureFlags onto the remote inputs. A missing (or
 * non-boolean) key stays undefined so studioAvailability applies the documented
 * default (never a blanket false). compileFlag defaults to isStudioCompiledIn().
 */
export function studioAvailabilityInputFromFeatureFlags(
  featureFlags: Readonly<Record<string, unknown>> | null | undefined,
  local: StudioLocalInput,
): StudioAvailabilityInput {
  return {
    ...local,
    compileFlag: local.compileFlag ?? isStudioCompiledIn(),
    remoteStudioEnabled: readBooleanFlag(featureFlags, REMOTE_STUDIO_ENABLED_KEY),
    remoteManagedEnabled: readBooleanFlag(featureFlags, REMOTE_STUDIO_MANAGED_ENABLED_KEY),
  };
}

/**
 * Sample-mode switch and preset injection point for the relay family's direct sample entry
 * (`/dev/relay-shots/<page name>`, `next dev` only).
 *
 * In production builds every function returns on its first line via
 * `process.env.NODE_ENV === 'production'` (a build-time constant, so the branch is pruned) and the
 * hooks inside components are always no-ops; presets are written only by the dev route
 * `app/dev/relay-shots/`.
 */
import type { RelayCapabilityTestPanelKind, RelayCapabilityTestResults } from '../core/relay-capability-test-ops';
import type { RelaySettingsSaveFailure } from '../hooks/useProviderActions';
import type { ManualSetupDraft } from '../../app/providers/relay/new/manual-setup-board';
import type { RelayKeyNotice } from '../../app/providers/[providerId]/relay-keys-board';

export const RELAY_SHOTS_PATH_PREFIX = '/dev/relay-shots/';
/** Memory page family samples (`/dev/memory-shots/<page>`): the same isolation fence and sample-mode switch. */
export const MEMORY_SHOTS_PATH_PREFIX = '/dev/memory-shots/';
/** Context page family samples (`/dev/context-shots/<page>`): the same isolation fence and sample-mode switch. */
export const CONTEXT_SHOTS_PATH_PREFIX = '/dev/context-shots/';
/** Web search page family samples (`/dev/webSearch-shots/<page>`): the same isolation fence as relay. */
export const WEB_SEARCH_SHOTS_PATH_PREFIX = '/dev/webSearch-shots/';

/** Per-page internal state presets applied on page entry (arm / settle); omitted = normal initial values. */
export interface RelayShotSeed {
  detail?: {
    /** Enter the page already in "edit connection". */
    editing?: boolean;
    /** After delayMs on entry, feed one save failure and focus the address input. */
    settingsFailure?: { delayMs: number; failure: RelaySettingsSaveFailure };
    /** The advanced page opens with the "test capabilities" panel already open (running). */
    capabilityTest?: { results: RelayCapabilityTestResults; running: RelayCapabilityTestPanelKind };
    /** The keys page shows these keys as still being fetched. */
    keysFetchingIDs?: readonly string[];
    /** Notices preset on the keys page (computed by the production notice function, e.g. "added" on success). */
    keysNotices?: readonly RelayKeyNotice[];
    /** The keys page opens with the add-key input already open. */
    keysAddOpen?: boolean;
    /** The first draft section of the web search settings page applies a template. */
    webSearchTemplate?: boolean;
  };
  setup?: {
    cloudMode?: 'quick' | 'manual';
    endpoint?: string;
    apiKey?: string;
    manualDraft?: Partial<ManualSetupDraft>;
    /** Step 2 opens with the inline manual-add form already expanded. */
    addManualOpen?: boolean;
  };
}

let currentSeed: RelayShotSeed | null = null;

export function isRelayShotsPath(pathname: string): boolean {
  return pathname.startsWith(RELAY_SHOTS_PATH_PREFIX);
}

/** Any sample route (relay / memory pages / context pages): StoreProvider uses this to install the fence and skip hydration. */
export function isShotsPath(pathname: string): boolean {
  return isRelayShotsPath(pathname)
    || pathname.startsWith(MEMORY_SHOTS_PATH_PREFIX)
    || pathname.startsWith(CONTEXT_SHOTS_PATH_PREFIX)
    || pathname.startsWith(WEB_SEARCH_SHOTS_PATH_PREFIX);
}

/** True when the current page is a sample route (dev builds, including the memory pages); always false in production. */
export function isRelayShotMode(): boolean {
  if (process.env.NODE_ENV === 'production') return false;
  return typeof window !== 'undefined' && isShotsPath(window.location.pathname);
}

export function setRelayShotSeed(seed: RelayShotSeed | null): void {
  if (process.env.NODE_ENV === 'production') return;
  currentSeed = seed;
}

/** Components read the preset here; always null in production. */
export function relayShotSeed(): RelayShotSeed | null {
  if (process.env.NODE_ENV === 'production') return null;
  return currentSeed;
}

/** Fixed model placeholder used in samples (iOS samples do not read live metadata). */
const RELAY_SHOT_FLAGSHIP_MODEL_ID = 'gpt-5.6-sol';

/** Returns the fixed flagship model ID inside sample routes; null everywhere else (including production), so callers use the served value. */
export function relayShotFlagshipModelID(): string | null {
  if (process.env.NODE_ENV === 'production') return null;
  return isRelayShotMode() ? RELAY_SHOT_FLAGSHIP_MODEL_ID : null;
}

/**
 * Launch entry for studio presets: when the studio entry is visible, refresh the
 * presets for the app language's preset locale; when the refresh replaced the
 * presets (and current presets decode), prune the sample-image cache down to the
 * current style samples. Other outcomes leave the cache alone. Never prefetches images.
 */
import { getRuntimeConfig } from '../metadata/metadata-client';
import { studioAvailability, studioAvailabilityInputFromFeatureFlags } from './availability';
import { createPresetSampleCache, type PresetSampleCache } from './preset-sample-cache';
import { bundledStudioPresetsSnapshot, resolveStudioPresetLocale } from './presets';
import { createStudioPresetsStore, type StudioPresetsRefreshOutcome, type StudioPresetsStore } from './presets-store';

export interface StudioPresetsLaunchDeps {
  /** Defaults to studioAvailability(runtime feature flags).entryVisible. */
  entryVisible?: boolean;
  /** Defaults to document.documentElement.lang. */
  appLanguageTag?: unknown;
  /** Defaults to the lazily created module Store. */
  store?: StudioPresetsStore;
  /** Defaults to the lazily created module sample cache. */
  sampleCache?: Pick<PresetSampleCache, 'prune'>;
}

let sharedStore: StudioPresetsStore | null = null;
let sharedSampleCache: PresetSampleCache | null = null;

/** Module-wide presets Store, created on first use. */
export function studioPresetsStore(): StudioPresetsStore {
  sharedStore ??= createStudioPresetsStore();
  return sharedStore;
}

/** Module-wide sample-image cache, created on first use. */
export function studioPresetSampleCache(): PresetSampleCache {
  sharedSampleCache ??= createPresetSampleCache();
  return sharedSampleCache;
}

function defaultEntryVisible(): boolean {
  // entryVisible depends only on the compile flag and the remote studio flag; isPro does not affect it.
  return studioAvailability(studioAvailabilityInputFromFeatureFlags(getRuntimeConfig()?.featureFlags, { isPro: false }))
    .entryVisible;
}

function defaultLanguageTag(): string {
  return typeof document === 'undefined' ? '' : document.documentElement.lang;
}

/** Returns the refresh outcome, or null when the entry is hidden (no refresh, no cache change). */
export async function runStudioPresetsLaunch(
  deps: StudioPresetsLaunchDeps = {},
): Promise<StudioPresetsRefreshOutcome | null> {
  const entryVisible = deps.entryVisible ?? defaultEntryVisible();
  if (!entryVisible) return null;
  const locale = resolveStudioPresetLocale(
    bundledStudioPresetsSnapshot().locales,
    deps.appLanguageTag === undefined ? defaultLanguageTag() : deps.appLanguageTag,
  );
  const store = deps.store ?? studioPresetsStore();
  const outcome = await store.refreshIfNeeded(locale);
  const current = outcome === 'replaced' ? store.current(locale) : null;
  // current is null only when nothing decodes; pruning to an empty keep set would wipe the cache.
  if (current) {
    const keep = new Set<string>();
    for (const style of current.styles) {
      if (style.sample) keep.add(style.sample.sha256);
    }
    await (deps.sampleCache ?? studioPresetSampleCache()).prune([...keep]);
  }
  return outcome;
}

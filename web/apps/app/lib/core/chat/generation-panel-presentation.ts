/**
 * Rendering rules for the generation parameter panel.
 *
 * The panel used to inline three decisions in JSX - which parameters are visible, whether an empty
 * panel still renders, and whether unknown gets a badge - where tests could not reach them, so
 * "never collapse silently" and "the badge is mandatory" were left to the human eye. As pure
 * functions the production rules can be asserted directly.
 */

import type { AIModel, Provider } from '@oriveo/shared';
import type { CapabilityEvidenceResolution } from '@oriveo/core/providers/capability-evidence-facade';
import {
  connectionConfigurable,
  resolveGenerationProfileForModel,
  sessionActionable,
  type GenerationParameterEntryScope,
} from './stream-options';

type ProfileParameter = NonNullable<
  ReturnType<typeof resolveGenerationProfileForModel>
>['parameters'][number];

/**
 * The three empty states. They are mutually exclusive and **every trigger is decidable locally on
 * the client**, consuming no additional server-provided field.
 *
 * Three states rather than one, because the next user action differs completely: A leaves nothing to
 * do, B is an authority change, C is a fact about this connection.
 */
export type GenerationParameterEmptyState =
  /** A - not verified yet: this model on this connection has never returned a non-empty profile (fail-safe). */
  | 'notVerified'
  /** B - taken over or withdrawn by the catalog: the user saw a non-empty profile on this machine before, and it is empty now. */
  | 'catalogManaged'
  /** C - nothing accepted: the profile is non-empty but the current scope can set none of it. */
  | 'allUnsupported';

/**
 * Visible parameter set for the current scope. The panel **may only ask this function** and must not
 * inline another copy of the support rules.
 *
 * The two scopes answer with different sets on purpose: connection defaults really are sent with
 * every request, while the session set is the narrower "adjustable for this one turn" list the
 * composer chip also asks for. Both entry points read the same function so the chip can never
 * promise a row the panel then refuses to show.
 */
export function generationPanelVisibleParameters(
  provider: Provider,
  model: AIModel,
  scope: GenerationParameterEntryScope,
): ProfileParameter[] {
  return scope === 'session'
    ? sessionActionable(provider, model)
    : connectionConfigurable(provider, model);
}

/**
 * Empty state decision. `null` means there are visible parameters and the panel renders normally.
 *
 * `hasSeenNonEmptyProfile` is the only boundary between A and B. Known limitation: that history is
 * local only, so after a reinstall, a device change or a cache clear, B degrades into A. Both mean
 * "not adjustable right now", which is acceptable; the only precise fix would be a server-sent
 * withdrawal marker, which is deliberately out of scope.
 */
export function generationPanelEmptyState(input: {
  provider: Provider;
  model: AIModel;
  scope: GenerationParameterEntryScope;
  hasSeenNonEmptyProfile: boolean;
}): GenerationParameterEmptyState | null {
  const { provider, model, scope, hasSeenNonEmptyProfile } = input;
  if (generationPanelVisibleParameters(provider, model, scope).length > 0) return null;

  const declared = resolveGenerationProfileForModel(provider, model)?.parameters ?? [];
  // (a) The profile is absent or declared empty. Only the local history knows whether it never existed or existed once.
  if (declared.length === 0) return hasSeenNonEmptyProfile ? 'catalogManaged' : 'notVerified';

  // (b) The profile is non-empty but this scope can set none of it.
  return 'allUnsupported';
}

/**
 * Per-row "not verified" badge.
 *
 * The badge only consumes the production projection: a Relay declaration's `declared` and
 * `accepted-unverified` must both be marked honestly, and an official projection never matches.
 * **A missing badge counts as advertising an unverified capability**, and tests assert this function directly.
 */
export function showsUnverifiedBadge(
  evidence: Pick<CapabilityEvidenceResolution, 'source' | 'grade'>,
): boolean {
  return evidence.source === 'relay_declaration'
    && (evidence.grade === 'accepted_unverified' || evidence.grade === 'declared');
}

/** Group caption: it must appear whenever any parameter in the current render set carries a badge. */
export function showsUnverifiedGroupNote(
  evidence: readonly Pick<CapabilityEvidenceResolution, 'source' | 'grade'>[],
): boolean {
  return evidence.some(showsUnverifiedBadge);
}

// ── History bit for "has this machine ever seen a non-empty profile" (it exists only to separate A from B) ────────────────────
// **Not backed up, not synced, and not part of any send decision** - it is pure UI history, and
// losing it only degrades B into A (see the known limitation on generationPanelEmptyState above).

const PROFILE_SEEN_KEY = 'oriveo.generation-parameter-profile-seen.v1';
/** The cap is sized to the connection x model combinations a user actually opens; beyond that the oldest entry is dropped so it cannot grow without bound. */
const MAX_PROFILE_SEEN_ENTRIES = 300;

function profileSeenEntryKey(providerId: string, modelId: string): string {
  return `${providerId}|${modelId}`;
}

function readProfileSeenEntries(): string[] {
  if (typeof window === 'undefined') return [];
  try {
    const raw = window.localStorage.getItem(PROFILE_SEEN_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === 'string') : [];
  } catch {
    return [];
  }
}

export function hasSeenNonEmptyGenerationProfile(providerId: string, modelId: string): boolean {
  return readProfileSeenEntries().includes(profileSeenEntryKey(providerId, modelId));
}

/**
 * Called once every time the panel really renders a non-empty profile to the user.
 * `parameterCount === 0` is not recorded: having seen an empty one is not the B rule, B needs having seen a non-empty one.
 */
export function recordSeenGenerationProfile(
  providerId: string,
  modelId: string,
  parameterCount: number,
): void {
  if (parameterCount <= 0 || !modelId || typeof window === 'undefined') return;
  const key = profileSeenEntryKey(providerId, modelId);
  const current = readProfileSeenEntries();
  if (current.includes(key)) return;
  const next = [...current, key];
  try {
    window.localStorage.setItem(
      PROFILE_SEEN_KEY,
      JSON.stringify(next.slice(Math.max(0, next.length - MAX_PROFILE_SEEN_ENTRIES))),
    );
  } catch {
    // When storage is unavailable (private mode, quota full) degrade silently to "never seen", which turns B into A without affecting usability.
  }
}
